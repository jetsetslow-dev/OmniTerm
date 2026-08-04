import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Dart half of the Android bridge that reads credentials the Kotlin app wrote
/// (MIGRATION.md §7.10).
///
/// Every credential the old app stored — server, sudo and proxy passwords, imported private keys,
/// credential-profile and share passwords — was encrypted under a non-exportable Android Keystore
/// key. The Dart port cannot use that key, so without this an updating user would find every saved
/// secret silently blank.
///
/// Wire it into `SecretStore.legacyDecryptor`. It is a no-op everywhere except Android: iOS, desktop
/// and web have no legacy data, and calling the channel there would only produce a
/// `MissingPluginException` per secret.
class LegacySecretChannel {
  LegacySecretChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.jetsetslow.omniterm/legacy_secrets';

  final MethodChannel _channel;

  /// Whether this platform can have legacy data at all.
  ///
  /// `defaultTargetPlatform` is deliberately not used: it reports the *design* platform, so a debug
  /// build previewing Android on a desktop host would try a channel that is not there.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  bool? _hasKey;

  /// True when this device has the Kotlin app's Keystore key.
  ///
  /// Cached after the first call so a fresh install pays one platform round trip rather than one
  /// per secret to keep learning there is nothing to migrate.
  Future<bool> hasLegacyKey() async {
    if (!isSupported) return false;
    if (_hasKey != null) return _hasKey!;
    try {
      _hasKey = await _channel.invokeMethod<bool>('hasLegacyKey') ?? false;
    } on PlatformException {
      _hasKey = false;
    } on MissingPluginException {
      // The host build predates the bridge. Treating this as "no legacy key" degrades to exactly
      // the behaviour before it existed, rather than failing the read.
      _hasKey = false;
    }
    return _hasKey!;
  }

  /// Returns the plaintext of an `enc:v1:` value, or null if it cannot be read.
  ///
  /// Null covers every failure — no key, a key invalidated by the user removing their device lock,
  /// or ciphertext failing its GCM tag. `SecretStore` treats null as "leave the stored value
  /// alone", so an unreadable secret stays on disk instead of being overwritten with a blank: a
  /// later OS or app version may still recover it, whereas an overwrite is final.
  Future<String?> decrypt(String legacyValue) async {
    if (!isSupported) return null;
    if (!await hasLegacyKey()) return null;
    try {
      return await _channel.invokeMethod<String>('decryptLegacy', legacyValue);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
