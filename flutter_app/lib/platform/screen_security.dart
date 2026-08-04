import 'package:flutter/services.dart';

/// Keeps the app's contents out of screenshots, screen recordings and the task-switcher thumbnail.
///
/// Backed by Android's `FLAG_SECURE` (see `ScreenSecurityBridge.kt`). On a terminal app the
/// task-switcher thumbnail is the real exposure: the OS captures it automatically, it survives
/// backgrounding, and it routinely contains a live root shell.
///
/// [isSupported] is asked of the platform rather than assumed, so the Settings screen can tell the
/// user the option does nothing here instead of implying a protection that is not being applied.
/// iOS has no API to block screenshots; it reports unsupported until the `willResignActive` cover
/// is built.
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
