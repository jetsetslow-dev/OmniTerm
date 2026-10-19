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

  // Read at launch by the Alerts view model, so it must not initialise the notification plugin:
  // that stays lazy until the first alert is posted. A plugin call would fail here, because the
  // plugin's own channel has no handler in this test.
  for (final enabled in <bool>[false, true]) {
    test(
      'Android reads notificationsEnabled ($enabled) through the bridge, not the plugin',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return enabled;
          },
        );

        final notifier = LocalAlertNotifier(
          permissions: PlatformPermissions(channel: channel),
          platform: TargetPlatform.android,
        );

        expect(await notifier.notificationsEnabled(), enabled);
        expect(calls.map((c) => c.method), ['notificationsEnabled']);
      },
    );
  }
}
