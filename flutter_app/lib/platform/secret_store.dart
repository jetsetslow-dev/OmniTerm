import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// At-rest encryption for stored credentials, ported from `data/SecretStore.kt`.
///
/// Protects every secret the app persists: server passwords, sudo passwords, proxy passwords,
/// imported private keys, credential-profile passwords and share passwords.
///
/// ## Why this is not a straight port — and why it matters (MIGRATION.md §7.10)
///
/// The Kotlin encrypted with AES-GCM under a key generated **inside the Android Keystore**, which
/// never leaves it (hardware-backed where the device supports it). A Flutter app cannot use that key
/// as a cipher: no plugin exposes "encrypt with Keystore alias X", and the key is non-exportable by
/// design.
///
/// So the Dart implementation generates its **own** 256-bit AES key, stores it in
/// `flutter_secure_storage` (Keystore-backed on Android, Keychain on iOS) and performs AES-GCM
/// in Dart. Values it writes are tagged `enc:v2:`.
///
/// **The consequence is a real migration hazard, not a detail:** every existing `enc:v1:` value on a
/// user's device was encrypted with the old Keystore key and *cannot* be decrypted here. Left
/// unhandled, an updating user would open the app to find every saved password and private key
/// silently blank. [legacyDecryptor] is the seam for the Android-only platform channel that decrypts
/// `enc:v1:` with the original Keystore alias; [decrypt] then transparently re-encrypts to `v2` via
/// [onUpgraded] so the migration happens once, in the background, per value.
///
/// Security note under requirement 12: the v2 key is retrievable into app memory, whereas the v1 key
/// was not. That is a genuine reduction, accepted because the alternative — writing and maintaining
/// two native crypto implementations — is a larger code-security surface than the one it removes,
/// and because the at-rest protection (a Keystore/Keychain-guarded key) is preserved.
class SecretStore {
  SecretStore({
    FlutterSecureStorage? storage,
    this.legacyDecryptor,
    this.onUpgraded,
  }) : _storage = storage ??
            const FlutterSecureStorage(
              // Android's default is now a custom cipher (Jetpack Security was deprecated by
              // Google); iOS pins the key to this device and requires a first unlock, so a backup
              // restored onto another handset cannot carry the key with it.
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
            );

  /// Marks a value encrypted by the **Kotlin** app, under the Android Keystore key.
  static const legacyPrefix = 'enc:v1:';

  /// Marks a value encrypted by this implementation.
  static const prefix = 'enc:v2:';

  static const _keyStorageName = 'omniterm_secret_key_v2';
  static const _ivBytes = 12;

  final FlutterSecureStorage _storage;

  /// Decrypts a legacy `enc:v1:` value. Supplied on Android by a platform channel that uses the
  /// original Keystore alias; null elsewhere (iOS has no legacy data to inherit).
  final Future<String?> Function(String legacyValue)? legacyDecryptor;

  /// Invoked with (original, re-encrypted) when a legacy value has been upgraded, so the caller can
  /// write the new ciphertext back to the database.
  final void Function(String legacyValue, String upgradedValue)? onUpgraded;

  final _algorithm = AesGcm.with256bits();
  SecretKey? _cachedKey;

  /// True for anything this app should treat as ciphertext, in either format.
  static bool isEncrypted(String? value) =>
      value != null && (value.startsWith(prefix) || value.startsWith(legacyPrefix));

  /// True specifically for a value written by the Kotlin app.
  static bool isLegacyEncrypted(String? value) =>
      value != null && value.startsWith(legacyPrefix);

  Future<SecretKey> _key() async {
    final cached = _cachedKey;
    if (cached != null) return cached;

    final stored = await _storage.read(key: _keyStorageName);
    if (stored != null && stored.isNotEmpty) {
      final key = SecretKey(base64Decode(stored));
      _cachedKey = key;
      return key;
    }

    final key = await _algorithm.newSecretKey();
    await _storage.write(key: _keyStorageName, value: base64Encode(await key.extractBytes()));
    _cachedKey = key;
    return key;
  }

  /// Encrypts [value]. Null, empty and already-encrypted values pass through unchanged, matching
  /// the Kotlin so callers can encrypt idempotently.
  Future<String?> encrypt(String? value) async {
    if (value == null || value.isEmpty || isEncrypted(value)) return value;

    final secretBox = await _algorithm.encrypt(
      utf8.encode(value),
      secretKey: await _key(),
    );
    // Same wire layout as the Kotlin: iv || ciphertext || tag, base64 with no wrapping.
    final payload = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    return '$prefix${base64Encode(payload)}';
  }

  /// Decrypts [value].
  ///
  /// Returns the input unchanged when it is null or empty, and **null when the value is not
  /// encrypted at all** — the Kotlin contract, which callers rely on to distinguish "no secret
  /// stored" from "stored but unreadable".
  Future<String?> decrypt(String? value) async {
    if (value == null || value.isEmpty) return value;

    if (isLegacyEncrypted(value)) return _decryptLegacy(value);
    if (!value.startsWith(prefix)) return null;

    try {
      final payload = base64Decode(value.substring(prefix.length));
      if (payload.length <= _ivBytes + 16) return null;
      final nonce = payload.sublist(0, _ivBytes);
      final macBytes = payload.sublist(payload.length - 16);
      final cipherText = payload.sublist(_ivBytes, payload.length - 16);

      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: await _key(),
      );
      return utf8.decode(clear);
    } catch (_) {
      // A value tagged as ours failed to decrypt — corrupted ciphertext, or a rotated/lost key.
      // Callers keep their existing null fallback; the secret itself is never logged.
      return null;
    }
  }

  /// Decrypts a Kotlin-era value and re-encrypts it under the current key.
  Future<String?> _decryptLegacy(String value) async {
    final decryptor = legacyDecryptor;
    if (decryptor == null) return null;
    try {
      final clear = await decryptor(value);
      if (clear == null || clear.isEmpty) return clear;
      final upgraded = await encrypt(clear);
      if (upgraded != null) onUpgraded?.call(value, upgraded);
      return clear;
    } catch (_) {
      return null;
    }
  }
}
