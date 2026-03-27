# flutter_reactive_ble_ohos

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

HarmonyOS NEXT (OHOS) BLE plugin for Flutter, implementing the [`reactive_ble_platform_interface`](https://pub.dev/packages/reactive_ble_platform_interface). Drop-in replacement for `flutter_reactive_ble` on HarmonyOS — your existing BLE code works without changes.

## Features

| Capability | Status |
|---|---|
| BLE adapter status monitoring | Supported |
| Scan for devices (with UUID filter & scan mode) | Supported |
| Connect / disconnect | Supported |
| Service discovery | Supported |
| Read / write characteristics (with & without response) | Supported |
| Subscribe / unsubscribe notifications (Notify & Indicate) | Supported |
| MTU negotiation | Supported |
| Connection priority | Supported |
| Read RSSI | Supported |
| Clear GATT cache | Not supported (no public API on HarmonyOS) |

## Getting Started

### Installation

Add this plugin as a dependency. You can use a **git** reference or a **local path**:

```yaml
# Git dependency
dependencies:
  flutter_reactive_ble_ohos:
    git:
      url: https://github.com/mxq/flutter_reactive_ble_ohos.git
      ref: main

# Or local path (if you copy it into your project)
dependencies:
  flutter_reactive_ble_ohos:
    path: ./flutter_reactive_ble_ohos
```

### Permissions

Add BLE permissions in your HarmonyOS module's `module.json5`:

```json5
{
  "module": {
    "requestPermissions": [
      { "name": "ohos.permission.ACCESS_BLUETOOTH" },
      { "name": "ohos.permission.DISCOVER_BLUETOOTH" },
      { "name": "ohos.permission.MANAGE_BLUETOOTH" },
      { "name": "ohos.permission.APPROXIMATELY_LOCATION" }
    ]
  }
}
```

### Usage

Register the HarmonyOS platform implementation at app startup, then use `flutter_reactive_ble` as usual:

```dart
import 'package:flutter_reactive_ble_ohos/reactive_ble_ohos.dart';

void main() {
  // Register HarmonyOS BLE implementation
  ReactiveBlePlatform.instance =
      const ReactiveBleOhosPlatformFactory().create();
  runApp(MyApp());
}
```

After registration, the standard `flutter_reactive_ble` API works transparently on HarmonyOS:

```dart
final platform = ReactiveBlePlatform.instance;

// Initialize
await platform.initialize();

// Listen to BLE status
platform.bleStatusStream.listen((status) {
  print('BLE status: $status');
});

// Scan for devices
platform.scanForDevices(
  withServices: [],
  scanMode: ScanMode.balanced,
  requireLocationServicesEnabled: false,
);
platform.scanStream.listen((scanResult) {
  print('Scan result: $scanResult');
});

// Connect to a device
platform.connectToDevice(deviceId, null, Duration(seconds: 10));
platform.connectionUpdateStream.listen((update) {
  print('${update.deviceId}: ${update.connectionState}');
});
```

## Project Structure

```
flutter_reactive_ble_ohos/
├── lib/
│   ├── reactive_ble_ohos.dart               # Library entry point
│   └── src/
│       ├── reactive_ble_ohos_platform.dart   # ReactiveBlePlatform implementation
│       └── ohos_ble_codec.dart               # Dart <-> HarmonyOS JSON codec
├── ohos/
│   ├── Index.ets                            # OHOS plugin entry
│   └── src/main/ets/
│       └── ReactiveBleOhosPlugin.ets        # Native BLE implementation (ArkTS)
├── pubspec.yaml
└── LICENSE
```

## Platform Interface Alignment

This plugin implements the same `ReactiveBlePlatform` interface used by `flutter_reactive_ble` on Android and iOS. The Dart-side and native-side communicate through:

- **MethodChannel**: `reactive_ble_ohos_method`
- **EventChannels**: `reactive_ble_ohos_scan`, `reactive_ble_ohos_connected_device`, `reactive_ble_ohos_char_update`, `reactive_ble_ohos_status`

The native layer is built on HarmonyOS NEXT system APIs:
- `@kit.ConnectivityKit` (`ble`) — scanning, GATT client operations
- `@ohos.bluetooth.access` — adapter state monitoring

## Technical Details

### Connection Handling

- Duplicate connection requests to the same device are deduplicated
- Connection timeout is configurable; the timer is properly cleared on success or disconnect
- GATT service discovery completes before reporting connection success, with a brief delay to ensure characteristic readiness

### Scan Optimization

- Device name resolution via temporary `GattClientDevice` is queued (max 3 concurrent) to prevent system overload
- Scan results are always emitted (including RSSI updates); deduplication only applies to name resolution requests

### Unsupported: clearGattCache

HarmonyOS does not expose a public API for clearing the GATT cache (unlike Android's hidden `BluetoothGatt.refresh()`). Calling `clearGattCache()` will return a `GenericFailure<ClearGattCacheError>`.

## Requirements

- Flutter SDK `>=2.0.0`
- Dart SDK `>=2.17.0 <4.0.0`
- HarmonyOS NEXT (OpenHarmony compatible)
- `@ohos/flutter_ohos` (Flutter HarmonyOS engine)

## License

```
Copyright 2025 mxq

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```

See [LICENSE](LICENSE) for the full text.
