import 'package:flutter/services.dart';

class PlatformPermissions {
  PlatformPermissions({
    this.channel = const MethodChannel('omniterm/platform_permissions'),
  });

  final MethodChannel channel;

  Future<bool> get localNetworkRequired =>
      _read('localNetworkRequired', fallback: false);
  Future<bool> get localNetworkGranted =>
      _read('localNetworkGranted', fallback: true);
  Future<bool> get notificationGranted =>
      _read('notificationGranted', fallback: true);
  Future<bool> get batteryExempt => _read('batteryExempt', fallback: true);

  Future<bool> requestLocalNetwork() =>
      _read('requestLocalNetwork', fallback: false);
  Future<bool> requestNotifications() =>
      _read('requestNotifications', fallback: false);
  Future<bool> openBatterySettings() =>
      _read('openBatterySettings', fallback: false);
  Future<bool> openAppSettings() => _read('openAppSettings', fallback: false);

  Future<bool> _read(String method, {required bool fallback}) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? fallback;
    } on MissingPluginException {
      return fallback;
    } on PlatformException {
      return fallback;
    }
  }
}
