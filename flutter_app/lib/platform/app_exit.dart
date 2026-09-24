import 'package:flutter/services.dart';

/// Ends the app when the user explicitly asks to.
///
/// `SystemNavigator.pop()` finishes the Activity, and on Android that used to end everything only
/// because the Flutter engine was destroyed along with it. The engine is now retained across
/// Activity instances so SSH sessions survive a recreation, which means finishing the Activity no
/// longer terminates anything by itself — and the exit dialog promises that it does.
///
/// Falls back to `SystemNavigator.pop()` where no implementation is registered: iOS and desktop
/// never had the engine-destruction side effect to lose, and a build without the bridge must still
/// be able to exit.
class AppExit {
  AppExit({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'omniterm/app_exit';

  final MethodChannel _channel;

  Future<void> terminate() async {
    try {
      final handled = await _channel.invokeMethod<bool>('terminate') ?? false;
      if (handled) return;
    } on MissingPluginException {
      // No bridge in this build or on this platform; the ordinary exit path is still correct.
    } on PlatformException {
      // The platform refused. Exiting is still what the user asked for.
    }
    await SystemNavigator.pop();
  }
}
