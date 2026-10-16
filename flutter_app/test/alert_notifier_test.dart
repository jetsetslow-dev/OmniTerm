import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omniterm/platform/alert_notifier.dart';
import 'package:omniterm/platform/platform_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('omniterm/test_notification_permission');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  for (final granted in <bool>[false, true]) {
    test('Android permission request completes with $granted result', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          return granted;
        },
      );

      final notifier = LocalAlertNotifier(
        permissions: PlatformPermissions(channel: channel),
        platform: TargetPlatform.android,
      );

      expect(await notifier.ensurePermission(), granted);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'requestNotifications');
      expect(calls.single.arguments, isNull);
    });
  }
}
