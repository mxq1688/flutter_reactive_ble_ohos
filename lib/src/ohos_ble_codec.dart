import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart'
    show
        BleStatus,
        CharacteristicInstance,
        CharacteristicValue,
        CharacteristicValueUpdateError,
        ConnectionPriority,
        ConnectionPriorityFailure,
        ConnectionPriorityInfo,
        Connectable,
        ConnectionError,
        ConnectionStateUpdate,
        convertPriorityToInt,
        convertScanModeToArgs,
        DeviceConnectionState,
        DiscoveredCharacteristic,
        DiscoveredDevice,
        DiscoveredService,
        GenericFailure,
        Result,
        ScanFailure,
        ScanMode,
        ScanResult,
        Unit,
        Uuid,
        WriteCharacteristicFailure,
        WriteCharacteristicInfo;

/// JSON-serializable codec for MethodChannel/EventChannel with HarmonyOS native.
/// Uses Map<String, dynamic> for cross-platform compatibility.
class OhosBleCodec {
  static const String _logName = 'flutter_reactive_ble_ohos';

  /// Parses [raw] as UUID; logs and returns null on failure (never returns zero/empty UUID).
  static Uuid? tryParseUuid(String? raw, {String? context}) {
    if (raw == null || raw.trim().isEmpty) {
      developer.log(
        'skip empty UUID${context != null ? ' ($context)' : ''}',
        name: _logName,
      );
      return null;
    }
    try {
      return Uuid.parse(raw.trim());
    } catch (e) {
      developer.log(
        'invalid UUID "$raw"${context != null ? ' ($context)' : ''}: $e',
        name: _logName,
      );
      return null;
    }
  }

  static Map<String, dynamic>? _asStringDynamicMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  // ---- Encode (Dart -> Native) ----

  static Map<String, dynamic> encodeScanRequest({
    required List<Uuid> withServices,
    required ScanMode scanMode,
    required bool requireLocationServicesEnabled,
    bool resolveDeviceNamesViaGatt = false,
  }) {
    return {
      'withServices': withServices.map((u) => u.toString()).toList(),
      'scanMode': convertScanModeToArgs(scanMode),
      'requireLocationServicesEnabled': requireLocationServicesEnabled,
      'resolveDeviceNamesViaGatt': resolveDeviceNamesViaGatt,
    };
  }

