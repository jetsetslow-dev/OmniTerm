import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/link_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  bool? bridgeAnswer;

  void installBridge() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      linkOpenerChannel,
      (call) async {
        calls.add(call);
        return bridgeAnswer;
      },
    );
  }

  setUp(() {
    calls = [];
    bridgeAnswer = true;
    installBridge();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(linkOpenerChannel, null)
      ..setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('an in-app open carries the toolbar colour to the platform', () async {
    // The whole reason for the bridge: `url_launcher`'s `InAppBrowserConfiguration` has exactly one
    // field — `showTitle` — so the Custom Tab could not be tinted, and Kotlin tints it with the
    // app's own surface colour (`ui/ShellScreen.kt:1846`).
    expect(
      await openLink(Uri.parse('https://example.test/x'), inApp: true, toolbarColor: 0xFF102030),
      isTrue,
    );

    expect(calls.single.method, 'open');
    expect(calls.single.arguments['url'], 'https://example.test/x');
    expect(calls.single.arguments['inApp'], isTrue);
    expect(calls.single.arguments['toolbarColor'], 0xFF102030);
  });

  test('no colour means no colour argument, not a null one', () async {
    // The native side treats a missing key as "leave the chrome alone"; a null would have to be
    // special-cased there instead.
    await openLink(Uri.parse('https://example.test/x'), inApp: true);
    expect(calls.single.arguments.containsKey('toolbarColor'), isFalse);
  });

  test('an external open says so, and is not a Custom Tab', () async {
    await openLink(Uri.parse('https://example.test/x'), inApp: false);
    expect(calls.single.arguments['inApp'], isFalse);
  });

  test('a refusal from the platform is reported, not swallowed', () async {
    // The screen shows "No app could open that link" on false. Reporting success would leave the
    // user waiting for a browser that never opens.
    bridgeAnswer = false;
    expect(await openLink(Uri.parse('https://example.test/x'), inApp: true), isFalse);
  });

  test('a non-http scheme is refused before the platform is asked', () async {
    // Terminal output is untrusted text. `intent:` and `file:` links reaching a real intent is the
    // hazard this guards, and the check has to happen before the channel call, not after.
    expect(await openLink(Uri.parse('file:///etc/passwd'), inApp: true), isFalse);
    expect(calls, isEmpty);
  });

  // Deliberately not covered here: the `url_launcher` fallback taken when the bridge is absent.
  // Proving it would mean mocking `url_launcher`'s own platform interface, and a test that merely
  // showed "we did not call our channel" would assert the absence of one thing while claiming the
  // presence of another. The fallback's contract is stated in `openLink`'s doc and exercised on
  // every non-Android platform.
}
