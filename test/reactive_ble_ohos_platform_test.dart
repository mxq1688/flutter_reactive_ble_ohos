import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart';

import 'package:flutter_reactive_ble_ohos/src/reactive_ble_ohos_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReactiveBleOhosPlatform unsupported APIs', () {
    late ReactiveBleOhosPlatform platform;

    setUp(() {
      platform = ReactiveBleOhosPlatform(
        methodChannel: const MethodChannel('reactive_ble_ohos_method'),
        scanChannel: const EventChannel('reactive_ble_ohos_scan'),
        connectionChannel: const EventChannel('reactive_ble_ohos_connected_device'),
        charUpdateChannel: const EventChannel('reactive_ble_ohos_char_update'),
        bleStatusChannel: const EventChannel('reactive_ble_ohos_status'),
      );
    });

    test('requestConnectionPriority returns failure without native call', () async {
      var nativeInvoked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('reactive_ble_ohos_method'),
        (MethodCall call) async {
          if (call.method == 'requestConnectionPriority') {
            nativeInvoked = true;
          }
          return null;
        },
      );

      final result = await platform.requestConnectionPriority(
        'AA:BB:CC:DD:EE:FF',
        ConnectionPriority.highPerformance,
      );

      expect(nativeInvoked, isFalse);
      result.result.iif(
        success: (_) => fail('Expected failure'),
        failure: (error) {
          expect(
            error!.message,
            'requestConnectionPriority is not supported on HarmonyOS',
          );
        },
      );
    });
  });
}
