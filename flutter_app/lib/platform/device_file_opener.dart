import 'package:flutter/services.dart';

/// What happened when a downloaded file was handed to the device's own apps.
enum DeviceOpenOutcome { opened, noApp, failed }

/// "Open with device app", the Kotlin app's `openRemoteFileWithDevice`: the remote file is
/// downloaded into a private cache directory that only this feature uses, then offered to the
/// device's viewers through Android's FileProvider and an "Open with" chooser.
///
/// Android goes through `DeviceFileOpenerBridge`. Elsewhere there is no bridge, [previewDirectory]
/// returns null and the option is not offered.
class DeviceFileOpener {
  const DeviceFileOpener([this._channel = const MethodChannel('omniterm/file_opener')]);

  final MethodChannel _channel;

  /// The directory to download into, emptied first; null where the platform has no bridge.
  Future<String?> previewDirectory() async {
    try {
      return await _channel.invokeMethod<String>('previewDirectory');
    } on MissingPluginException {
      return null;
    }
  }

  /// Shows the chooser for [path], which must be a file directly inside [previewDirectory].
  Future<DeviceOpenOutcome> open(String path) async {
    try {
      return switch (await _channel.invokeMethod<String>('open', {'path': path})) {
        'opened' => DeviceOpenOutcome.opened,
        'no_app' => DeviceOpenOutcome.noApp,
        _ => DeviceOpenOutcome.failed,
      };
    } on MissingPluginException {
      return DeviceOpenOutcome.failed;
    } on PlatformException {
      return DeviceOpenOutcome.failed;
    }
  }
}
