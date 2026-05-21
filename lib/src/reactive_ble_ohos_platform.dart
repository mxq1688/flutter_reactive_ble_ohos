import 'package:flutter/services.dart';
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';

import 'ohos_ble_codec.dart';

/// HarmonyOS NEXT (OHOS) implementation of [ReactiveBlePlatform].
///
/// Implements: initialize, deinitialize, BLE status, scan, connect, disconnect,
/// discoverServices, read/write characteristic (with/without response),
/// subscribe/stop notifications, MTU negotiation, connection priority, readRssi.
/// Does NOT implement [clearGattCache] (no public API on HarmonyOS).
class ReactiveBleOhosPlatform extends ReactiveBlePlatform {
  /// 扫描时是否创建临时 GattClient 解析无广播名称的设备。
  ///
  /// 默认 `false`：仅使用广播数据中的名称（[parseLocalNameFromAdvData] 等价逻辑），
  /// 避免临时连接占用设备资源、影响后续正式连接。
  /// 设为 `true` 可恢复通过 Gatt 拉取名称的行为（并发上限 3）。
  static bool resolveScanDeviceNamesViaGatt = false;

  ReactiveBleOhosPlatform({
    required MethodChannel methodChannel,
    required EventChannel scanChannel,
    required EventChannel connectionChannel,
    required EventChannel charUpdateChannel,
    required EventChannel bleStatusChannel,
    Logger? logger,
  })  : _methodChannel = methodChannel,
        _scanChannel = scanChannel,
        _connectionChannel = connectionChannel,
        _charUpdateChannel = charUpdateChannel,
        _bleStatusChannel = bleStatusChannel,
        _logger = logger;

  final MethodChannel _methodChannel;
  final EventChannel _scanChannel;
  final EventChannel _connectionChannel;
  final EventChannel _charUpdateChannel;
  final EventChannel _bleStatusChannel;
  final Logger? _logger;

  Stream<ConnectionStateUpdate>? _connectionUpdateStream;
  Stream<CharacteristicValue>? _charValueStream;
  Stream<ScanResult>? _scanResultStream;
  Stream<BleStatus>? _bleStatusStream;

  @override
  Stream<BleStatus> get bleStatusStream =>
      _bleStatusStream ??= _bleStatusChannel.receiveBroadcastStream().map((dynamic raw) {
        final map = _castMap(raw);
        return OhosBleCodec.decodeBleStatus(map);
      });

  @override
  Stream<ScanResult> get scanStream =>
      _scanResultStream ??= _scanChannel.receiveBroadcastStream().map((dynamic raw) {
        final map = _castMap(raw);
        return OhosBleCodec.decodeScanResult(map);
      });

  @override
  Stream<ConnectionStateUpdate> get connectionUpdateStream =>
      _connectionUpdateStream ??= _connectionChannel.receiveBroadcastStream().map((dynamic raw) {
        final map = _castMap(raw);
        return OhosBleCodec.decodeConnectionStateUpdate(map);
      });

  @override
  Stream<CharacteristicValue> get charValueUpdateStream =>
      _charValueStream ??= _charUpdateChannel.receiveBroadcastStream().map((dynamic raw) {
        final map = _castMap(raw);
        return OhosBleCodec.decodeCharacteristicValue(map);
      });

