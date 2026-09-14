import 'package:flutter/services.dart';

/// Keeps the app's contents out of screenshots, screen recordings and the task-switcher thumbnail.
///
/// Backed by Android's `FLAG_SECURE` (see `ScreenSecurityBridge.kt`). On a terminal app the
/// task-switcher thumbnail is the real exposure: the OS captures it automatically, it survives
/// backgrounding, and it routinely contains a live root shell.
///
/// **The two platforms protect different things, and the app must not blur that.**
///
/// - **Android** applies `FLAG_SECURE`: screenshots, screen recordings and the task-switcher
///   thumbnail are all blocked.
/// - **iOS** has no API to block a screenshot at all. What it does have is the moment before the
///   system snapshots the window for the app switcher, so the window is covered for the duration of
///   that snapshot. The switcher preview is protected; a deliberate screenshot is not.
///
/// [isSupported] is asked of the platform rather than assumed, so a platform with neither can say
/// the option does nothing rather than implying a protection nobody is applying.
class ScreenSecurity {
  ScreenSecurity({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('omniterm/screen_security');

  final MethodChannel _channel;

  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Returns whether the flag was actually applied.
  ///
  /// A false return is not swallowed: the caller needs to know the difference between "protected"
  /// and "asked for protection and did not get it".
  Future<bool> setSecure({required bool secure}) async {
    try {
      return await _channel.invokeMethod<bool>('setSecure', {'secure': secure}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
