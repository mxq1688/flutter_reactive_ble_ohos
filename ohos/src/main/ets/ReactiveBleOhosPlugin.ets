/**
 * reactive_ble_ohos - HarmonyOS NEXT BLE 插件
 *
 * 基于 @kit.ConnectivityKit (ble) 与 @ohos.bluetooth.access 实现。
 * 参考文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-bluetooth-ble
 *
 * 实现除 clearGattCache、requestConnectionPriority 外的全部能力，与 Dart 层通过以下 Channel 通信：
 * - MethodChannel: reactive_ble_ohos_method
 * - EventChannel: reactive_ble_ohos_scan, reactive_ble_ohos_connected_device,
 *   reactive_ble_ohos_char_update, reactive_ble_ohos_status
 *
 * 错误处理约定（刻意分层，非统一 try/catch 包装）：
 * - 用户操作（连接、GATT 读写、MTU、RSSI、发现服务）：经 MethodChannel result.error 或
 *   EventChannel 载荷中的 error 字段回传 Dart，由 reactive_ble_platform_interface 转为 Result.failure
 * - 辅助路径（广播解析、扫描名称解析、清理 close/off）：仅 logBleWarning / logBleError，不中断扫描流
 * - 资源清理（disconnect、插件 detach）：尽力执行并记录日志，避免二次失败掩盖主错误
 */

import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodCallHandler,
  MethodResult,
  EventChannel,
  EventSink,
  StreamHandler,
} from '@ohos/flutter_ohos';
import { ble, constant } from '@kit.ConnectivityKit';
import access from '@ohos.bluetooth.access';
import { BusinessError } from '@kit.BasicServicesKit';

const METHOD_CHANNEL = 'reactive_ble_ohos_method';
const EVENT_SCAN = 'reactive_ble_ohos_scan';
const EVENT_CONNECTION = 'reactive_ble_ohos_connected_device';
const EVENT_CHAR_UPDATE = 'reactive_ble_ohos_char_update';
const EVENT_BLE_STATUS = 'reactive_ble_ohos_status';

const NO_OP_STREAM_HANDLER: StreamHandler = {
  onListen(_args: object, _sink: EventSink): void {},
  onCancel(_args: object): void {}
};

// Explicit interfaces for ArkTS (no untyped object literals)
interface BleStatusPayload {
  status: number;
}
interface ConnectionPayload {
  deviceId: string;
  connectionState: number;
  failureMessage?: string;
}
interface ScanDevicePayload {
  id: string;
  name: string;
  rssi: number;
  serviceUuids: string[];
  serviceData: Record<string, number[]>;
  manufacturerData: number[];
  connectable: number;
}
interface ScanResultPayload {
  device?: ScanDevicePayload;
  error?: string;
}
interface CharUpdatePayload {
  characteristic: CharRef;
  value?: number[];
  error?: string;
}
interface WriteResultPayload {
  characteristic: CharRef;
  error?: string;
}
interface MtuResultPayload {
  mtu: number;
}
interface RssiResultPayload {
  rssi: number;
}
interface ConnStateWithCode {
  code?: number;
}
interface MtuNegotiationPending {
  settled: boolean;
  clampedMtu: number;
  /** 与 [mtuNegotiationGenerationByDevice] 对齐，用于忽略被取代或乱序的 BLEMtuChange */
  generation: number;
  resolve: (mtu: number) => void;
  reject: (reason: Error) => void;
  timeoutId: number;
}
interface CharRef {
  deviceId: string;
  serviceId: string;
  serviceInstanceId: string;
  characteristicId: string;
  characteristicInstanceId: string;
}
interface DiscoveredChar {
  characteristicId: string;
  characteristicInstanceId: string;
  isReadable: boolean;
  isWritableWithResponse: boolean;
  isWritableWithoutResponse: boolean;
  isNotifiable: boolean;
  isIndicatable: boolean;
}
interface DiscoveredService {
  serviceId: string;
  serviceInstanceId: string;
  characteristics: DiscoveredChar[];
  includedServices: DiscoveredService[];
}

// BLE status codes (与 Dart BleStatus 枚举一致)
const BLE_STATUS_UNKNOWN = 0;
const BLE_STATUS_UNSUPPORTED = 1;
const BLE_STATUS_UNAUTHORIZED = 2;
const BLE_STATUS_POWERED_OFF = 3;
const BLE_STATUS_LOCATION_DISABLED = 4;
const BLE_STATUS_READY = 5;

// Connection state codes (与 Dart DeviceConnectionState 一致)
const CONN_STATE_CONNECTING = 0;
const CONN_STATE_CONNECTED = 1;
const CONN_STATE_DISCONNECTING = 2;
const CONN_STATE_DISCONNECTED = 3;

// Connectable (与 Dart Connectable 一致)
const CONNECTABLE_UNKNOWN = 0;
const CONNECTABLE_UNAVAILABLE = 1;
const CONNECTABLE_AVAILABLE = 2;

export default class ReactiveBleOhosPlugin implements FlutterPlugin, MethodCallHandler {
  getUniqueClassName(): string {
    return 'ReactiveBleOhosPlugin';
  }

  private methodChannel: MethodChannel | null = null;
  private scanChannel: EventChannel | null = null;
  private connectionChannel: EventChannel | null = null;
  private charUpdateChannel: EventChannel | null = null;
  private bleStatusChannel: EventChannel | null = null;

  private scanSink: EventSink | null = null;
  private connectionSink: EventSink | null = null;
  private charUpdateSink: EventSink | null = null;
  private bleStatusSink: EventSink | null = null;

  private binding: FlutterPluginBinding | null = null;

  /** 已连接的 GATT 客户端设备，key 为 deviceId */
  private connectedDevices: Map<string, ble.GattClientDevice> = new Map();
  /** 各设备 GATT 服务发现就绪的 Promise，供连接上报与特征读写复用 */
  private gattServicesReady: Map<string, Promise<ble.GattService[]>> = new Map();
  private static readonly GATT_READY_MAX_ATTEMPTS = 12;
  private static readonly GATT_READY_INITIAL_DELAY_MS = 100;
  private static readonly GATT_READY_MAX_DELAY_MS = 1500;
  private static readonly BLE_ATT_DEFAULT_MTU = 23;
  private static readonly BLE_MTU_MIN = 23;
  private static readonly BLE_MTU_MAX = 517;
  private static readonly MTU_NEGOTIATE_TIMEOUT_MS = 3000;
  /** Client Characteristic Configuration Descriptor (CCCD) 标准 UUID */
  private static readonly CCCD_DESCRIPTOR_UUID = '00002902-0000-1000-8000-00805f9b34fb';
  /** 各设备协商后的实际 MTU（由 BLEMtuChange 更新） */
  private negotiatedMtuByDevice: Map<string, number> = new Map();
  private mtuChangeHandlerByDevice: Map<string, (mtu: number) => void> = new Map();
  private mtuNegotiationPendingByDevice: Map<string, MtuNegotiationPending> = new Map();
  private mtuNegotiationGenerationByDevice: Map<string, number> = new Map();
  /** 已注册的 BLECharacteristicChange 回调，key 为 deviceId|serviceId|characteristicId */
  private charChangeCallbacks: Map<string, (ch: ble.BLECharacteristic) => void> = new Map();
  /** 正在连接的设备，用于连接超时与状态回调 */
  private connectingDeviceId: string | null = null;
  private connectingClient: ble.GattClientDevice | null = null;
  /** 各设备连接超时定时器 ID（支持多设备并发连接） */
  private connectTimeoutIdByDevice: Map<string, number> = new Map();
  /** 每次 connectToDevice 递增，用于超时与状态回调互斥 */
  private connectSessionCounter: number = 0;
  private static readonly MAX_CONNECT_SESSION_ID = 2147483647;
  private connectSessionByDevice: Map<string, number> = new Map();
  private connectStateHandlerByDevice: Map<string, (state: ble.BLEConnectionChangeState) => void> = new Map();
  /** 各设备最近一次连接状态，用于 EventSink 发送失败或重新监听后补发 */
  private lastConnectionStateByDevice: Map<string, ConnectionPayload> = new Map();

  // GattClient 创建优化：防止批量创建导致系统崩溃
  private isScanning: boolean = false;
  private scanResultHandler: ((data: Array<ble.ScanResult>) => void) | null = null;
  /** 扫描时是否通过临时 GattClient 解析空名称（默认关闭，避免影响后续连接） */
  private resolveScanNamesViaGatt: boolean = false;
  private pendingNameRequests: Set<string> = new Set(); // 正在获取名称的设备
  private completedNameRequests: Set<string> = new Set(); // 已完成名称获取的设备
  private activeGattClients: Map<string, ble.GattClientDevice> = new Map(); // 活跃的临时 GattClient
  private nameRequestTimeoutIdByDevice: Map<string, number> = new Map();
  private static readonly MAX_CONCURRENT_NAME_REQUESTS = 3; // 最大并发数
  private static readonly MAX_DISCOVERED_DEVICES = 1000;
  private static readonly SCAN_CACHE_TRIM_BATCH = 500;
  private nameRequestQueue: Array<string> = []; // 等待队列
  private discoveredDeviceIds: Set<string> = new Set(); // 已发现的设备 ID（用于去重）
  /** FIFO 顺序，用于在长时间扫描时按最早发现批次淘汰缓存 */
  private discoveredDeviceIdOrder: string[] = [];
  /** 各设备最近一次广播解析结果，供 Gatt 名称解析后合并上报 */
  private lastScanPayloadByDevice: Map<string, ScanDevicePayload> = new Map();

