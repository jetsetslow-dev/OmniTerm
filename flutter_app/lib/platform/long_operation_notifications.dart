import 'dart:async';

import 'package:flutter/services.dart';

/// Android foreground-notification bridge for work that must continue after app switching.
///
/// Calls intentionally degrade to `false` on iOS, desktop and widget tests: those platforms either
/// have no equivalent execution contract or no registered Android plugin.
class LongOperationNotifications {
  LongOperationNotifications({
    MethodChannel? channel,
    this.requestNotificationPermission,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'omniterm/long_operations';

  final MethodChannel _channel;
  final Future<bool> Function()? requestNotificationPermission;
  bool _permissionRequested = false;

  Future<bool> isSupported() => _invoke('isSupported');

  Future<bool> start({
    required String id,
    required String label,
    int bytesDone = 0,
    int totalBytes = 0,
    String destination = 'transfers',
  }) async {
    // Android 13+ hides ordinary foreground-service notifications from the drawer when this
    // permission is denied. Ask at the first user-started long operation, not at cold start, so
    // the permission has an immediate and understandable purpose. A denial does not cancel work:
    // Android still exposes the foreground service in its active-apps surface.
    final requestPermission = requestNotificationPermission;
    if (!_permissionRequested && requestPermission != null) {
      _permissionRequested = true;
      // Do not hold the service start behind the system dialog. The operation can finish while the
      // user is deciding; if finish overtook a delayed start, Android would be left displaying an
      // ongoing notification for work that no longer exists.
      unawaited(requestPermission());
    }
    return _invoke('start', {
      'id': id,
      'label': label,
      'bytesDone': bytesDone,
      'totalBytes': totalBytes,
      'destination': destination,
    });
  }

  Future<bool> update({
    required String id,
    required String label,
    required int bytesDone,
    required int totalBytes,
    String destination = '',
  }) => _invoke('update', {
    'id': id,
    'label': label,
    'bytesDone': bytesDone,
    'totalBytes': totalBytes,
    'destination': destination,
  });

  Future<bool> finish({
    required String id,
    required bool success,
    bool cancelled = false,
  }) =>
      _invoke('finish', {'id': id, 'success': success, 'cancelled': cancelled});

  Future<bool> stopAll() => _invoke('stopAll');

  Future<bool> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
