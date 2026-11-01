import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/battery_saver_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late List<MethodCall> calls;

  setUp(() {
    channel = const MethodChannel(BatterySaverNotifications.channelName);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(call);
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test('shows the advisory and accepted states, then cancels them', () async {
    final notifications = BatterySaverNotifications();

    await notifications.showPrompt(percent: 18);
    await notifications.showActive(percent: 18);
    await notifications.cancel();

    expect(calls.map((call) => call.method), ['showPrompt', 'showActive', 'cancel']);
    expect((calls.first.arguments as Map)['percent'], 18);
  });

  test('a platform without the bridge remains usable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );

    await BatterySaverNotifications().showPrompt(percent: 10);
  });
}
