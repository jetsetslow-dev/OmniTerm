import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class DeviceDiagnostics {
  const DeviceDiagnostics({
    required this.device,
    required this.platform,
    required this.abi,
    required this.advertisingId,
  });

  final String device;
  final String platform;
  final String abi;
  final String advertisingId;

  static const _channel = MethodChannel('omniterm/device_info');

  static Future<DeviceDiagnostics> load({
    required bool includeAdvertisingId,
  }) async {
    var device = Platform.operatingSystem;
    var platform = Platform.operatingSystemVersion;
    var abi = 'unknown';
    var adId = includeAdvertisingId ? 'Unavailable' : 'N/A';
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final raw = await _channel.invokeMapMethod<String, Object?>('details');
        device = raw?['device'] as String? ?? device;
        platform = raw?['platform'] as String? ?? platform;
        abi = raw?['abi'] as String? ?? abi;
        if (includeAdvertisingId) {
          adId =
              await _channel.invokeMethod<String>('advertisingId') ??
              'Unavailable';
        }
      } on PlatformException {
        // Diagnostics still name the Dart platform when the optional bridge fails.
      } on MissingPluginException {
        // Widget tests and non-Android platforms intentionally have no bridge.
      }
    }
    return DeviceDiagnostics(
      device: device,
      platform: platform,
      abi: abi,
      advertisingId: adId,
    );
  }
}
