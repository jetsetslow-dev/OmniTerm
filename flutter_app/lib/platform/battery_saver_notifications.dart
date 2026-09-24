import 'package:flutter/services.dart';

abstract interface class BatterySaverNotifier {
  Future<void> showPrompt({required int percent});
  Future<void> showActive({required int percent});
  Future<void> cancel();
}

/// Android notification bridge for low-battery prompts that arrive while OmniTerm is backgrounded.
class BatterySaverNotifications implements BatterySaverNotifier {
  BatterySaverNotifications({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'omniterm/battery_saver';

  final MethodChannel _channel;

  @override
  Future<void> showPrompt({required int percent}) => _invoke('showPrompt', percent);

  @override
  Future<void> showActive({required int percent}) => _invoke('showActive', percent);

  @override
  Future<void> cancel() => _invoke('cancel');

  Future<void> _invoke(String method, [int? percent]) async {
    try {
      await _channel.invokeMethod<bool>(
        method,
        percent == null ? null : <String, Object?>{'percent': percent},
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