  static Map<String, dynamic> _castMap(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  @override
  Future<void> initialize() async {
    _logger?.log('ReactiveBleOhos: initialize');
    await _methodChannel.invokeMethod<void>('initialize');
  }

  @override
  Future<void> deinitialize() async {
    _logger?.log('ReactiveBleOhos: deinitialize');
    await _methodChannel.invokeMethod<void>('deinitialize');
  }

  @override
  Stream<void> scanForDevices({
    required List<Uuid> withServices,
    required ScanMode scanMode,
    required bool requireLocationServicesEnabled,
  }) {
    _logger?.log('ReactiveBleOhos: scanForDevices');
    final args = OhosBleCodec.encodeScanRequest(
      withServices: withServices,
      scanMode: scanMode,
      requireLocationServicesEnabled: requireLocationServicesEnabled,
      resolveDeviceNamesViaGatt: resolveScanDeviceNamesViaGatt,
    );
    return _methodChannel.invokeMethod<void>('scanForDevices', args).asStream();
  }

  @override
  Future<Result<Unit, GenericFailure<ClearGattCacheError>?>> clearGattCache(String deviceId) async {
    // Not supported on HarmonyOS - no public API for clearing GATT cache.
    return Result.failure(GenericFailure<ClearGattCacheError>(
      code: ClearGattCacheError.unknown,
      message: 'clearGattCache is not supported on HarmonyOS',
    ));
  }

  @override
  Future<int> readRssi(String deviceId) async {
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>('readRssi', {'deviceId': deviceId});
    final map = result != null ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    return (map['rssi'] as num?)?.toInt() ?? 0;
  }

  @override
  Stream<void> connectToDevice(
    String id,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  ) {
    _logger?.log('ReactiveBleOhos: connectToDevice $id');
    final args = OhosBleCodec.encodeConnectRequest(
      deviceId: id,
      servicesWithCharacteristicsToDiscover: servicesWithCharacteristicsToDiscover,
      connectionTimeout: connectionTimeout,
    );
    return _methodChannel.invokeMethod<void>('connectToDevice', args).asStream();
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    _logger?.log('ReactiveBleOhos: disconnectDevice $deviceId');
    await _methodChannel.invokeMethod<void>('disconnectFromDevice', {'deviceId': deviceId});
  }

  @override
  Future<List<DiscoveredService>> discoverServices(String deviceId) async {
    _logger?.log('ReactiveBleOhos: discoverServices $deviceId');
    final result = await _methodChannel.invokeMethod<List<dynamic>>('discoverServices', {'deviceId': deviceId});
    if (result == null) return [];
    return OhosBleCodec.decodeDiscoveredServices(result);
  }

  @override
  Future<List<DiscoveredService>> getDiscoverServices(String deviceId) async {
    return discoverServices(deviceId);
  }

  @override
  Stream<void> readCharacteristic(CharacteristicInstance characteristic) {
    _logger?.log('ReactiveBleOhos: readCharacteristic $characteristic');
    final args = OhosBleCodec.encodeCharacteristicInstance(characteristic);
    return _methodChannel.invokeMethod<void>('readCharacteristic', args).asStream();
  }

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) =>
      _writeCharacteristic('writeCharacteristicWithResponse', characteristic, value);

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(
    CharacteristicInstance characteristic,
    List<int> value,
  ) =>
      _writeCharacteristic('writeCharacteristicWithoutResponse', characteristic, value);

  Future<WriteCharacteristicInfo> _writeCharacteristic(
    String method,
    CharacteristicInstance characteristic,
    List<int> value,
  ) async {
    _logger?.log('ReactiveBleOhos: $method');
    final args = OhosBleCodec.encodeWriteRequest(characteristic, value);
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(method, args);
    final map = result != null ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    return OhosBleCodec.decodeWriteCharacteristicInfo(map);
  }

  @override
  Stream<void> subscribeToNotifications(CharacteristicInstance characteristic) {
    _logger?.log('ReactiveBleOhos: subscribeToNotifications');
    final args = OhosBleCodec.encodeCharacteristicInstance(characteristic);
    return _methodChannel.invokeMethod<void>('readNotifications', args).asStream();
  }

  @override
  Future<void> stopSubscribingToNotifications(CharacteristicInstance characteristic) async {
    _logger?.log('ReactiveBleOhos: stopSubscribingToNotifications');
    final args = OhosBleCodec.encodeCharacteristicInstance(characteristic);
    await _methodChannel.invokeMethod<void>('stopNotifications', args);
  }

  @override
  Future<int> requestMtuSize(String deviceId, int? mtu) async {
    _logger?.log('ReactiveBleOhos: requestMtuSize $deviceId $mtu');
    final args = OhosBleCodec.encodeMtuRequest(deviceId, mtu ?? 512);
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>('negotiateMtuSize', args);
    final map = result != null ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    return (map['mtu'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<ConnectionPriorityInfo> requestConnectionPriority(String deviceId, ConnectionPriority priority) async {
    _logger?.log('ReactiveBleOhos: requestConnectionPriority $deviceId $priority');
    final args = OhosBleCodec.encodeConnectionPriorityRequest(deviceId, priority);
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>('requestConnectionPriority', args);
    final map = result != null ? Map<String, dynamic>.from(result) : <String, dynamic>{};
    return OhosBleCodec.decodeConnectionPriorityInfo(map);
  }
}

/// Factory that creates [ReactiveBleOhosPlatform] with default channel names.
class ReactiveBleOhosPlatformFactory {
  const ReactiveBleOhosPlatformFactory();

  ReactiveBleOhosPlatform create({Logger? logger}) {
    final methodChannel = MethodChannel('reactive_ble_ohos_method');
    final scanChannel = EventChannel('reactive_ble_ohos_scan');
    final connectionChannel = EventChannel('reactive_ble_ohos_connected_device');
    final charUpdateChannel = EventChannel('reactive_ble_ohos_char_update');
    final bleStatusChannel = EventChannel('reactive_ble_ohos_status');

    return ReactiveBleOhosPlatform(
      methodChannel: methodChannel,
      scanChannel: scanChannel,
      connectionChannel: connectionChannel,
      charUpdateChannel: charUpdateChannel,
      bleStatusChannel: bleStatusChannel,
      logger: logger,
    );
  }
}