  static Map<String, dynamic> encodeConnectRequest({
    required String deviceId,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    return {
      'deviceId': deviceId,
      'timeoutInMs': connectionTimeout?.inMilliseconds ?? 0,
      'servicesWithCharacteristicsToDiscover':
          servicesWithCharacteristicsToDiscover != null
              ? servicesWithCharacteristicsToDiscover.entries
                  .map((e) => {
                        'service': e.key.toString(),
                        'characteristics':
                            e.value.map((u) => u.toString()).toList(),
                      })
                  .toList()
              : null,
    };
  }

  static Map<String, dynamic> encodeCharacteristicInstance(
      CharacteristicInstance c) {
    return {
      'deviceId': c.deviceId,
      'serviceId': c.serviceId.toString(),
      'serviceInstanceId': c.serviceInstanceId,
      'characteristicId': c.characteristicId.toString(),
      'characteristicInstanceId': c.characteristicInstanceId,
    };
  }

  static Map<String, dynamic> encodeWriteRequest(
      CharacteristicInstance c, List<int> value) {
    return {
      ...encodeCharacteristicInstance(c),
      'value': value,
    };
  }

  static Map<String, dynamic> encodeMtuRequest(String deviceId, int mtu) {
    return {'deviceId': deviceId, 'mtuSize': mtu};
  }

  static Map<String, dynamic> encodeConnectionPriorityRequest(
      String deviceId, ConnectionPriority priority) {
    return {
      'deviceId': deviceId,
      'priority': convertPriorityToInt(priority),
    };
  }

  // ---- Decode (Native -> Dart) ----

  static BleStatus decodeBleStatus(Map<String, dynamic> map) {
    final code = map['status'] as int? ?? 0;
    return _bleStatusFromCode(code);
  }

  static BleStatus _bleStatusFromCode(int code) {
    switch (code) {
      case 0:
        return BleStatus.unknown;
      case 1:
        return BleStatus.unsupported;
      case 2:
        return BleStatus.unauthorized;
      case 3:
        return BleStatus.poweredOff;
      case 4:
        return BleStatus.locationServicesDisabled;
      case 5:
        return BleStatus.ready;
      default:
        return BleStatus.unknown;
    }
  }

  static ScanResult decodeScanResult(Map<String, dynamic> map) {
    if (map['error'] != null) {
      return ScanResult(
        result: Result.failure(GenericFailure<ScanFailure>(
            code: ScanFailure.unknown, message: map['error'] as String)),
      );
    }
    final d = _asStringDynamicMap(map['device']);
    if (d == null) {
      return ScanResult(
          result: Result.failure(GenericFailure<ScanFailure>(
              code: ScanFailure.unknown, message: 'No device')));
    }
    final device = DiscoveredDevice(
      id: d['id'] as String? ?? '',
      name: d['name'] as String? ?? '',
      serviceData: _decodeServiceData(d['serviceData']),
      serviceUuids: _decodeUuidList(d['serviceUuids']),
      manufacturerData: Uint8List.fromList(
          (d['manufacturerData'] as List<dynamic>?)?.cast<int>() ?? []),
      rssi: d['rssi'] as int? ?? 0,
      connectable: _decodeConnectable(d['connectable'] as int?),
    );
    return ScanResult(result: Result.success(device));
  }

  static Map<Uuid, Uint8List> _decodeServiceData(dynamic raw) {
    if (raw is! Map) return {};
    final out = <Uuid, Uint8List>{};
    for (final e in raw.entries) {
      try {
        final u = Uuid.parse(e.key.toString());
        final list = (e.value as List<dynamic>?)?.cast<int>() ?? [];
        out[u] = Uint8List.fromList(list);
      } catch (_) {}
    }
    return out;
  }

  static List<Uuid> _decodeUuidList(dynamic raw) {
    if (raw is! List) return [];
    final out = <Uuid>[];
    for (final e in raw) {
      final uuid = tryParseUuid(e.toString(), context: 'scan serviceUuids');
      if (uuid != null) {
        out.add(uuid);
      }
    }
    return out;
  }

  static Connectable _decodeConnectable(int? code) {
    switch (code) {
      case 1:
        return Connectable.unavailable;
      case 2:
        return Connectable.available;
      default:
        return Connectable.unknown;
    }
  }

  static ConnectionStateUpdate decodeConnectionStateUpdate(
      Map<String, dynamic> map) {
    final deviceId = map['deviceId'] as String? ?? '';
    final stateCode = map['connectionState'] as int? ?? 3;
    final failureMsg = map['failureMessage'] as String?;
    final state = _connectionStateFromCode(stateCode);
    final failure = failureMsg != null && failureMsg.isNotEmpty
        ? GenericFailure<ConnectionError>(
            code: ConnectionError.unknown, message: failureMsg)
        : null;
    return ConnectionStateUpdate(
        deviceId: deviceId, connectionState: state, failure: failure);
  }

  static DeviceConnectionState _connectionStateFromCode(int code) {
    switch (code) {
      case 0:
        return DeviceConnectionState.connecting;
      case 1:
        return DeviceConnectionState.connected;
      case 2:
        return DeviceConnectionState.disconnecting;
      case 3:
      default:
        return DeviceConnectionState.disconnected;
    }
  }

  static CharacteristicValue decodeCharacteristicValue(
      Map<String, dynamic> map) {
    final charMap = _asStringDynamicMap(map['characteristic']);
    final characteristic =
        charMap != null ? _decodeCharacteristicInstance(charMap) : null;
    if (characteristic == null) {
      return CharacteristicValue(
        characteristic: CharacteristicInstance(
          characteristicId: Uuid.parse('00000000-0000-0000-0000-000000000000'),
          characteristicInstanceId: '',
          serviceId: Uuid.parse('00000000-0000-0000-0000-000000000000'),
          serviceInstanceId: '',
          deviceId: charMap?['deviceId'] as String? ?? '',
        ),
        result: Result.failure(GenericFailure<CharacteristicValueUpdateError>(
            code: CharacteristicValueUpdateError.unknown,
            message: 'Invalid characteristic (UUID parse failed)')),
      );
    }
    if (map['error'] != null) {
      return CharacteristicValue(
        characteristic: characteristic,
        result: Result.failure(GenericFailure<CharacteristicValueUpdateError>(
            code: CharacteristicValueUpdateError.unknown,
            message: map['error'] as String)),
      );
    }
    final value = (map['value'] as List<dynamic>?)?.cast<int>() ?? [];
    return CharacteristicValue(
      characteristic: characteristic,
      result: Result.success(value),
    );
  }

  static CharacteristicInstance? _decodeCharacteristicInstance(
      Map<String, dynamic> m) {
    final serviceId =
        tryParseUuid(m['serviceId'] as String?, context: 'characteristic serviceId');
    final charId = tryParseUuid(
        m['characteristicId'] as String?, context: 'characteristicId');
    if (serviceId == null || charId == null) {
      return null;
    }
    return CharacteristicInstance(
      deviceId: m['deviceId'] as String? ?? '',
      serviceId: serviceId,
      serviceInstanceId: m['serviceInstanceId'] as String? ?? '',
      characteristicId: charId,
      characteristicInstanceId: m['characteristicInstanceId']?.toString() ?? '',
    );
  }

  static List<DiscoveredService> decodeDiscoveredServices(List<dynamic> raw) {
    final out = <DiscoveredService>[];
    for (final item in raw) {
      final m = _asStringDynamicMap(item);
      if (m == null) continue;
      final service = _decodeDiscoveredService(m);
      if (service != null) {
        out.add(service);
      }
    }
    return out;
  }

  static DiscoveredService? _decodeDiscoveredService(Map<String, dynamic> m) {
    final serviceId =
        tryParseUuid(m['serviceId'] as String?, context: 'discovered serviceId');
    if (serviceId == null) {
      return null;
    }
    final serviceInstanceId = m['serviceInstanceId'] as String? ?? '';
    final chars = (m['characteristics'] as List<dynamic>?) ?? [];
    final characteristics = <DiscoveredCharacteristic>[];
    for (final item in chars) {
      final cMap = _asStringDynamicMap(item);
      if (cMap == null) continue;
      final c = _decodeDiscoveredCharacteristic(cMap, serviceId);
      if (c != null) {
        characteristics.add(c);
      }
    }
    final characteristicIds =
        characteristics.map((c) => c.characteristicId).toList();
    final included = <DiscoveredService>[];
    final includedRaw = (m['includedServices'] as List<dynamic>?) ?? [];
    for (final item in includedRaw) {
      final incMap = _asStringDynamicMap(item);
      if (incMap == null) continue;
      final inc = _decodeDiscoveredService(incMap);
      if (inc != null) {
        included.add(inc);
      }
    }
    return DiscoveredService(
      serviceId: serviceId,
      serviceInstanceId: serviceInstanceId,
      characteristicIds: characteristicIds,
      characteristics: characteristics,
      includedServices: included,
    );
  }

  static DiscoveredCharacteristic? _decodeDiscoveredCharacteristic(
      Map<String, dynamic> m, Uuid serviceId) {
    final charId = tryParseUuid(
        m['characteristicId'] as String?, context: 'discovered characteristicId');
    if (charId == null) {
      return null;
    }
    return DiscoveredCharacteristic(
      characteristicId: charId,
      characteristicInstanceId: m['characteristicInstanceId']?.toString() ?? '',
      serviceId: serviceId,
      isReadable: m['isReadable'] as bool? ?? false,
      isWritableWithResponse: m['isWritableWithResponse'] as bool? ?? false,
      isWritableWithoutResponse:
          m['isWritableWithoutResponse'] as bool? ?? false,
      isNotifiable: m['isNotifiable'] as bool? ?? false,
      isIndicatable: m['isIndicatable'] as bool? ?? false,
    );
  }

  static WriteCharacteristicInfo decodeWriteCharacteristicInfo(
      Map<String, dynamic> map) {
    final charMap = _asStringDynamicMap(map['characteristic']);
    final characteristic =
        charMap != null ? _decodeCharacteristicInstance(charMap) : null;
    if (characteristic == null) {
      return WriteCharacteristicInfo(
        characteristic: CharacteristicInstance(
          characteristicId: Uuid.parse('00000000-0000-0000-0000-000000000000'),
          characteristicInstanceId: '',
          serviceId: Uuid.parse('00000000-0000-0000-0000-000000000000'),
          serviceInstanceId: '',
          deviceId: charMap?['deviceId'] as String? ?? '',
        ),
        result: Result.failure(GenericFailure<WriteCharacteristicFailure>(
            code: WriteCharacteristicFailure.unknown,
            message: 'Invalid characteristic (UUID parse failed)')),
      );
    }
    final error = map['error'] as String?;
    if (error != null && error.isNotEmpty) {
      return WriteCharacteristicInfo(
        characteristic: characteristic,
        result: Result.failure(GenericFailure<WriteCharacteristicFailure>(
            code: WriteCharacteristicFailure.unknown, message: error)),
      );
    }
    return WriteCharacteristicInfo(
      characteristic: characteristic,
      result: const Result.success(Unit()),
    );
  }

  static ConnectionPriorityInfo decodeConnectionPriorityInfo(
      Map<String, dynamic> map) {
    final error = map['error'] as String?;
    if (error != null && error.isNotEmpty) {
      return ConnectionPriorityInfo(
        result: Result.failure(GenericFailure<ConnectionPriorityFailure>(
            code: ConnectionPriorityFailure.unknown, message: error)),
      );
    }
    return const ConnectionPriorityInfo(result: Result.success(Unit()));
  }
}
