import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/sensitive_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('omniterm/sensitive_clipboard');
  late List<MethodCall> calls;
  late String? held;

  /// Stands in for the platform clipboard: records what it was asked to do, and answers `holds`
  /// from whatever it currently contains — which is what makes "someone copied something else"
  /// expressible.
  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'copy':
            held = call.arguments['text'] as String;
            return true;
          case 'holds':
            return held == call.arguments['text'];
          case 'clear':
            held = null;
            return true;
        }
        return null;
      },
    );
  }

  setUp(() {
    calls = [];
    held = null;
    install();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  /// A 20ms lifetime instead of the real minute. The policy under test is *when* the clear fires
  /// and *whether* it fires, not the constant; `sensitiveClipboardLifetime` carries that and is
  /// asserted separately below.
  const lifetime = Duration(milliseconds: 20);
  SensitiveClipboard clipboard() => SensitiveClipboard(lifetime: lifetime, channel: channel);

  Future<void> pastLifetime() => Future<void>.delayed(const Duration(milliseconds: 80));

  test('a secret is copied through the platform, marked and labelled', () async {
    // Not `Clipboard.setData`: that writes a plain clip, and from Android 13 the system shows a
    // preview of it — putting the private key on screen beside the button pressed to keep it
    // private. Kotlin marks the same copy sensitive at `ui/ToolsScreen.kt:115`.
    final subject = clipboard();
    await subject.copy(label: 'OmniTerm private key', text: 'PRIVATE-KEY-BODY');

    expect(calls.single.method, 'copy');
    expect(calls.single.arguments['text'], 'PRIVATE-KEY-BODY');
    expect(calls.single.arguments['label'], 'OmniTerm private key');
    subject.dispose();
  });

  test('the secret is taken back after its minute', () async {
    final subject = clipboard();
    await subject.copy(label: 'k', text: 'PRIVATE-KEY-BODY');
    expect(held, 'PRIVATE-KEY-BODY');

    await pastLifetime();

    expect(held, isNull, reason: 'a key must not sit in the clipboard for the rest of the day');
    expect(calls.map((c) => c.method), containsAllInOrder(['copy', 'holds', 'clear']));
    subject.dispose();
  });

  test('something the user copied afterwards is left alone', () async {
    // The reason the clear is conditional. Wiping unconditionally would destroy whatever the user
    // copied in the meantime, which is a worse bug than the one being fixed.
    final subject = clipboard();
    await subject.copy(label: 'k', text: 'PRIVATE-KEY-BODY');
    held = 'something the user copied later';

    await pastLifetime();

    expect(held, 'something the user copied later');
    expect(calls.map((c) => c.method), isNot(contains('clear')));
    subject.dispose();
  });

  test('tapping copy again restarts the minute', () async {
    // The same secret copied twice — a user tapping the button again — is the case that needs the
    // previous timer cancelled. With different text the conditional clear already protects the
    // second copy, so only identical text can show whether the stale timer was dropped.
    final subject = clipboard();
    await subject.copy(label: 'k', text: 'PRIVATE-KEY-BODY');
    await Future<void>.delayed(const Duration(milliseconds: 14));
    await subject.copy(label: 'k', text: 'PRIVATE-KEY-BODY');

    // Past the first copy's deadline, well short of the second's.
    await Future<void>.delayed(const Duration(milliseconds: 12));
    expect(held, 'PRIVATE-KEY-BODY', reason: 'the stale timer must not cut the new minute short');

    await pastLifetime();
    expect(held, isNull, reason: 'the second copy has its own full lifetime, then goes');
    subject.dispose();
  });

  test('a platform without the channel still copies', () async {
    // iOS, desktop and any build without the bridge. Skipping the marker is acceptable; skipping
    // the copy would mean a button that silently does nothing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
    final pasted = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') pasted.add(call);
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final subject = clipboard();
    await subject.copy(label: 'k', text: 'PRIVATE-KEY-BODY');

    expect(pasted.single.arguments['text'], 'PRIVATE-KEY-BODY');
    subject.dispose();
  });

  test('the lifetime matches the Kotlin helper', () {
    // `ui/ToolsScreen.kt:129` waits 60 seconds before taking the secret back.
    expect(sensitiveClipboardLifetime, const Duration(seconds: 60));
  });
}