  /** FlutterPlugin 生命周期：引擎附加时注册 Method/Event Channel（HarmonyOS API：onAttachedToEngine）。 */
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;
    this.methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
    this.methodChannel.setMethodCallHandler(this);

    this.scanChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_SCAN);
    this.scanChannel.setStreamHandler(this.createStreamHandler(
      (sink: EventSink) => { this.scanSink = sink; },
      () => { this.releaseScanEventSink(); }
    ));

    this.connectionChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CONNECTION);
    this.connectionChannel.setStreamHandler(this.createStreamHandler(
      (sink: EventSink) => {
        this.connectionSink = sink;
        this.flushPendingConnectionUpdates();
      },
      () => { this.releaseConnectionEventSink(); }
    ));

    this.charUpdateChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHAR_UPDATE);
    this.charUpdateChannel.setStreamHandler(this.createStreamHandler(
      (sink: EventSink) => { this.charUpdateSink = sink; },
      () => { this.releaseCharUpdateEventSink(); }
    ));

    this.bleStatusChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_BLE_STATUS);
    this.bleStatusChannel.setStreamHandler(this.createStreamHandler(
      (sink: EventSink) => {
        this.bleStatusSink = sink;
        this.emitBleStatus();
      },
      () => { this.releaseBleStatusEventSink(); }
    ));

    // 监听蓝牙适配器状态变化（参考 js-apis-bluetooth-ble 与 bluetooth.access）
    try {
      access.on('stateChange', (state: number) => {
        this.emitBleStatus();
      });
    } catch (e) {
      this.logBleError('failed to register access stateChange listener', e);
    }
  }

  /** FlutterPlugin 生命周期：引擎销毁时释放 BLE、定时器与 Channel（HarmonyOS API：onDetachedFromEngine）。 */
  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.disposeBleResources();
    this.teardownFlutterChannels();
    this.binding = null;
  }

  /** 释放扫描、连接、MTU 协商、名称解析等 BLE 资源；可重复调用。 */
  private disposeBleResources(): void {
    this.clearAllConnectTimeouts();
    try {
      access.off('stateChange');
    } catch (e) {
      this.logBleError('failed to unregister access stateChange listener', e);
    }
    this.stopScan();
    this.disconnectAll();
    this.clearAllMtuNegotiationPending();
    this.lastScanPayloadByDevice.clear();
    this.resolveScanNamesViaGatt = false;
  }

  private clearAllMtuNegotiationPending(): void {
    this.mtuNegotiationPendingByDevice.forEach((pending: MtuNegotiationPending) => {
      if (!pending.settled && pending.timeoutId >= 0) {
        clearTimeout(pending.timeoutId);
      }
      if (!pending.settled) {
        pending.settled = true;
        try {
          pending.reject(new Error('plugin disposed'));
        } catch (rejectErr) {
          this.logBleError('failed to reject pending MTU negotiation', rejectErr as object);
        }
      }
    });
    this.mtuNegotiationPendingByDevice.clear();
    this.mtuNegotiationGenerationByDevice.clear();
  }

  private closeEventSink(sink: EventSink | null): void {
    if (sink == null) {
      return;
    }
    try {
      sink.endOfStream();
    } catch (e) {
      this.logBleError('failed to end EventSink stream', e);
    }
  }

  private releaseScanEventSink(): void {
    this.closeEventSink(this.scanSink);
    this.scanSink = null;
  }

  private releaseConnectionEventSink(): void {
    this.closeEventSink(this.connectionSink);
    this.connectionSink = null;
  }

  private releaseCharUpdateEventSink(): void {
    this.closeEventSink(this.charUpdateSink);
    this.charUpdateSink = null;
  }

  private releaseBleStatusEventSink(): void {
    this.closeEventSink(this.bleStatusSink);
    this.bleStatusSink = null;
  }

  /** 结束全部 EventChannel 流，触发 Dart 侧 Stream.onDone；Channel 仍保留供再次订阅。 */
  private endAllEventSinks(): void {
    this.releaseScanEventSink();
    this.releaseConnectionEventSink();
    this.releaseCharUpdateEventSink();
    this.releaseBleStatusEventSink();
  }

  private teardownFlutterChannels(): void {
    this.endAllEventSinks();

    this.scanChannel?.setStreamHandler(NO_OP_STREAM_HANDLER);
    this.connectionChannel?.setStreamHandler(NO_OP_STREAM_HANDLER);
    this.charUpdateChannel?.setStreamHandler(NO_OP_STREAM_HANDLER);
    this.bleStatusChannel?.setStreamHandler(NO_OP_STREAM_HANDLER);
    this.methodChannel?.setMethodCallHandler(null);

    this.lastConnectionStateByDevice.clear();
    this.methodChannel = null;
    this.scanChannel = null;
    this.connectionChannel = null;
    this.charUpdateChannel = null;
    this.bleStatusChannel = null;
  }

  private createStreamHandler(onListen: (sink: EventSink) => void, onCancel: () => void): StreamHandler {
    const h: StreamHandler = {
      onListen(_args: object, sink: EventSink): void {
        onListen(sink);
      },
      onCancel(_args: object): void {
        onCancel();
      }
    };
    return h;
  }

  private getArgs(call: MethodCall): Record<string, Object> {
    const keys: string[] = ['withServices', 'scanMode', 'requireLocationServicesEnabled', 'resolveDeviceNamesViaGatt',
      'deviceId', 'timeoutInMs',
      'serviceId', 'characteristicId', 'serviceInstanceId', 'characteristicInstanceId', 'value', 'mtuSize', 'priority'];
    const out: Record<string, Object> = {};
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const v: Object | undefined = call.argument(k) as Object | undefined;
      if (v !== undefined && v !== null) {
        out[k] = v;
      }
    }
    return out;
  }

  private bleErrorMessage(e: object): string {
    const err = e as BusinessError;
    return err.message ?? String(e);
  }

  /** 非致命路径（如广播解析失败）：记录警告并继续，不向 Dart 上报。 */
  private logBleWarning(context: string, e: object): void {
    console.warn(`ReactiveBleOhos: ${context}: ${this.bleErrorMessage(e)}`);
  }

  private logBleError(context: string, e: object): void {
    console.error(`ReactiveBleOhos: ${context}: ${this.bleErrorMessage(e)}`);
  }

  /**
   * 根据蓝牙适配器状态映射为 Dart BleStatus。
   * access.getState() 返回值：STATE_OFF(0), STATE_ON(1), STATE_TURNING_ON(2), STATE_TURNING_OFF(3), STATE_BLE_TURNING_ON(4), STATE_BLE_TURNING_OFF(5), STATE_BLE_ON(6)
   */
  private mapAccessStateToBleStatus(state: number): number {
    if (state === access.BluetoothState.STATE_ON || state === access.BluetoothState.STATE_BLE_ON) {
      return BLE_STATUS_READY;
    }
    if (state === access.BluetoothState.STATE_OFF || state === access.BluetoothState.STATE_BLE_TURNING_OFF ||
      state === access.BluetoothState.STATE_TURNING_OFF) {
      return BLE_STATUS_POWERED_OFF;
    }
    return BLE_STATUS_UNKNOWN;
  }

  private emitBleStatus(): void {
    try {
      const state = access.getState();
      const status = this.mapAccessStateToBleStatus(state);
      const payload: BleStatusPayload = { status };
      this.bleStatusSink?.success(payload);
    } catch (e) {
      const payload: BleStatusPayload = { status: BLE_STATUS_UNKNOWN };
      this.bleStatusSink?.success(payload);
    }
  }

  private buildConnectionPayload(deviceId: string, connectionState: number,
    failureMessage?: string): ConnectionPayload {
    const payload: ConnectionPayload = {
      deviceId,
      connectionState,
    };
    if (failureMessage !== undefined && failureMessage.length > 0) {
      payload.failureMessage = failureMessage;
    }
    return payload;
  }

  private emitConnectionPayload(payload: ConnectionPayload): void {
    this.lastConnectionStateByDevice.set(payload.deviceId, payload);
    try {
      this.connectionSink?.success(payload);
    } catch (e) {
      this.logBleError(`failed to emit connection update for ${payload.deviceId}`, e);
    }
  }

  private flushPendingConnectionUpdates(): void {
    if (this.connectionSink == null) {
      return;
    }
    this.lastConnectionStateByDevice.forEach((payload: ConnectionPayload, deviceId: string) => {
      try {
        this.connectionSink?.success(payload);
      } catch (e) {
        this.logBleError(`failed to flush connection update for ${deviceId}`, e);
      }
    });
  }

  private emitConnectionUpdate(deviceId: string, connectionState: number, failureMessage?: string): void {
    this.emitConnectionPayload(this.buildConnectionPayload(deviceId, connectionState, failureMessage));
  }

  private emitScanResult(device: ScanDevicePayload | null, error?: string): void {
    if (error !== undefined) {
      const payload: ScanResultPayload = { error };
      this.scanSink?.success(payload);
    } else if (device !== null) {
      const payload: ScanResultPayload = { device };
      this.scanSink?.success(payload);
    }
  }

  private emitCharValue(characteristic: CharRef, value?: number[], error?: string): void {
    const payload: CharUpdatePayload = { characteristic };
    if (error !== undefined) payload.error = error;
    if (value !== undefined) payload.value = value;
    try {
      this.charUpdateSink?.success(payload);
    } catch (e) {
      this.logBleError(`failed to emit characteristic update for ${characteristic.deviceId}`, e);
    }
  }

  /**
   * 将 Dart scanMode 映射为鸿蒙 ble.ScanDuty。
   * Dart: -1 opportunistic, 0 lowPower, 1 balanced, 2 lowLatency
   * 鸿蒙 ScanDuty: SCAN_MODE_LOW_POWER(0), SCAN_MODE_BALANCED(1), SCAN_MODE_LOW_LATENCY(2) 等
   */
  private mapScanModeToDuty(scanMode: number): number {
    if (scanMode === 2) return 2; // lowLatency -> SCAN_MODE_LOW_LATENCY
    if (scanMode === 1) return 1; // balanced -> SCAN_MODE_BALANCED
    return 0; // 0 或 -1 -> SCAN_MODE_LOW_POWER
  }

  private stopScan(): void {
    if (!this.isScanning && this.scanResultHandler == null) {
      return;
    }
    const queuedCount = this.nameRequestQueue.length;
    const pendingCount = this.pendingNameRequests.size;

    if (this.scanResultHandler != null) {
      try {
        ble.off('BLEDeviceFind', this.scanResultHandler);
      } catch (e) {
        this.logBleError('failed to unregister BLEDeviceFind handler', e);
      }
      this.scanResultHandler = null;
    } else {
      try {
        ble.off('BLEDeviceFind');
      } catch (e) {
        this.logBleError('failed to unregister BLEDeviceFind (no handler ref)', e);
      }
    }

    if (this.isScanning) {
      try {
        ble.stopBLEScan();
      } catch (e) {
        this.logBleError('failed to stop BLE scan', e);
      }
    }

    this.isScanning = false;
    this.cleanupPendingNameRequests();
    if (queuedCount > 0 || pendingCount > 0) {
      console.info(
        `ReactiveBleOhos: stopScan cleared name resolution (queued=${queuedCount}, pending=${pendingCount})`
      );
    }
  }

  private closeTemporaryGattClient(deviceId: string, client: ble.GattClientDevice): void {
    try {
      client.close();
    } catch (e) {
      this.logBleError(`failed to close temporary GattClient for ${deviceId}`, e);
    }
  }

  private clearScanDiscoveryCache(): void {
    this.discoveredDeviceIds.clear();
    this.discoveredDeviceIdOrder = [];
    this.completedNameRequests.clear();
    this.nameRequestQueue = [];
    this.lastScanPayloadByDevice.clear();
  }

  private trimScanDiscoveryCacheIfNeeded(): void {
    if (this.discoveredDeviceIdOrder.length < ReactiveBleOhosPlugin.MAX_DISCOVERED_DEVICES) {
      return;
    }
    const removeCount = Math.min(ReactiveBleOhosPlugin.SCAN_CACHE_TRIM_BATCH, this.discoveredDeviceIdOrder.length);
    const removed = this.discoveredDeviceIdOrder.splice(0, removeCount);
    for (let i = 0; i < removed.length; i++) {
      const id = removed[i];
      this.discoveredDeviceIds.delete(id);
      this.completedNameRequests.delete(id);
      this.lastScanPayloadByDevice.delete(id);
    }
    this.nameRequestQueue = this.nameRequestQueue.filter(
      (id: string) => this.discoveredDeviceIds.has(id) || this.pendingNameRequests.has(id)
    );
  }

  private cacheLastScanPayload(device: ScanDevicePayload): void {
    this.lastScanPayloadByDevice.set(device.id, device);
  }

  private buildScanPayloadWithResolvedName(deviceId: string, name: string): ScanDevicePayload {
    const cached = this.lastScanPayloadByDevice.get(deviceId);
    if (cached != null) {
      return {
        id: deviceId,
        name,
        rssi: cached.rssi,
        serviceUuids: cached.serviceUuids,
        serviceData: cached.serviceData,
        manufacturerData: cached.manufacturerData,
        connectable: cached.connectable,
      };
    }
    return {
      id: deviceId,
      name,
      rssi: 0,
      serviceUuids: [],
      serviceData: {},
      manufacturerData: [],
      connectable: CONNECTABLE_UNKNOWN,
    };
  }

  /** 记录已发现设备；若为新设备返回 true，已存在则返回 false */
  private trackDiscoveredDevice(deviceId: string): boolean {
    this.trimScanDiscoveryCacheIfNeeded();
    if (this.discoveredDeviceIds.has(deviceId)) {
      return false;
    }
    this.discoveredDeviceIds.add(deviceId);
    this.discoveredDeviceIdOrder.push(deviceId);
    return true;
  }

  private clearNameRequestTimeout(deviceId: string): void {
    const timeoutId = this.nameRequestTimeoutIdByDevice.get(deviceId);
    if (timeoutId !== undefined && timeoutId >= 0) {
      clearTimeout(timeoutId);
    }
    this.nameRequestTimeoutIdByDevice.delete(deviceId);
  }

  private cancelNameRequestForDevice(deviceId: string): void {
    this.clearNameRequestTimeout(deviceId);
    const client = this.activeGattClients.get(deviceId);
    if (client != null) {
      this.closeTemporaryGattClient(deviceId, client);
      this.activeGattClients.delete(deviceId);
    }
    this.pendingNameRequests.delete(deviceId);
  }

  private cleanupPendingNameRequests(): void {
    this.nameRequestTimeoutIdByDevice.forEach((_timeoutId: number, deviceId: string) => {
      this.clearNameRequestTimeout(deviceId);
    });
    this.nameRequestTimeoutIdByDevice.clear();
    this.activeGattClients.forEach((client: ble.GattClientDevice, deviceId: string) => {
      this.closeTemporaryGattClient(deviceId, client);
    });
    this.activeGattClients.clear();
    this.pendingNameRequests.clear();
    this.nameRequestQueue = [];
    this.clearScanDiscoveryCache();
  }

  private processNameRequestQueue(): void {
    while (
      this.nameRequestQueue.length > 0 &&
      this.pendingNameRequests.size < ReactiveBleOhosPlugin.MAX_CONCURRENT_NAME_REQUESTS
    ) {
      const deviceId = this.nameRequestQueue.shift();
      if (!deviceId) break;
      if (this.pendingNameRequests.has(deviceId) || this.completedNameRequests.has(deviceId)) {
        continue;
      }
      if (!this.isScanning) {
        continue;
      }
      this.executeNameRequest(deviceId);
    }
  }

  private executeNameRequest(deviceId: string): void {
    if (!this.isScanning) return;

    this.pendingNameRequests.add(deviceId);
    let tempClient: ble.GattClientDevice;
    try {
      tempClient = ble.createGattClientDevice(deviceId);
    } catch (e) {
      this.pendingNameRequests.delete(deviceId);
      this.processNameRequestQueue();
      return;
    }
    this.activeGattClients.set(deviceId, tempClient);
    this.clearNameRequestTimeout(deviceId);

    const timeoutId = setTimeout(() => {
      if (this.activeGattClients.get(deviceId) !== tempClient) {
        return;
      }
      this.finalizeNameRequest(deviceId, tempClient, null);
    }, 3000) as number;
    this.nameRequestTimeoutIdByDevice.set(deviceId, timeoutId);

    tempClient.getDeviceName().then((resolvedName: string) => {
      this.clearNameRequestTimeout(deviceId);
      this.finalizeNameRequest(deviceId, tempClient, resolvedName);
    }).catch((e: object) => {
      this.clearNameRequestTimeout(deviceId);
      this.logBleError(`getDeviceName failed for scan name resolution ${deviceId}`, e);
      this.finalizeNameRequest(deviceId, tempClient, null);
    });
  }

  private finalizeNameRequest(deviceId: string, client: ble.GattClientDevice, name: string | null): void {
    if (this.activeGattClients.get(deviceId) !== client) {
      return;
    }
    try {
      this.closeTemporaryGattClient(deviceId, client);
    } finally {
      this.clearNameRequestTimeout(deviceId);
      this.activeGattClients.delete(deviceId);
      this.pendingNameRequests.delete(deviceId);
      this.completedNameRequests.add(deviceId);
    }
    try {
      if (name != null && name.length > 0 && this.isScanning) {
        const updated = this.buildScanPayloadWithResolvedName(deviceId, name);
        this.cacheLastScanPayload(updated);
        this.emitScanResult(updated);
      }
    } catch (e) {
      this.logBleError(`failed to emit resolved scan name for ${deviceId}`, e);
    }
    this.processNameRequestQueue();
  }

  private handleBleScanResult(item: ble.ScanResult): void {
    let name = '';
    let serviceUuids: string[] = [];
    let manufacturerData: number[] = [];
    try {
      const arrayBuf = this.toArrayBufferForAdv(item.data as object);
      if (arrayBuf != null && arrayBuf.byteLength > 0) {
        serviceUuids = this.parseServiceUuidsFromAdvData(arrayBuf);
        manufacturerData = this.parseManufacturerData(arrayBuf);
        const advName = this.parseLocalNameFromAdvData(arrayBuf);
        if (advName.length > 0) name = advName;
      }
    } catch (parseErr) {
      this.logBleWarning(`failed to parse scan advertisement for ${item.deviceId}`, parseErr);
    }
    const connectable = item.connectable === true ? CONNECTABLE_AVAILABLE :
      (item.connectable === false ? CONNECTABLE_UNAVAILABLE : CONNECTABLE_UNKNOWN);
    const device: ScanDevicePayload = {
      id: item.deviceId,
      name,
      rssi: item.rssi ?? 0,
      serviceUuids,
      serviceData: {},
      manufacturerData,
      connectable,
    };
    this.cacheLastScanPayload(device);
    this.emitScanResult(device);

    // 广播名优先；仅当启用 resolveScanNamesViaGatt 且名称为空时才创建临时 GattClient
    if (this.resolveScanNamesViaGatt && name.length === 0 && this.trackDiscoveredDevice(item.deviceId)) {
      if (!this.pendingNameRequests.has(item.deviceId) &&
          !this.completedNameRequests.has(item.deviceId) &&
          !this.nameRequestQueue.includes(item.deviceId)) {
        if (this.nameRequestQueue.length >= ReactiveBleOhosPlugin.MAX_DISCOVERED_DEVICES) {
          this.nameRequestQueue.shift();
        }
        this.nameRequestQueue.push(item.deviceId);
        this.processNameRequestQueue();
      }
    }
  }

  private clearConnectTimeoutForDevice(deviceId: string): void {
    const timeoutId = this.connectTimeoutIdByDevice.get(deviceId);
    if (timeoutId !== undefined && timeoutId >= 0) {
      clearTimeout(timeoutId);
    }
    this.connectTimeoutIdByDevice.delete(deviceId);
  }

  private clearAllConnectTimeouts(): void {
    this.connectTimeoutIdByDevice.forEach((timeoutId: number) => {
      if (timeoutId >= 0) {
        clearTimeout(timeoutId);
      }
    });
    this.connectTimeoutIdByDevice.clear();
  }

  private isActiveConnectSession(deviceId: string, sessionId: number): boolean {
    return this.connectSessionByDevice.get(deviceId) === sessionId;
  }

  private isActiveConnectStateHandler(deviceId: string,
    onStateChange: (state: ble.BLEConnectionChangeState) => void): boolean {
    return this.connectStateHandlerByDevice.get(deviceId) === onStateChange;
  }

  private allocateConnectSessionId(): number {
    if (this.connectSessionCounter >= ReactiveBleOhosPlugin.MAX_CONNECT_SESSION_ID) {
      this.connectSessionCounter = 0;
      this.connectSessionByDevice.clear();
    }
    this.connectSessionCounter++;
    return this.connectSessionCounter;
  }

  /** 设备已在 connectedDevices 时，等待或重新发起 GATT 发现后再上报 CONNECTED */
  private emitConnectedWhenGattReady(deviceId: string): void {
    const gatt = this.connectedDevices.get(deviceId);
    if (gatt == null) {
      return;
    }
    let promise = this.gattServicesReady.get(deviceId);
    if (promise == null) {
      this.beginGattServiceDiscovery(gatt, deviceId);
      promise = this.gattServicesReady.get(deviceId);
    }
    if (promise == null) {
      return;
    }
    promise.then(() => {
      if (this.connectedDevices.has(deviceId)) {
        this.emitConnectionUpdate(deviceId, CONN_STATE_CONNECTED);
      }
    }).catch(() => {
      if (this.connectedDevices.has(deviceId)) {
        this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED, 'Descriptor discovery failed');
      }
    });
  }

  private unregisterConnectStateHandler(deviceId: string, client: ble.GattClientDevice): void {
    const handler = this.connectStateHandlerByDevice.get(deviceId);
    if (handler != null) {
      try {
        client.off('BLEConnectionStateChange', handler);
      } catch (e) {
        this.logBleError(`failed to unregister connection state handler for ${deviceId}`, e);
      }
      this.connectStateHandlerByDevice.delete(deviceId);
    }
  }

  private clearPendingConnectState(deviceId: string, sessionId: number): void {
    if (!this.isActiveConnectSession(deviceId, sessionId)) {
      return;
    }
    this.connectSessionByDevice.delete(deviceId);
    this.clearConnectTimeoutForDevice(deviceId);
    if (this.connectingDeviceId === deviceId) {
      this.connectingDeviceId = null;
      this.connectingClient = null;
    }
  }

  private abortPendingConnect(deviceId: string, sessionId: number, client: ble.GattClientDevice,
    failureMessage: string): void {
    if (!this.isActiveConnectSession(deviceId, sessionId)) {
      return;
    }
    this.cancelPendingConnectClient(deviceId, client);
    this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED, failureMessage);
  }

  /** 关闭并注销进行中的连接，使旧 session 回调失效；不发送 DISCONNECTED（用于被新连接取代） */
  private cancelPendingConnectClient(deviceId: string, client: ble.GattClientDevice): void {
    this.connectSessionByDevice.delete(deviceId);
    this.clearConnectTimeoutForDevice(deviceId);
    this.unregisterMtuChangeCache(deviceId, client);
    this.unregisterConnectStateHandler(deviceId, client);
    try {
      client.close();
    } catch (e) {
      this.logBleError(`failed to close GattClient while cancelling connect for ${deviceId}`, e);
    }
    this.clearGattServicesReady(deviceId);
    if (this.connectingDeviceId === deviceId) {
      this.connectingDeviceId = null;
      this.connectingClient = null;
    }
  }

  /** 同一设备重复 connect 时，先取消尚未完成的连接，避免 session 被覆盖后旧回调误判 */
  private supersedePendingConnect(deviceId: string): void {
    if (this.connectingDeviceId !== deviceId || this.connectingClient == null) {
      return;
    }
    this.cancelPendingConnectClient(deviceId, this.connectingClient);
  }

  private clearGattServicesReady(deviceId?: string): void {
    if (deviceId !== undefined) {
      this.gattServicesReady.delete(deviceId);
      return;
    }
    this.gattServicesReady.clear();
  }

  private delayMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private hasCccdDescriptor(descriptors: ble.BLEDescriptor[]): boolean {
    const cccdUuid = ReactiveBleOhosPlugin.CCCD_DESCRIPTOR_UUID;
    for (let k = 0; k < descriptors.length; k++) {
      const descUuid = this.normalizeUuid(this.uuidStr(descriptors[k].descriptorUuid));
      if (descUuid === cccdUuid) {
        return true;
      }
    }
    return false;
  }

  /** 服务列表非空，且需 CCCD 的 notify/indicate 特征已包含 0x2902 descriptor */
  private areGattServicesReady(services: ble.GattService[]): boolean {
    if (services.length === 0) {
      return false;
    }
    let hasCharacteristic = false;
    for (let i = 0; i < services.length; i++) {
      const chars = services[i].characteristics ?? [];
      for (let j = 0; j < chars.length; j++) {
        hasCharacteristic = true;
        const c = chars[j];
        const needsCccd = c.properties?.notify === true || c.properties?.indicate === true;
        if (needsCccd && !this.hasCccdDescriptor(c.descriptors ?? [])) {
          return false;
        }
      }
    }
    return hasCharacteristic;
  }

  private async waitForGattServicesReady(gatt: ble.GattClientDevice, deviceId: string): Promise<ble.GattService[]> {
    let delay = ReactiveBleOhosPlugin.GATT_READY_INITIAL_DELAY_MS;
    let lastServices: ble.GattService[] = [];
    for (let attempt = 0; attempt < ReactiveBleOhosPlugin.GATT_READY_MAX_ATTEMPTS; attempt++) {
      if (!this.connectedDevices.has(deviceId)) {
        throw new Error('device disconnected during GATT discovery');
      }
      try {
        const services = await gatt.getServices();
        if (this.areGattServicesReady(services)) {
          return services;
        }
        lastServices = services;
      } catch (e) {
        this.logBleError(`GATT getServices attempt failed for ${deviceId}`, e);
      }
      await this.delayMs(delay);
      delay = Math.min(delay * 2, ReactiveBleOhosPlugin.GATT_READY_MAX_DELAY_MS);
    }
    if (this.areGattServicesReady(lastServices)) {
      return lastServices;
    }
    if (lastServices.length > 0) {
      throw new Error('Descriptor discovery failed');
    }
    throw new Error('GATT service discovery timed out');
  }

  private onGattDiscoverySucceeded(deviceId: string, client: ble.GattClientDevice): void {
    if (this.connectedDevices.get(deviceId) !== client) {
      return;
    }
    this.registerMtuChangeCache(deviceId, client);
    this.emitConnectionUpdate(deviceId, CONN_STATE_CONNECTED);
  }

  private onGattDiscoveryFailed(deviceId: string, client: ble.GattClientDevice, failureMessage: string): void {
    if (this.connectedDevices.get(deviceId) !== client) {
      return;
    }
    this.removeCharChangeCallbacksForDevice(deviceId, client);
    this.connectedDevices.delete(deviceId);
    this.clearGattServicesReady(deviceId);
    this.unregisterMtuChangeCache(deviceId, client);
    this.unregisterConnectStateHandler(deviceId, client);
    try {
      client.close();
    } catch (e) {
      this.logBleError(`failed to close GattClient after GATT discovery failed for ${deviceId}`, e);
    }
    this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED, failureMessage);
  }

  private beginGattServiceDiscovery(gatt: ble.GattClientDevice, deviceId: string): void {
    const promise = this.waitForGattServicesReady(gatt, deviceId);
    this.gattServicesReady.set(deviceId, promise);
  }

  private normalizeNegotiatedMtu(mtu: number, deviceId: string): number {
    if (mtu >= ReactiveBleOhosPlugin.BLE_MTU_MIN) {
      return mtu;
    }
    const actual = ReactiveBleOhosPlugin.BLE_ATT_DEFAULT_MTU;
    this.logBleError(`MTU negotiation returned invalid value ${mtu} for ${deviceId}, using default ${actual}`,
      new Error('invalid MTU'));
    return actual;
  }

  private isActiveMtuNegotiation(deviceId: string, pending: MtuNegotiationPending): boolean {
    if (pending.settled) {
      return false;
    }
    const activeGeneration = this.mtuNegotiationGenerationByDevice.get(deviceId);
    if (activeGeneration === undefined || pending.generation !== activeGeneration) {
      return false;
    }
    return this.mtuNegotiationPendingByDevice.get(deviceId) === pending;
  }

  /**
   * 设备可能协商出低于请求值的 MTU；若 MTU 大于当前请求的 clampedMtu，多为被取代的旧协商回调，应忽略。
   */
  private isMtuPlausibleForPendingRequest(mtu: number, pending: MtuNegotiationPending): boolean {
    return mtu <= pending.clampedMtu;
  }

  private onMtuChanged(deviceId: string, mtu: number): void {
    const pending = this.mtuNegotiationPendingByDevice.get(deviceId);
    if (pending != null && this.isActiveMtuNegotiation(deviceId, pending)) {
      if (!this.isMtuPlausibleForPendingRequest(mtu, pending)) {
        this.logBleError(
          `ignoring stale MTU ${mtu} for ${deviceId} (active request ${pending.clampedMtu})`,
          new Error('stale MTU callback'));
        return;
      }
      pending.settled = true;
      if (pending.timeoutId >= 0) {
        clearTimeout(pending.timeoutId);
      }
      const actual = this.normalizeNegotiatedMtu(mtu, deviceId);
      this.negotiatedMtuByDevice.set(deviceId, actual);
      pending.resolve(actual);
      this.mtuNegotiationPendingByDevice.delete(deviceId);
      return;
    }
    if (mtu >= ReactiveBleOhosPlugin.BLE_MTU_MIN) {
      this.negotiatedMtuByDevice.set(deviceId, mtu);
    }
  }

  private supersedeMtuNegotiation(deviceId: string): void {
    const existing = this.mtuNegotiationPendingByDevice.get(deviceId);
    if (existing != null && !existing.settled) {
      existing.settled = true;
      if (existing.timeoutId >= 0) {
        clearTimeout(existing.timeoutId);
      }
      existing.reject(new Error('superseded by new MTU negotiation'));
      this.mtuNegotiationPendingByDevice.delete(deviceId);
    }
  }

  private allocateMtuNegotiationGeneration(deviceId: string): number {
    const next = (this.mtuNegotiationGenerationByDevice.get(deviceId) ?? 0) + 1;
    this.mtuNegotiationGenerationByDevice.set(deviceId, next);
    return next;
  }

  private ensureMtuChangeHandler(deviceId: string, client: ble.GattClientDevice): void {
    if (this.mtuChangeHandlerByDevice.has(deviceId)) {
      return;
    }
    const handler = (mtu: number): void => {
      this.onMtuChanged(deviceId, mtu);
    };
    this.mtuChangeHandlerByDevice.set(deviceId, handler);
    try {
      client.on('BLEMtuChange', handler);
    } catch (e) {
      this.logBleError(`failed to register BLEMtuChange handler for ${deviceId}`, e);
    }
  }

  private clearMtuNegotiationPending(deviceId: string, reason: string): void {
    const pending = this.mtuNegotiationPendingByDevice.get(deviceId);
    if (pending == null || pending.settled) {
      return;
    }
    pending.settled = true;
    if (pending.timeoutId >= 0) {
      clearTimeout(pending.timeoutId);
    }
    pending.reject(new Error(reason));
    this.mtuNegotiationPendingByDevice.delete(deviceId);
  }

  private registerMtuChangeCache(deviceId: string, client: ble.GattClientDevice): void {
    this.ensureMtuChangeHandler(deviceId, client);
  }

  private unregisterMtuChangeCache(deviceId: string, client?: ble.GattClientDevice): void {
    this.clearMtuNegotiationPending(deviceId, 'MTU negotiation cancelled');
    const handler = this.mtuChangeHandlerByDevice.get(deviceId);
    if (handler != null && client != null) {
      try {
        client.off('BLEMtuChange', handler);
      } catch (e) {
        this.logBleError(`failed to unregister BLEMtuChange handler for ${deviceId}`, e);
      }
    }
    this.mtuChangeHandlerByDevice.delete(deviceId);
    this.negotiatedMtuByDevice.delete(deviceId);
    this.mtuNegotiationGenerationByDevice.delete(deviceId);
  }

  private negotiateMtuWithCallback(gatt: ble.GattClientDevice, deviceId: string,
    requestedMtu: number): Promise<number> {
    const clampedMtu = Math.max(ReactiveBleOhosPlugin.BLE_MTU_MIN,
      Math.min(ReactiveBleOhosPlugin.BLE_MTU_MAX, requestedMtu));
    this.ensureMtuChangeHandler(deviceId, gatt);
    this.supersedeMtuNegotiation(deviceId);
    const generation = this.allocateMtuNegotiationGeneration(deviceId);
    return new Promise<number>((resolve: (mtu: number) => void, reject: (reason: Error) => void) => {
      const pending: MtuNegotiationPending = {
        settled: false,
        clampedMtu,
        generation,
        resolve,
        reject,
        timeoutId: -1,
      };
      this.mtuNegotiationPendingByDevice.set(deviceId, pending);
      pending.timeoutId = setTimeout(() => {
        if (!this.isActiveMtuNegotiation(deviceId, pending)) {
          return;
        }
        pending.settled = true;
        this.mtuNegotiationPendingByDevice.delete(deviceId);
        reject(new Error('MTU negotiation timeout'));
      }, ReactiveBleOhosPlugin.MTU_NEGOTIATE_TIMEOUT_MS) as number;
      try {
        gatt.setBLEMtuSize(clampedMtu);
      } catch (e) {
        if (this.isActiveMtuNegotiation(deviceId, pending)) {
          pending.settled = true;
          if (pending.timeoutId >= 0) {
            clearTimeout(pending.timeoutId);
          }
          this.mtuNegotiationPendingByDevice.delete(deviceId);
          reject(new Error(this.bleErrorMessage(e)));
        }
      }
    });
  }

  private async getGattServicesWhenReady(deviceId: string): Promise<ble.GattService[] | null> {
    const gatt = this.connectedDevices.get(deviceId);
    if (gatt == null) {
      return null;
    }
    let promise = this.gattServicesReady.get(deviceId);
    if (promise == null) {
      promise = this.waitForGattServicesReady(gatt, deviceId);
      this.gattServicesReady.set(deviceId, promise);
    }
    try {
      return await promise;
    } catch (e) {
      this.gattServicesReady.delete(deviceId);
      this.logBleError(`GATT services not ready for ${deviceId}`, e);
      return null;
    }
  }

  private disconnectAll(): void {
    this.clearGattServicesReady();
    this.clearAllConnectTimeouts();
    this.connectSessionByDevice.clear();

    this.connectedDevices.forEach((gatt: ble.GattClientDevice, deviceId: string) => {
      this.removeCharChangeCallbacksForDevice(deviceId, gatt);
      this.unregisterMtuChangeCache(deviceId, gatt);
      this.unregisterConnectStateHandler(deviceId, gatt);
    });
    this.charChangeCallbacks.clear();
    this.connectStateHandlerByDevice.clear();

    this.connectedDevices.forEach((gatt: ble.GattClientDevice, deviceId: string) => {
      try {
        gatt.disconnect();
        gatt.close();
      } catch (e) {
        this.logBleError(`failed to close GattClient for ${deviceId}`, e);
      }
    });
    this.connectedDevices.clear();

    if (this.connectingClient != null && this.connectingDeviceId != null) {
      this.unregisterConnectStateHandler(this.connectingDeviceId, this.connectingClient);
      try {
        this.connectingClient.close();
      } catch (e) {
        this.logBleError(`failed to close connectingClient for ${this.connectingDeviceId}`, e);
      }
      this.connectingClient = null;
      this.connectingDeviceId = null;
    }
  }

  /**
   * 将 BLECharacteristic.characteristicValue 转为 Dart 层使用的 number[]。
   * HarmonyOS 返回值可能是 ArrayBuffer、Uint8Array 或 number[]。
   */
  private characteristicValueToNumberArray(raw: object | null | undefined): number[] {
    if (raw == null) {
      return [];
    }
    if (raw instanceof ArrayBuffer) {
      return Array.from(new Uint8Array(raw));
    }
    if (raw instanceof Uint8Array) {
      return Array.from(raw);
    }
    if (Array.isArray(raw)) {
      const arr = raw as number[];
      const out: number[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(arr[i]);
      }
      return out;
    }
    return [];
  }

  /**
   * 将 BLE 广播数据转为 ArrayBuffer。OHOS ScanResult.data 可能为 Uint8Array 等，DataView 仅接受 ArrayBuffer。
   */
  private toArrayBufferForAdv(raw: object): ArrayBuffer | null {
    if (raw == null) return null;
    if (raw instanceof ArrayBuffer) return raw;
    if (raw instanceof Uint8Array) {
      const copy = new ArrayBuffer(raw.length);
      const view = new Uint8Array(copy);
      for (let i = 0; i < raw.length; i++) {
        view[i] = raw[i];
      }
      return copy;
    }
    return null;
  }

  /**
   * 从广播数据中解析 16/128 位服务 UUID 列表。
   * BLE AD 格式：byte0=len(含 type 与 data), byte1=type, byte2..=data，故 data 长度为 len-1。
   */
  private parseServiceUuidsFromAdvData(data: ArrayBuffer): string[] {
    const uuids: string[] = [];
    const view = new DataView(data);
    let offset = 0;
    while (offset < view.byteLength) {
      const len = view.getUint8(offset);
      if (len === 0 || offset + 1 + len > view.byteLength) break;
      const type = view.getUint8(offset + 1);
      const dataLen = len - 1;
      if ((type === 0x02 || type === 0x03) && dataLen >= 2) {
        for (let i = 0; i + 2 <= dataLen; i += 2) {
          const u = view.getUint16(offset + 2 + i, true);
          uuids.push('0000' + u.toString(16).padStart(4, '0') + '-0000-1000-8000-00805f9b34fb');
        }
      }
      if ((type === 0x06 || type === 0x07) && dataLen >= 16) {
        for (let i = 0; i + 16 <= dataLen; i += 16) {
          let s = '';
          for (let j = 0; j < 16; j++) {
            s += view.getUint8(offset + 2 + i + j).toString(16).padStart(2, '0');
          }
          uuids.push(s.replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5'));
        }
      }
      offset += 1 + len;
    }
    return uuids;
  }

  /**
   * 从广播数据中解析厂商数据（所有 AD type 0xFF 的 payload 按出现顺序拼接）。
   * 每条 0xFF 结构含 companyId(2B) + 厂商自定义数据，与 Dart DiscoveredDevice.manufacturerData 扁平数组一致。
   */
  private parseManufacturerData(data: ArrayBuffer): number[] {
    const arr: number[] = [];
    const view = new DataView(data);
    let offset = 0;
    while (offset < view.byteLength) {
      const len = view.getUint8(offset);
      if (len === 0 || offset + 1 + len > view.byteLength) break;
      const type = view.getUint8(offset + 1);
      if (type === 0xFF) {
        for (let i = 0; i < len - 1; i++) {
          arr.push(view.getUint8(offset + 2 + i));
        }
      }
      offset += 1 + len;
    }
    return arr;
  }

  /** 从广播数据中解析本地名称，优先 Complete Local Name (0x09)，其次 Short Name (0x08) */
  private parseLocalNameFromAdvData(data: ArrayBuffer): string {
    const view = new DataView(data);
    let shortName = '';
    let offset = 0;
    while (offset < view.byteLength) {
      const len = view.getUint8(offset);
      if (len === 0 || offset + 1 + len > view.byteLength) break;
      const type = view.getUint8(offset + 1);
      const dataLen = len - 1;
      if (type === 0x09) {
        let s = '';
        for (let i = 0; i < dataLen; i++) {
          s += String.fromCharCode(view.getUint8(offset + 2 + i));
        }
        return s;
      }
      if (type === 0x08 && shortName.length === 0) {
        for (let i = 0; i < dataLen; i++) {
          shortName += String.fromCharCode(view.getUint8(offset + 2 + i));
        }
      }
      offset += 1 + len;
    }
    return shortName;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    const method = call.method;
    const args = this.getArgs(call);

    try {
      switch (method) {
        case 'initialize':
          this.emitBleStatus();
          result.success(null);
          break;

        case 'deinitialize':
          this.disposeBleResources();
          this.endAllEventSinks();
          result.success(null);
          break;

        case 'scanForDevices': {
          const withServices = args['withServices'] as string[] | undefined ?? [];
          const scanMode = (args['scanMode'] as number) ?? 1;
          const requireLocationServicesEnabled = (args['requireLocationServicesEnabled'] as boolean) ?? false;
          this.resolveScanNamesViaGatt = (args['resolveDeviceNamesViaGatt'] as boolean) ?? false;

          this.stopScan();

          const filterArray: ble.ScanFilter[] = [];
          for (let i = 0; i < withServices.length; i++) {
            const filter: ble.ScanFilter = { serviceUuid: withServices[i] as string };
            filterArray.push(filter);
          }
          const scanOption: ble.ScanOptions = {
            dutyMode: this.mapScanModeToDuty(scanMode) as ble.ScanDuty,
            matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
            interval: 0,
          };
          this.scanResultHandler = (data: Array<ble.ScanResult>): void => {
            if (data.length === 0) return;
            for (let i = 0; i < data.length; i++) {
              this.handleBleScanResult(data[i]);
            }
          };
          ble.on('BLEDeviceFind', this.scanResultHandler);
          if (filterArray.length === 0) {
            ble.startBLEScan(null, scanOption);
          } else {
            ble.startBLEScan(filterArray, scanOption);
          }
          this.isScanning = true;
          result.success(null);
          break;
        }

        case 'connectToDevice': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const timeoutInMs = (args['timeoutInMs'] as number) ?? 0;

          if (this.connectedDevices.has(deviceId)) {
            this.emitConnectedWhenGattReady(deviceId);
            result.success(null);
            break;
          }
          this.supersedePendingConnect(deviceId);
          this.emitConnectionUpdate(deviceId, CONN_STATE_CONNECTING);
          let client: ble.GattClientDevice | null = null;
          try {
            client = ble.createGattClientDevice(deviceId);
            const sessionId = this.allocateConnectSessionId();
            this.connectSessionByDevice.set(deviceId, sessionId);
            this.connectingDeviceId = deviceId;
            this.connectingClient = client;

            const onStateChange = (state: ble.BLEConnectionChangeState) => {
              if (state.deviceId !== deviceId) {
                return;
              }
              if (!this.isActiveConnectStateHandler(deviceId, onStateChange)) {
                return;
              }
              const isPendingSession = this.isActiveConnectSession(deviceId, sessionId);

              if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
                if (!isPendingSession) {
                  return;
                }
                this.clearPendingConnectState(deviceId, sessionId);
                this.connectedDevices.set(deviceId, client);
                this.beginGattServiceDiscovery(client, deviceId);
                this.gattServicesReady.get(deviceId)!.then(() => {
                  this.onGattDiscoverySucceeded(deviceId, client);
                }).catch((_err: object) => {
                  const msg = (_err as Error).message ?? 'Descriptor discovery failed';
                  this.onGattDiscoveryFailed(deviceId, client, msg);
                });
              } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
                const stateWithCode = state as ConnStateWithCode;
                const msg = stateWithCode.code !== undefined ? `code: ${stateWithCode.code}` : 'disconnected';
                if (isPendingSession) {
                  this.abortPendingConnect(deviceId, sessionId, client, msg);
                } else if (this.connectedDevices.get(deviceId) === client) {
                  this.removeCharChangeCallbacksForDevice(deviceId, client);
                  this.connectedDevices.delete(deviceId);
                  this.clearGattServicesReady(deviceId);
                  this.unregisterMtuChangeCache(deviceId, client);
                  this.unregisterConnectStateHandler(deviceId, client);
                  try {
                    client.close();
                  } catch (e) {
                    this.logBleError(`failed to close GattClient on disconnect for ${deviceId}`, e);
                  }
                  this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED, msg);
                }
              }
            };
            this.connectStateHandlerByDevice.set(deviceId, onStateChange);
            client.on('BLEConnectionStateChange', onStateChange);
            client.connect();

            if (timeoutInMs > 0) {
              this.clearConnectTimeoutForDevice(deviceId);
              const timeoutId = setTimeout(() => {
                this.connectTimeoutIdByDevice.delete(deviceId);
                if (!this.isActiveConnectSession(deviceId, sessionId)) {
                  return;
                }
                if (this.connectedDevices.has(deviceId)) {
                  return;
                }
                this.abortPendingConnect(deviceId, sessionId, client, 'Connection timeout');
              }, timeoutInMs);
              this.connectTimeoutIdByDevice.set(deviceId, timeoutId as number);
            }
            result.success(null);
          } catch (e) {
            this.clearConnectTimeoutForDevice(deviceId);
            this.connectSessionByDevice.delete(deviceId);
            if (client != null) {
              this.unregisterConnectStateHandler(deviceId, client);
              try {
                client.close();
              } catch (closeErr) {
                this.logBleError(`failed to close GattClient after connect error for ${deviceId}`, closeErr);
              }
            }
            const msg = this.bleErrorMessage(e);
            this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED, msg);
            this.connectingDeviceId = null;
            this.connectingClient = null;
            result.error('connectToDevice', msg, null);
          }
          break;
        }

        case 'disconnectFromDevice': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          this.connectSessionByDevice.delete(deviceId);
          this.clearConnectTimeoutForDevice(deviceId);
          this.clearMtuNegotiationPending(deviceId, 'device disconnected');
          this.cancelNameRequestForDevice(deviceId);
          const gatt = this.connectedDevices.get(deviceId);
          this.removeCharChangeCallbacksForDevice(deviceId, gatt ?? undefined);
          this.clearGattServicesReady(deviceId);
          if (gatt != null) {
            this.unregisterMtuChangeCache(deviceId, gatt);
            this.unregisterConnectStateHandler(deviceId, gatt);
            try {
              gatt.disconnect();
              gatt.close();
            } catch (e) {
              this.logBleError(`failed to disconnect GattClient for ${deviceId}`, e);
            }
            this.connectedDevices.delete(deviceId);
          }
          if (this.connectingDeviceId === deviceId && this.connectingClient != null) {
            this.unregisterConnectStateHandler(deviceId, this.connectingClient);
            try {
              this.connectingClient.close();
            } catch (e) {
              this.logBleError(`failed to close pending connecting GattClient for ${deviceId}`, e);
            }
            this.connectingClient = null;
            this.connectingDeviceId = null;
          }
          this.emitConnectionUpdate(deviceId, CONN_STATE_DISCONNECTED);
          result.success(null);
          break;
        }

        case 'discoverServices': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          if (!this.connectedDevices.has(deviceId)) {
            result.error('discoverServices', 'device not connected', null);
            break;
          }
          try {
            const services = await this.getGattServicesWhenReady(deviceId);
            if (services == null) {
              result.error('discoverServices', 'GATT services not ready', null);
              break;
            }
            const list = this.buildDiscoveredServicesList(deviceId, services);
            result.success(list);
          } catch (e) {
            const msg = this.bleErrorMessage(e);
            result.error('discoverServices', msg, null);
          }
          break;
        }

        case 'readCharacteristic': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const serviceId = args['serviceId'] as string | undefined ?? '';
          const characteristicId = args['characteristicId'] as string | undefined ?? '';
          const serviceInstanceId = args['serviceInstanceId'] as string | undefined ?? '';
          const characteristicInstanceId = args['characteristicInstanceId']?.toString() ?? '';
          const characteristic: CharRef = {
            deviceId,
            serviceId,
            serviceInstanceId,
            characteristicId,
            characteristicInstanceId,
          };
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt == null) {
            this.emitCharValue(characteristic, undefined, 'device not connected');
            result.success(null);
            break;
          }
          try {
            const services = await this.getGattServicesWhenReady(deviceId);
            if (services == null) {
              this.emitCharValue(characteristic, undefined, 'GATT services not ready');
              result.success(null);
              break;
            }
            const charFound = this.findCharacteristic(services, serviceId, characteristicId);
            if (charFound == null) {
              this.emitCharValue(characteristic, undefined, 'characteristic not found');
              result.success(null);
              break;
            }
            const readChar = await gatt.readCharacteristicValue(charFound);
            const value = this.characteristicValueToNumberArray(readChar.characteristicValue);
            this.emitCharValue(characteristic, value);
          } catch (e) {
            this.emitCharValue(characteristic, undefined, this.bleErrorMessage(e));
          }
          result.success(null);
          break;
        }

        case 'writeCharacteristicWithResponse':
        case 'writeCharacteristicWithoutResponse': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const serviceId = args['serviceId'] as string | undefined ?? '';
          const characteristicId = args['characteristicId'] as string | undefined ?? '';
          const serviceInstanceId = args['serviceInstanceId'] as string | undefined ?? '';
          const characteristicInstanceId = args['characteristicInstanceId']?.toString() ?? '';
          const value = (args['value'] as number[] | undefined) ?? [];
          const characteristic: CharRef = {
            deviceId,
            serviceId,
            serviceInstanceId,
            characteristicId,
            characteristicInstanceId,
          };
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt == null) {
            const errPayload: WriteResultPayload = { characteristic, error: 'device not connected' };
            result.success(errPayload);
            break;
          }
          try {
            const services = await this.getGattServicesWhenReady(deviceId);
            if (services == null) {
              const notReadyPayload: WriteResultPayload = { characteristic, error: 'GATT services not ready' };
              result.success(notReadyPayload);
              break;
            }
            const charFound = this.findCharacteristic(services, serviceId, characteristicId);
            if (charFound == null) {
              const errPayload2: WriteResultPayload = { characteristic, error: 'characteristic not found' };
              result.success(errPayload2);
              break;
            }
            const writeType = method === 'writeCharacteristicWithResponse' ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
            const buf = new ArrayBuffer(value.length);
            const view = new DataView(buf);
            for (let i = 0; i < value.length; i++) view.setUint8(i, value[i]);
            const writeChar = this.buildCharacteristicForWrite(charFound, buf);
            await gatt.writeCharacteristicValue(writeChar, writeType);
            const successPayload: WriteResultPayload = { characteristic };
            result.success(successPayload);
          } catch (e) {
            const errPayload: WriteResultPayload = { characteristic, error: this.bleErrorMessage(e) };
            result.success(errPayload);
          }
          break;
        }

        case 'readNotifications': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const serviceId = args['serviceId'] as string | undefined ?? '';
          const characteristicId = args['characteristicId'] as string | undefined ?? '';
          const serviceInstanceId = args['serviceInstanceId'] as string | undefined ?? '';
          const characteristicInstanceId = args['characteristicInstanceId']?.toString() ?? '';
          const characteristic: CharRef = {
            deviceId,
            serviceId,
            serviceInstanceId,
            characteristicId,
            characteristicInstanceId,
          };
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt == null) {
            this.emitCharValue(characteristic, undefined, 'device not connected');
            result.success(null);
            break;
          }
          try {
            const services = await this.getGattServicesWhenReady(deviceId);
            if (services == null) {
              this.emitCharValue(characteristic, undefined, 'GATT services not ready');
              result.success(null);
              break;
            }
            const charFound = this.findCharacteristic(services, serviceId, characteristicId);
            if (charFound == null) {
              this.emitCharValue(characteristic, undefined, 'characteristic not found');
              result.success(null);
              break;
            }
            const callbackKey = this.charChangeCallbackKey(deviceId, serviceId, characteristicId);
            let newCallbackRegistered = false;
            let notificationEnabled = false;
            try {
              if (!this.charChangeCallbacks.has(callbackKey)) {
                const normServiceId = this.normalizeUuid(serviceId);
                const normCharId = this.normalizeUuid(characteristicId);
                const callback = (ch: ble.BLECharacteristic): void => {
                  const chServiceId = this.normalizeUuid(this.uuidStr(ch.serviceUuid));
                  const chCharId = this.normalizeUuid(this.uuidStr(ch.characteristicUuid));
                  if (chServiceId !== normServiceId || chCharId !== normCharId) {
                    return;
                  }
                  const c: CharRef = {
                    deviceId,
                    serviceId: this.uuidStr(ch.serviceUuid),
                    serviceInstanceId,
                    characteristicId: this.uuidStr(ch.characteristicUuid),
                    characteristicInstanceId,
                  };
                  const val = this.characteristicValueToNumberArray(ch.characteristicValue);
                  this.emitCharValue(c, val);
                };
                gatt.on('BLECharacteristicChange', callback);
                this.charChangeCallbacks.set(callbackKey, callback);
                newCallbackRegistered = true;
              }
              await this.enableCharacteristicNotifications(gatt, charFound);
              notificationEnabled = true;
            } catch (e) {
              if (notificationEnabled) {
                try {
                  await this.disableCharacteristicNotifications(gatt, charFound);
                } catch (cleanupErr) {
                  this.logBleError(`failed to disable notification after readNotifications error for ${deviceId}`,
                    cleanupErr);
                }
              }
              if (newCallbackRegistered) {
                this.unregisterCharChangeCallback(deviceId, serviceId, characteristicId, gatt);
              }
              const errorMsg = this.bleErrorMessage(e);
              this.emitCharValue(characteristic, undefined, `Failed to subscribe: ${errorMsg}`);
              this.logBleError(`readNotifications failed for ${deviceId}`, e);
            }
          } catch (e) {
            const errorMsg = this.bleErrorMessage(e);
            this.emitCharValue(characteristic, undefined, `Failed to subscribe: ${errorMsg}`);
            this.logBleError(`readNotifications failed for ${deviceId}`, e);
          }
          result.success(null);
          break;
        }

        case 'stopNotifications': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const serviceId = args['serviceId'] as string | undefined ?? '';
          const characteristicId = args['characteristicId'] as string | undefined ?? '';
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt != null) {
            try {
              const services = await this.getGattServicesWhenReady(deviceId);
              if (services != null) {
                const charFound = this.findCharacteristic(services, serviceId, characteristicId);
                if (charFound != null) {
                  await this.disableCharacteristicNotifications(gatt, charFound);
                }
              }
            } catch (e) {
              this.logBleError(`stopNotifications failed for ${deviceId}`, e);
            }
            this.unregisterCharChangeCallback(deviceId, serviceId, characteristicId, gatt);
          }
          result.success(null);
          break;
        }

        case 'negotiateMtuSize': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const mtuSize = (args['mtuSize'] as number) ?? 512;
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt == null) {
            result.error('negotiateMtuSize', 'device not connected', null);
            break;
          }
          this.negotiateMtuWithCallback(gatt, deviceId, mtuSize).then((actualMtu: number) => {
            const mtuPayload: MtuResultPayload = { mtu: actualMtu };
            result.success(mtuPayload);
          }).catch((e: object) => {
            result.error('negotiateMtuSize', this.bleErrorMessage(e), null);
          });
          break;
        }

        case 'requestConnectionPriority': {
          const errPayload: Record<string, string> = {
            error: 'requestConnectionPriority is not supported on HarmonyOS',
          };
          result.success(errPayload);
          break;
        }

        case 'readRssi': {
          const deviceId = args['deviceId'] as string | undefined ?? '';
          const gatt = this.connectedDevices.get(deviceId);
          if (gatt == null) {
            result.error('readRssi', 'device not connected', null);
            break;
          }
          try {
            const rssi = await gatt.getRssiValue();
            const rssiPayload: RssiResultPayload = { rssi };
            result.success(rssiPayload);
          } catch (e) {
            result.error('readRssi', this.bleErrorMessage(e), null);
          }
          break;
        }

        default:
          result.notImplemented();
      }
    } catch (e) {
      this.logBleError(`unhandled method ${method}`, e);
      result.error(method, this.bleErrorMessage(e), null);
    }
  }

  private uuidStr(uuid: ArrayBuffer | string): string {
    if (typeof uuid === 'string') {
      const trimmed = uuid.trim();
      return trimmed.length > 0 ? trimmed : '';
    }
    const view = new DataView(uuid);
    if (uuid.byteLength === 2) {
      const u = view.getUint16(0, true);
      return '0000' + u.toString(16).padStart(4, '0') + '-0000-1000-8000-00805f9b34fb';
    }
    if (uuid.byteLength !== 16) {
      return '';
    }
    let s = '';
    for (let i = 0; i < 16; i++) s += view.getUint8(i).toString(16).padStart(2, '0');
    return s.replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5');
  }

  private isParsableUuidString(uuid: string): boolean {
    if (uuid.length === 0) {
      return false;
    }
    const lower = uuid.toLowerCase().replace(/-/g, '');
    return lower.length === 4 || lower.length === 8 || lower.length === 32;
  }

  /**
   * 按 HarmonyOS 官方写法构造写入用 BLECharacteristic（不修改 getServices 返回的实例）。
   * API: writeCharacteristicValue(characteristic, writeType) — 数据放在 characteristicValue 字段。
   * 从 discovered 复制 properties，保持与 GATT 发现结果一致，便于系统校验与调试。
   */
  private buildCharacteristicForWrite(
    discovered: ble.BLECharacteristic,
    value: ArrayBuffer
  ): ble.BLECharacteristic {
    return {
      serviceUuid: discovered.serviceUuid,
      characteristicUuid: discovered.characteristicUuid,
      characteristicValue: value,
      properties: discovered.properties,
      descriptors: discovered.descriptors ?? [],
    };
  }

  private findCharacteristic(services: ble.GattService[], serviceId: string, characteristicId: string): ble.BLECharacteristic | null {
    const svcUuid = this.normalizeUuid(serviceId);
    const charUuid = this.normalizeUuid(characteristicId);
    for (let i = 0; i < services.length; i++) {
      const sUuid = this.normalizeUuid(this.uuidStr(services[i].serviceUuid));
      if (sUuid !== svcUuid) continue;
      const chars = services[i].characteristics ?? [];
      for (let j = 0; j < chars.length; j++) {
        const cUuid = this.normalizeUuid(this.uuidStr(chars[j].characteristicUuid));
        if (cUuid === charUuid) return chars[j];
      }
    }
    return null;
  }

  private async enableCharacteristicNotifications(gatt: ble.GattClientDevice,
    charFound: ble.BLECharacteristic): Promise<void> {
    if (charFound.properties?.notify === true) {
      await gatt.setCharacteristicChangeNotification(charFound, true);
    } else if (charFound.properties?.indicate === true) {
      await gatt.setCharacteristicChangeIndication(charFound, true);
    }
  }

  private async disableCharacteristicNotifications(gatt: ble.GattClientDevice,
    charFound: ble.BLECharacteristic): Promise<void> {
    if (charFound.properties?.notify === true) {
      await gatt.setCharacteristicChangeNotification(charFound, false);
    }
    if (charFound.properties?.indicate === true) {
      await gatt.setCharacteristicChangeIndication(charFound, false);
    }
  }

  private unregisterCharChangeCallback(deviceId: string, serviceId: string, characteristicId: string,
    gatt: ble.GattClientDevice): void {
    const callbackKey = this.charChangeCallbackKey(deviceId, serviceId, characteristicId);
    const existingCallback = this.charChangeCallbacks.get(callbackKey);
    if (existingCallback != null) {
      try {
        gatt.off('BLECharacteristicChange', existingCallback);
      } catch (e) {
        this.logBleError(`failed to unregister characteristic change callback for ${deviceId}`, e);
      }
      this.charChangeCallbacks.delete(callbackKey);
    }
  }

  private charChangeCallbackKey(deviceId: string, serviceId: string, characteristicId: string): string {
    return `${deviceId}|${this.normalizeUuid(serviceId)}|${this.normalizeUuid(characteristicId)}`;
  }

  private removeCharChangeCallbacksForDevice(deviceId: string, gatt?: ble.GattClientDevice): void {
    const prefix = `${deviceId}|`;
    const keysToRemove: string[] = [];
    this.charChangeCallbacks.forEach((_callback: (ch: ble.BLECharacteristic) => void, key: string) => {
      if (key.startsWith(prefix)) {
        keysToRemove.push(key);
      }
    });
    for (let i = 0; i < keysToRemove.length; i++) {
      const key = keysToRemove[i];
      const callback = this.charChangeCallbacks.get(key);
      if (callback != null && gatt != null) {
        try {
          gatt.off('BLECharacteristicChange', callback);
        } catch (e) {
          this.logBleError(`failed to unregister characteristic change callback for ${key}`, e);
        }
      }
      this.charChangeCallbacks.delete(key);
    }
  }

  /** 统一为带连字符的小写 128 位 UUID 字符串，便于与 uuidStr() 比较 */
  private normalizeUuid(u: string): string {
    const lower = u.toLowerCase().replace(/-/g, '');
    if (lower.length === 4) return '0000' + lower + '-0000-1000-8000-00805f9b34fb';
    if (lower.length === 8) return lower + '-0000-1000-8000-00805f9b34fb';
    if (lower.length === 32) return lower.replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5');
    return u;
  }

  /** 构建与 Dart OhosBleCodec.decodeDiscoveredServices 一致的服务列表 */
  private buildDiscoveredServicesList(deviceId: string, services: ble.GattService[]): DiscoveredService[] {
    const list: DiscoveredService[] = [];
    for (let i = 0; i < services.length; i++) {
      const s = services[i];
      const serviceId = this.uuidStr(s.serviceUuid);
      if (!this.isParsableUuidString(serviceId)) {
        continue;
      }
      const serviceInstanceId = String(i);
      const characteristics: DiscoveredChar[] = [];
      const chars = s.characteristics ?? [];
      for (let j = 0; j < chars.length; j++) {
        const c = chars[j];
        const characteristicId = this.uuidStr(c.characteristicUuid);
        if (!this.isParsableUuidString(characteristicId)) {
          continue;
        }
        const props = c.properties;
        const dc: DiscoveredChar = {
          characteristicId,
          characteristicInstanceId: String(j),
          isReadable: props?.read === true,
          isWritableWithResponse: props?.write === true,
          isWritableWithoutResponse: props?.writeNoResponse === true,
          isNotifiable: props?.notify === true,
          isIndicatable: props?.indicate === true,
        };
        characteristics.push(dc);
      }
      const includedServices: DiscoveredService[] = [];
      const inc = s.includeServices ?? [];
      for (let k = 0; k < inc.length; k++) {
        const subList = this.buildDiscoveredServicesList(deviceId, [inc[k]]);
        if (subList.length > 0) includedServices.push(subList[0]);
      }
      const svc: DiscoveredService = {
        serviceId,
        serviceInstanceId,
        characteristics,
        includedServices,
      };
      list.push(svc);
    }
    return list;
  }
}
