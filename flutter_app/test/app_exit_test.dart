import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/app_exit.dart';

/// How the app ends when the user explicitly asks it to.
///
/// This used to need no code at all: `SystemNavigator.pop()` finished the Activity and a default
/// `FlutterActivity` destroyed its Flutter engine along with it, taking the Dart isolate and every
/// SSH session with it. That was a side effect, not a decision — and retaining the engine so
/// sessions survive an Activity *recreation* removes it. The exit dialog promises that "Exiting
/// will terminate all active background SSH sessions", so the exit path now has to ask for that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;
  late List<MethodCall> navigatorCalls;
  const channel = MethodChannel(AppExit.channelName);

  void stubExit(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        platformCalls.add(call);
        return handler(call);
      },
    );
  }

  setUp(() {
    platformCalls = [];
    navigatorCalls = [];
    // SystemNavigator.pop travels on the platform channel; capturing it is how the fallback is
    // told apart from the native termination.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        navigatorCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('an explicit exit asks the platform to terminate, not merely to pop', () async {
    stubExit((_) async => true);

    await AppExit().terminate();

    expect(platformCalls.map((c) => c.method), ['terminate']);
    expect(
      navigatorCalls.where((c) => c.method == 'SystemNavigator.pop'),
      isEmpty,
      reason: 'popping alone no longer ends the isolate that owns the SSH sessions',
    );
  });

  test('a build without the bridge still exits', () async {
    // iOS and desktop never had the engine-destruction side effect to lose, and a build without
    // the bridge must not become unexitable.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );

    await AppExit().terminate();

    expect(navigatorCalls.map((c) => c.method), contains('SystemNavigator.pop'));
  });

  test('a platform that refuses still exits', () async {
    stubExit((_) async => throw PlatformException(code: 'no'));

    await AppExit().terminate();

    expect(
      navigatorCalls.map((c) => c.method),
      contains('SystemNavigator.pop'),
      reason: 'exiting is what the user asked for; a refused channel must not trap them',
    );
  });

  test('a platform that answers false falls back rather than doing nothing', () async {
    stubExit((_) async => false);

    await AppExit().terminate();

    expect(navigatorCalls.map((c) => c.method), contains('SystemNavigator.pop'));
  });
}
