import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/secret_store.dart';

/// In-memory stand-in for the platform keystore, so the crypto is testable off-device.
class FakeSecureStorage extends FlutterSecureStorage {
  const FakeSecureStorage(this._values);

  final Map<String, String> _values;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

void main() {
  late Map<String, String> keychain;

  SecretStore store({
    Future<String?> Function(String)? legacyDecryptor,
    void Function(String, String)? onUpgraded,
  }) =>
      SecretStore(
        storage: FakeSecureStorage(keychain),
        legacyDecryptor: legacyDecryptor,
        onUpgraded: onUpgraded,
      );

  setUp(() => keychain = {});

  group('round trip', () {
    test('encrypts and decrypts a secret', () async {
      final s = store();
      final cipher = await s.encrypt('hunter2');
      expect(cipher, isNotNull);
      expect(cipher, startsWith(SecretStore.prefix));
      expect(cipher, isNot(contains('hunter2')), reason: 'the plaintext must not survive');
      expect(await s.decrypt(cipher), 'hunter2');
    });

    test('round-trips a full private key and unicode', () async {
      final s = store();
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----';
      expect(await s.decrypt(await s.encrypt(pem)), pem);
      expect(await s.decrypt(await s.encrypt('пароль 日本 🔐')), 'пароль 日本 🔐');
    });

    test('the same plaintext encrypts differently each time', () async {
      // A fresh nonce per encryption; identical ciphertext would leak that two hosts share a
      // password.
      final s = store();
      final a = await s.encrypt('same');
      final b = await s.encrypt('same');
      expect(a, isNot(b));
      expect(await s.decrypt(a), 'same');
      expect(await s.decrypt(b), 'same');
    });

    test('the key persists across instances', () async {
      final cipher = await store().encrypt('secret');
      // A second store sharing the same keychain must still read it.
      expect(await store().decrypt(cipher), 'secret');
    });

    test('a different keychain cannot decrypt', () async {
      final cipher = await store().encrypt('secret');
      keychain = {}; // simulate a wiped/reinstalled keystore
      expect(await store().decrypt(cipher), isNull,
          reason: 'must fail closed rather than returning garbage');
    });
  });

  group('pass-through contract', () {
    test('null and empty are returned unchanged', () async {
      final s = store();
      expect(await s.encrypt(null), isNull);
      expect(await s.encrypt(''), '');
      expect(await s.decrypt(null), isNull);
      expect(await s.decrypt(''), '');
    });

    test('encrypting is idempotent', () async {
      // Callers encrypt on every save without checking, so double-encryption must not corrupt.
      final s = store();
      final once = await s.encrypt('x');
      expect(await s.encrypt(once), once);
      expect(await s.decrypt(once), 'x');
    });

    test('decrypting plaintext returns null, not the plaintext', () async {
      // The Kotlin contract callers rely on to tell "no secret stored" from "stored but unreadable".
      expect(await store().decrypt('not-encrypted'), isNull);
    });

    test('isEncrypted recognises both formats', () {
      expect(SecretStore.isEncrypted('enc:v2:abc'), isTrue);
      expect(SecretStore.isEncrypted('enc:v1:abc'), isTrue);
      expect(SecretStore.isEncrypted('plain'), isFalse);
      expect(SecretStore.isEncrypted(null), isFalse);
      expect(SecretStore.isLegacyEncrypted('enc:v1:abc'), isTrue);
      expect(SecretStore.isLegacyEncrypted('enc:v2:abc'), isFalse);
    });
  });

  group('corrupt ciphertext fails closed', () {
    test('a tampered payload does not decrypt', () async {
      // AES-GCM authenticates: flipping a byte must be detected, not silently returned.
      final s = store();
      final cipher = (await s.encrypt('secret'))!;
      final body = cipher.substring(SecretStore.prefix.length);
      final tampered = '${SecretStore.prefix}${body.substring(0, body.length - 4)}AAAA';
      expect(await s.decrypt(tampered), isNull);
    });

    test('a truncated or unparseable payload returns null', () async {
      final s = store();
      expect(await s.decrypt('enc:v2:shortish'), isNull);
      expect(await s.decrypt('enc:v2:!!!not-base64!!!'), isNull);
      expect(await s.decrypt('enc:v2:'), isNull);
    });
  });

  group('legacy migration', () {
    // The hazard this exists for: every credential on an updating user's device is enc:v1:, sealed
    // by an Android Keystore key Flutter cannot use. Without a decryptor they read as blank.

    test('without a decryptor, a legacy value reads as null', () async {
      expect(await store().decrypt('enc:v1:whatever'), isNull);
    });

    test('a legacy value is decrypted through the platform seam', () async {
      final s = store(legacyDecryptor: (v) async => 'recovered');
      expect(await s.decrypt('enc:v1:whatever'), 'recovered');
    });

    test('a decrypted legacy value is re-encrypted to v2 and reported', () async {
      final upgrades = <String, String>{};
      final s = store(
        legacyDecryptor: (v) async => 'recovered',
        onUpgraded: (from, to) => upgrades[from] = to,
      );

      expect(await s.decrypt('enc:v1:whatever'), 'recovered');
      expect(upgrades, hasLength(1), reason: 'the caller must be told to write the new ciphertext');

      final upgraded = upgrades['enc:v1:whatever']!;
      expect(upgraded, startsWith(SecretStore.prefix));
      expect(await s.decrypt(upgraded), 'recovered',
          reason: 'the upgraded value must be readable without the legacy path');
    });

    test('a failing decryptor degrades to null rather than throwing', () async {
      final s = store(legacyDecryptor: (v) async => throw StateError('keystore gone'));
      expect(await s.decrypt('enc:v1:whatever'), isNull);
    });

    test('a legacy value that decrypts to empty is not re-encrypted', () async {
      var upgrades = 0;
      final s = store(
        legacyDecryptor: (v) async => '',
        onUpgraded: (_, _) => upgrades++,
      );
      expect(await s.decrypt('enc:v1:whatever'), '');
      expect(upgrades, 0);
    });
  });
}
