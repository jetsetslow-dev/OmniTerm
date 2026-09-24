import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How long a copied secret is left on the clipboard before it is taken back.
///
/// Kotlin's value (`ui/ToolsScreen.kt:129`). Long enough to switch apps and paste, short enough that
/// a key does not sit in the clipboard for the rest of the day.
const sensitiveClipboardLifetime = Duration(seconds: 60);

/// Copies secrets to the clipboard the way Kotlin's `copySensitiveClipboard` does: marked sensitive,
/// and taken back after a minute.
///
/// Two things `Clipboard.setData` cannot do on its own, both of which matter for the one secret this
/// app offers to copy — a freshly generated private key:
///
/// * From Android 13 the system shows a **preview** of whatever was copied, so the key appears on
///   screen beside the button pressed to keep it private. The platform's
///   `ClipDescription.EXTRA_IS_SENSITIVE` replaces that preview with a placeholder, and it is only
///   reachable through a method channel.
/// * A clipboard is readable by whatever the user pastes into next, indefinitely. Kotlin clears it
///   after 60 seconds — but only if it still holds the same text, so a clear never destroys
///   something the user copied afterwards.
///
/// Where the channel is unavailable (iOS, tests, desktop) the copy still happens through
/// [Clipboard]; the marker is Android-only, and silently skipping the copy would be worse than
/// skipping the marker.
class SensitiveClipboard {
  SensitiveClipboard({MethodChannel? channel, this.lifetime = sensitiveClipboardLifetime})
    : _channel = channel ?? const MethodChannel('omniterm/sensitive_clipboard');

  final MethodChannel _channel;

  /// Exposed so tests can drive the timer without waiting a real minute.
  final Duration lifetime;

  Timer? _clear;

  /// Copies [text], marking it sensitive, and schedules its removal.
  ///
  /// Only the most recent copy is scheduled: copying twice in a minute must not leave the first
  /// timer alive to clear the second value early.
  Future<void> copy({required String label, required String text}) async {
    _clear?.cancel();
    var copied = false;
    try {
      copied = await _channel.invokeMethod<bool>('copy', {'label': label, 'text': text}) ?? false;
    } on MissingPluginException {
      copied = false;
    } on PlatformException {
      copied = false;
    }
    if (!copied) await Clipboard.setData(ClipboardData(text: text));
    _clear = Timer(lifetime, () => unawaited(_clearIfUnchanged(text)));
  }

  /// Cancels a pending clear without touching the clipboard — for disposal, not for cancelling the
  /// protection.
  void dispose() {
    _clear?.cancel();
    _clear = null;
  }

  Future<void> _clearIfUnchanged(String text) async {
    try {
      final stillOurs = await _channel.invokeMethod<bool>('holds', {'text': text}) ?? false;
      if (stillOurs) await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // No channel: fall back to Flutter's own clipboard, which can still answer both questions.
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    } on PlatformException catch (e) {
      debugPrint('sensitive clipboard clear failed: ${e.code}');
    }
  }
}
