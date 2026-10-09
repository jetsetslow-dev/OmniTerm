import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ssh_host_key_trust.dart';

/// The trust store's pinned host keys, kept in the platform keystore/keychain.
///
/// Ported from the `EncryptedSharedPreferences`-backed store the Kotlin used. A pinned fingerprint
/// is not a secret — it is public information — but it *is* integrity-critical: an attacker who can
/// rewrite it can silently re-pin a host to their own key and every later connection succeeds
/// without a warning. Keeping it where the OS protects it from other apps and from a rooted-device
/// file read is the point, not confidentiality.
class SecureHostKeyStore implements HostKeyStore {
  SecureHostKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Matches `SecretStore`: the key is pinned to this device and needs a first unlock, so
            // a backup restored onto another handset cannot carry the trust store with it. A
            // transplanted pin would authorise a host the new owner never verified.
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  /// Namespaces these entries so [readAll] and [deleteAll] cannot see — or wipe — the credential
  /// secrets, session keys and everything else sharing the same keychain.
  static const prefix = 'hostkey.';

  @override
  Future<Map<String, String>> readAll() async {
    final all = await _storage.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
    };
  }

  @override
  Future<String?> read(String key) => _storage.read(key: '$prefix$key');

  @override
  Future<void> write(String key, String value) => _storage.write(key: '$prefix$key', value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: '$prefix$key');

  @override
  Future<void> deleteAll() async {
    final all = await _storage.readAll();
    for (final key in all.keys) {
      // Deliberately not `_storage.deleteAll()`: that would take the encryption key and every saved
      // credential with it. "Forget every host key" must mean exactly that.
      if (key.startsWith(prefix)) await _storage.delete(key: key);
    }
  }
}
