import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// At-rest encryption for stored credentials, ported from `data/SecretStore.kt`.
///
/// Protects every secret the app persists: server passwords, sudo passwords, proxy passwords,
/// imported private keys, credential-profile passwords and share passwords.
///
/// ## Why this is not a straight port — and why it matters
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
  SecretStore({FlutterSecureStorage? storage, this.legacyDecryptor, this.onUpgraded})
    : _storage =
          storage ?? const FlutterSecureStorage(iOptions: iosOptions, aOptions: androidOptions);

  /// iOS pins the key to this device and requires a first unlock, so a backup restored onto another
  /// handset cannot carry the key with it.
  static const iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  /// Android options, stated rather than inherited — the default is destructive here.
  ///
  /// `resetOnError` defaults to **true**, and the plugin means it literally: a failed read calls
  /// `delete(key)`, a failed `readAll` calls `deleteAll()`, and a failed migration calls
  /// `deleteAllDataAndKeys` (`FlutterSecureStorage.java`, `handleStorageError`). This store keeps
  /// exactly one thing here — [_keyStorageName], the AES key that every `enc:v2:` credential in the
  /// database is encrypted under — so "delete the key that failed to read once" means every saved
  /// password, sudo password, proxy password, private key, profile password and share password
  /// becomes permanently undecryptable, with the ciphertext still sitting in the database looking
  /// intact.
  ///
  /// [_key] would then complete the job: it treats a missing key as "first run" and mints a new one,
  /// so the app would carry on encrypting under a fresh key and never report anything wrong. That is
  /// the same silent-blanking this class's header warns about for the v1→v2 migration, arriving by a
  /// different route.
  ///
  /// Kotlin does none of this. `data/SecretStore.kt:35` logs the failure class — never the secret —
  /// and returns null, so a transient failure stays transient and the data survives it. With
  /// `resetOnError: false` the plugin surfaces the error instead of deleting, [decrypt] catches it
  /// and returns null exactly as Kotlin does, and the only null [_key] can see is a key that was
  /// genuinely never written.
  ///
  /// `migrateOnAlgorithmChange` keeps its default of true: that one preserves data across a plugin
  /// cipher change rather than discarding it.
  static const androidOptions = AndroidOptions(resetOnError: false);

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
  static bool isLegacyEncrypted(String? value) => value != null && value.startsWith(legacyPrefix);

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

    final secretBox = await _algorithm.encrypt(utf8.encode(value), secretKey: await _key());
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

  /// Re-encrypts a Kotlin-era value under the current key, returning the new `enc:v2:` ciphertext.
  ///
  /// Returns null when the value is not legacy, or when it cannot be read. Null must be treated as
  /// "leave the stored value exactly as it is": overwriting an unreadable secret with a blank is
  /// final, whereas leaving it lets a later OS or app version recover it.
  ///
  /// Deliberately returns *ciphertext* rather than plaintext. The migration pass runs over every
  /// stored credential at once, and there is no reason for that pass to hold a single plaintext
  /// password in a variable.
  Future<String?> upgradeLegacy(String? value) async {
    if (value == null || !isLegacyEncrypted(value)) return null;
    final decryptor = legacyDecryptor;
    if (decryptor == null) return null;
    try {
      final clear = await decryptor(value);
      if (clear == null || clear.isEmpty) return null;
      return encrypt(clear);
    } catch (_) {
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
