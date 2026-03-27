import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';

import 'package:flutter_reactive_ble_ohos/src/ohos_ble_codec.dart';

void main() {
  group('OhosBleCodec', () {
    group('decodeBleStatus', () {
      test('returns ready for status 5', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 5});
        expect(result, BleStatus.ready);
      });

      test('returns poweredOff for status 3', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 3});
        expect(result, BleStatus.poweredOff);
      });

      test('returns unknown for status 0', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 0});
        expect(result, BleStatus.unknown);
      });

      test('returns unsupported for status 1', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 1});
        expect(result, BleStatus.unsupported);
      });

      test('returns unauthorized for status 2', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 2});
        expect(result, BleStatus.unauthorized);
      });

      test('returns locationServicesDisabled for status 4', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 4});
        expect(result, BleStatus.locationServicesDisabled);
      });

      test('returns unknown for missing status', () {
        final result = OhosBleCodec.decodeBleStatus({});
        expect(result, BleStatus.unknown);
      });

      test('returns unknown for unrecognized status code', () {
        final result = OhosBleCodec.decodeBleStatus({'status': 99});
        expect(result, BleStatus.unknown);
      });
    });

    group('decodeConnectionStateUpdate', () {
      test('decodes connected state', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({
          'deviceId': 'AA:BB:CC:DD:EE:FF',
          'connectionState': 1,
        });
        expect(result.deviceId, 'AA:BB:CC:DD:EE:FF');
        expect(result.connectionState, DeviceConnectionState.connected);
        expect(result.failure, isNull);
      });

      test('decodes disconnected state with failure message', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({
          'deviceId': 'AA:BB:CC:DD:EE:FF',
          'connectionState': 3,
          'failureMessage': 'Connection timeout',
        });
        expect(result.connectionState, DeviceConnectionState.disconnected);
        expect(result.failure, isNotNull);
        expect(result.failure!.message, 'Connection timeout');
      });

      test('decodes connecting state', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({
          'deviceId': 'test',
          'connectionState': 0,
        });
        expect(result.connectionState, DeviceConnectionState.connecting);
      });

      test('decodes disconnecting state', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({
          'deviceId': 'test',
          'connectionState': 2,
        });
        expect(result.connectionState, DeviceConnectionState.disconnecting);
      });

      test('defaults to disconnected for unknown state code', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({
          'deviceId': 'test',
          'connectionState': 99,
        });
        expect(result.connectionState, DeviceConnectionState.disconnected);
      });

      test('handles empty map gracefully', () {
        final result = OhosBleCodec.decodeConnectionStateUpdate({});
        expect(result.deviceId, '');
        expect(result.connectionState, DeviceConnectionState.disconnected);
      });
    });

    group('decodeScanResult', () {
      test('decodes successful scan with device info', () {
        final result = OhosBleCodec.decodeScanResult({
          'device': {
            'id': 'AA:BB:CC:DD:EE:FF',
            'name': 'TestDevice',
            'rssi': -65,
            'serviceUuids': ['0000180d-0000-1000-8000-00805f9b34fb'],
            'serviceData': {},
            'manufacturerData': [0x01, 0x02],
            'connectable': 2,
          },
        });
        result.result.iif(
          success: (device) {
            expect(device.id, 'AA:BB:CC:DD:EE:FF');
            expect(device.name, 'TestDevice');
            expect(device.rssi, -65);
            expect(device.manufacturerData, Uint8List.fromList([0x01, 0x02]));
            expect(device.connectable, Connectable.available);
          },
          failure: (_) => fail('Expected success'),
        );
      });

      test('decodes scan error', () {
        final result = OhosBleCodec.decodeScanResult({
          'error': 'Scan failed',
        });
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error!.message, 'Scan failed');
          },
        );
      });

      test('returns failure for missing device', () {
        final result = OhosBleCodec.decodeScanResult({});
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error!.message, 'No device');
          },
        );
      });
    });

    group('decodeWriteCharacteristicInfo', () {
      test('decodes successful write', () {
        final result = OhosBleCodec.decodeWriteCharacteristicInfo({
          'characteristic': {
            'deviceId': 'AA:BB:CC:DD:EE:FF',
            'serviceId': '0000180d-0000-1000-8000-00805f9b34fb',
            'serviceInstanceId': '0',
            'characteristicId': '00002a37-0000-1000-8000-00805f9b34fb',
            'characteristicInstanceId': '0',
          },
        });
        expect(result.characteristic.deviceId, 'AA:BB:CC:DD:EE:FF');
        result.result.iif(
          success: (_) {},
          failure: (_) => fail('Expected success'),
        );
      });

      test('decodes write error', () {
        final result = OhosBleCodec.decodeWriteCharacteristicInfo({
          'characteristic': {
            'deviceId': 'test',
            'serviceId': '0000180d-0000-1000-8000-00805f9b34fb',
            'serviceInstanceId': '0',
            'characteristicId': '00002a37-0000-1000-8000-00805f9b34fb',
            'characteristicInstanceId': '0',
          },
          'error': 'Write failed',
        });
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error!.message, 'Write failed');
          },
        );
      });

      test('handles missing characteristic gracefully', () {
        final result = OhosBleCodec.decodeWriteCharacteristicInfo({});
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error, isNotNull);
          },
        );
      });
    });

    group('decodeConnectionPriorityInfo', () {
      test('decodes success', () {
        final result = OhosBleCodec.decodeConnectionPriorityInfo({});
        result.result.iif(
          success: (_) {},
          failure: (_) => fail('Expected success'),
        );
      });

      test('decodes error', () {
        final result = OhosBleCodec.decodeConnectionPriorityInfo({
          'error': 'Priority change failed',
        });
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error!.message, 'Priority change failed');
          },
        );
      });
    });

    group('decodeCharacteristicValue', () {
      test('decodes value successfully', () {
        final result = OhosBleCodec.decodeCharacteristicValue({
          'characteristic': {
            'deviceId': 'test',
            'serviceId': '0000180d-0000-1000-8000-00805f9b34fb',
            'serviceInstanceId': '0',
            'characteristicId': '00002a37-0000-1000-8000-00805f9b34fb',
            'characteristicInstanceId': '0',
          },
          'value': [0x10, 0x20, 0x30],
        });
        expect(result.characteristic.deviceId, 'test');
        result.result.iif(
          success: (value) {
            expect(value, [0x10, 0x20, 0x30]);
          },
          failure: (_) => fail('Expected success'),
        );
      });

      test('decodes error', () {
        final result = OhosBleCodec.decodeCharacteristicValue({
          'characteristic': {
            'deviceId': 'test',
            'serviceId': '0000180d-0000-1000-8000-00805f9b34fb',
            'serviceInstanceId': '0',
            'characteristicId': '00002a37-0000-1000-8000-00805f9b34fb',
            'characteristicInstanceId': '0',
          },
          'error': 'Read failed',
        });
        result.result.iif(
          success: (_) => fail('Expected failure'),
          failure: (error) {
            expect(error!.message, 'Read failed');
          },
        );
      });
    });

    group('decodeDiscoveredServices', () {
      test('decodes service list', () {
        final result = OhosBleCodec.decodeDiscoveredServices([
          {
            'serviceId': '0000180d-0000-1000-8000-00805f9b34fb',
            'serviceInstanceId': '0',
            'characteristics': [
              {
                'characteristicId': '00002a37-0000-1000-8000-00805f9b34fb',
                'characteristicInstanceId': '0',
                'isReadable': true,
                'isWritableWithResponse': false,
                'isWritableWithoutResponse': false,
                'isNotifiable': true,
                'isIndicatable': false,
              },
            ],
            'includedServices': [],
          },
        ]);
        expect(result.length, 1);
        expect(result[0].characteristics.length, 1);
        expect(result[0].characteristics[0].isReadable, true);
        expect(result[0].characteristics[0].isNotifiable, true);
      });

      test('handles empty list', () {
        final result = OhosBleCodec.decodeDiscoveredServices([]);
        expect(result, isEmpty);
      });
    });

    group('encode methods', () {
      test('encodeScanRequest produces expected keys', () {
        final result = OhosBleCodec.encodeScanRequest(
          withServices: [],
          scanMode: ScanMode.balanced,
          requireLocationServicesEnabled: false,
        );
        expect(result.containsKey('withServices'), true);
        expect(result.containsKey('scanMode'), true);
        expect(result.containsKey('requireLocationServicesEnabled'), true);
        expect(result['requireLocationServicesEnabled'], false);
      });

      test('encodeConnectRequest includes deviceId and timeout', () {
        final result = OhosBleCodec.encodeConnectRequest(
          deviceId: 'AA:BB:CC:DD:EE:FF',
          connectionTimeout: const Duration(seconds: 10),
        );
        expect(result['deviceId'], 'AA:BB:CC:DD:EE:FF');
        expect(result['timeoutInMs'], 10000);
      });

      test('encodeMtuRequest', () {
        final result = OhosBleCodec.encodeMtuRequest('test-device', 256);
        expect(result['deviceId'], 'test-device');
        expect(result['mtuSize'], 256);
      });

      test('encodeConnectionPriorityRequest', () {
        final result = OhosBleCodec.encodeConnectionPriorityRequest(
          'test-device',
          ConnectionPriority.highPerformance,
        );
        expect(result['deviceId'], 'test-device');
        expect(result.containsKey('priority'), true);
      });
    });
  });
}
