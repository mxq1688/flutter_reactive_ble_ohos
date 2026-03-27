import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble_ohos/reactive_ble_ohos.dart';

void main() {
  ReactiveBlePlatform.instance =
      const ReactiveBleOhosPlatformFactory().create();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Harmony Example',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const BleHomePage(),
    );
  }
}

class BleHomePage extends StatefulWidget {
  const BleHomePage({super.key});

  @override
  State<BleHomePage> createState() => _BleHomePageState();
}

class _BleHomePageState extends State<BleHomePage> {
  final _platform = ReactiveBlePlatform.instance;
  final _devices = <String, DiscoveredDevice>{};
  BleStatus _bleStatus = BleStatus.unknown;
  bool _isScanning = false;

  StreamSubscription<BleStatus>? _statusSub;
  StreamSubscription<ScanResult>? _scanSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _platform.initialize();
    _statusSub = _platform.bleStatusStream.listen((status) {
      setState(() => _bleStatus = status);
    });
  }

  void _startScan() {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    _platform.scanForDevices(
      withServices: [],
      scanMode: ScanMode.balanced,
      requireLocationServicesEnabled: false,
    );

    _scanSub = _platform.scanStream.listen((scanResult) {
      scanResult.result.iif(
        success: (device) {
          setState(() => _devices[device.id] = device);
        },
        failure: (_) {},
      );
    });
  }

  void _stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    setState(() => _isScanning = false);
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _scanSub?.cancel();
    _platform.deinitialize();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deviceList = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Harmony Example'),
        actions: [
          Chip(label: Text(_bleStatus.name)),
          const SizedBox(width: 8),
        ],
      ),
      body: deviceList.isEmpty
          ? const Center(child: Text('No devices found.\nTap the button to start scanning.', textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: deviceList.length,
              itemBuilder: (context, index) {
                final d = deviceList[index];
                return ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(d.name.isEmpty ? '(unknown)' : d.name),
                  subtitle: Text(d.id),
                  trailing: Text('${d.rssi} dBm'),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? _stopScan : _startScan,
        icon: Icon(_isScanning ? Icons.stop : Icons.search),
        label: Text(_isScanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}
