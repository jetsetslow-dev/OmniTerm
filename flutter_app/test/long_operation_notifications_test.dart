import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/long_operation_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late List<MethodCall> calls;
  late LongOperationNotifications notifications;

  setUp(() {
    channel = const MethodChannel(LongOperationNotifications.channelName);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    notifications = LongOperationNotifications();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'sends start, determinate progress and completion without losing 64-bit byte counts',
    () async {
      const total = 8 * 1024 * 1024 * 1024;
      const done = 5 * 1024 * 1024 * 1024;

      await notifications.start(
        id: 'copy-1',
        label: 'Copy: archive.tar',
        totalBytes: total,
        destination: 'transfers',
      );
      await notifications.update(
        id: 'copy-1',
        label: 'Copy: archive.tar',
        bytesDone: done,
        totalBytes: total,
      );
      await notifications.finish(id: 'copy-1', success: true);

      expect(calls.map((call) => call.method), ['start', 'update', 'finish']);
      expect((calls[1].arguments as Map)['bytesDone'], done);
      expect((calls[1].arguments as Map)['totalBytes'], total);
      expect((calls.first.arguments as Map)['destination'], 'transfers');
      expect((calls[2].arguments as Map)['success'], isTrue);
      expect((calls[2].arguments as Map)['cancelled'], isFalse);
    },
  );

  test(
    'requests notification access once and keeps cancellation distinct from failure',
    () async {
      var permissionRequests = 0;
      notifications = LongOperationNotifications(
        requestNotificationPermission: () async {
          permissionRequests++;
          return false;
        },
      );

      await notifications.start(id: 'a', label: 'Download: a');
      await notifications.start(id: 'b', label: 'Download: b');
      await notifications.finish(id: 'a', success: false, cancelled: true);

      expect(permissionRequests, 1);
      expect((calls.last.arguments as Map)['cancelled'], isTrue);
      expect((calls.last.arguments as Map)['success'], isFalse);
    },
  );

  test('missing native plugin degrades to unsupported', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    expect(
      await notifications.start(id: 'a', label: 'Upload: a', totalBytes: 1),
      isFalse,
    );
  });
}
