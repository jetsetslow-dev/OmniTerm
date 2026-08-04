import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/legacy_secret_channel.dart';
import 'package:omniterm/platform/secret_store.dart';

import 'support/fake_secure_storage.dart';

/// MIGRATION.md §7.10. The Kotlin app encrypted every credential under a non-exportable Android
/// Keystore key, so without the bridge an updating user finds every saved secret blank. These tests
/// cover the property that matters most: a secret is either migrated correctly or left exactly
/// as it was — never replaced with an empty value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  /// Stands in for the Android Keystore: maps `enc:v1:<token>` to its plaintext.
  late Map<String, String> vault;
  late List<String> decryptCalls;

  AppRepository repositoryWith({bool bridgeAvailable = true}) {
    return AppRepository(
      db,
      SecretStore(
        storage: FakeSecureStorage(<String, String>{}),
        legacyDecryptor: (value) async {
          decryptCalls.add(value);
          if (!bridgeAvailable) return null;
          return vault[value];
        },
      ),
    );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    vault = {};
    decryptCalls = [];
  });

  tearDown(() async => db.close());

  Server server({
    required String name,
    String? authPassword,
    String sudoPassword = '',
    String proxyPassword = '',
  }) => Server(
    id: 0,
    name: name,
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: authPassword,
    sudoPassword: sudoPassword,
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: false,
    proxyCommand: '',
    proxyType: 'none',
    proxyHost: '',
    proxyPort: 0,
    proxyUser: '',
    proxyPassword: proxyPassword,
    agentForwarding: false,
    healthScore: 100,
    lastLatency: 0,
    status: 'offline',
    authStatus: 'unknown',
  );

  /// Writes a row with its secrets already in the Kotlin `enc:v1:` form, bypassing encryption.
  Future<int> insertLegacyServer(Server row) =>
      db.serverDao.insertServer(row.toCompanion(false).copyWith(id: const Value.absent()));

  test('a legacy password is migrated and reads back as plaintext', () async {
    vault['enc:v1:AAAA'] = 'hunter2';
    await insertLegacyServer(server(name: 'nas', authPassword: 'enc:v1:AAAA'));

    final repo = repositoryWith();
    expect(await repo.migrateLegacySecrets(), 1);

    final stored = await db.serverDao.getAllServers();
    expect(
      stored.single.authPassword,
      startsWith(SecretStore.prefix),
      reason: 'the value on disk is now encrypted under the Dart key',
    );
    expect((await repo.getAllServers()).single.authPassword, 'hunter2');
  });

  test('every secret column is covered, not just the login password', () async {
    vault['enc:v1:A'] = 'login';
    vault['enc:v1:B'] = 'sudo';
    vault['enc:v1:C'] = 'proxy';
    await insertLegacyServer(
      server(
        name: 'nas',
        authPassword: 'enc:v1:A',
        sudoPassword: 'enc:v1:B',
        proxyPassword: 'enc:v1:C',
      ),
    );

    final repo = repositoryWith();
    expect(await repo.migrateLegacySecrets(), 3);

    final row = (await repo.getAllServers()).single;
    expect(row.authPassword, 'login');
    expect(row.sudoPassword, 'sudo');
    expect(row.proxyPassword, 'proxy');
  });

  test('private keys and credential profiles migrate too', () async {
    vault['enc:v1:KEY'] = '-----BEGIN OPENSSH PRIVATE KEY-----';
    vault['enc:v1:PROF'] = 'profile-pw';
    await db.appDataDao.insertKey(
      SshKey(
        id: 0,
        alias: 'laptop',
        keyType: 'Ed25519',
        privateKey: 'enc:v1:KEY',
        publicKey: 'ssh-ed25519 AAAA',
        fingerprint: 'SHA256:x',
      ).toCompanion(false).copyWith(id: const Value.absent()),
    );
    await db.appDataDao.insertProfile(
      CredentialProfile(
        id: 0,
        profileName: 'shared',
        username: 'deploy',
        authType: 'password',
        password: 'enc:v1:PROF',
        groupName: 'General',
      ).toCompanion(false).copyWith(id: const Value.absent()),
    );

    final repo = repositoryWith();
    expect(await repo.migrateLegacySecrets(), 2);

    expect((await repo.getAllKeys()).single.privateKey, '-----BEGIN OPENSSH PRIVATE KEY-----');
    expect((await repo.getAllProfiles()).single.password, 'profile-pw');
  });

  group('a value that cannot be read is left alone', () {
    test('an unreadable secret keeps its exact bytes on disk', () async {
      // This is the whole point: overwriting it with a blank is final, whereas leaving it lets a
      // later OS or app version recover it.
      await insertLegacyServer(server(name: 'nas', authPassword: 'enc:v1:UNREADABLE'));

      final repo = repositoryWith();
      expect(await repo.migrateLegacySecrets(), 0);

      expect((await db.serverDao.getAllServers()).single.authPassword, 'enc:v1:UNREADABLE');
    });

    test('a device with no bridge at all changes nothing', () async {
      vault['enc:v1:A'] = 'hunter2';
      await insertLegacyServer(server(name: 'nas', authPassword: 'enc:v1:A'));

      final repo = repositoryWith(bridgeAvailable: false);
      expect(await repo.migrateLegacySecrets(), 0);
      expect((await db.serverDao.getAllServers()).single.authPassword, 'enc:v1:A');
    });

    test('one unreadable secret does not block the others', () async {
      vault['enc:v1:GOOD'] = 'recovered';
      await insertLegacyServer(server(name: 'a', authPassword: 'enc:v1:BAD'));
      await insertLegacyServer(server(name: 'b', authPassword: 'enc:v1:GOOD'));

      final repo = repositoryWith();
      expect(await repo.migrateLegacySecrets(), 1);

      final rows = await repo.getAllServers();
      expect(rows.firstWhere((s) => s.name == 'b').authPassword, 'recovered');
    });
  });

  group('the pass is safe to run on every launch', () {
    test('it is idempotent and touches the channel only once per value', () async {
      vault['enc:v1:A'] = 'hunter2';
      await insertLegacyServer(server(name: 'nas', authPassword: 'enc:v1:A'));

      final repo = repositoryWith();
      expect(await repo.migrateLegacySecrets(), 1);
      final callsAfterFirst = decryptCalls.length;

      expect(await repo.migrateLegacySecrets(), 0);
      expect(
        decryptCalls.length,
        callsAfterFirst,
        reason: 'an enc:v2: value must not reach the platform channel again',
      );
    });

    test('a fresh install with no legacy data does nothing', () async {
      final repo = repositoryWith();
      await repo.insertServer(server(name: 'new', authPassword: 'typed-today'));

      expect(await repo.migrateLegacySecrets(), 0);
      expect(decryptCalls, isEmpty);
      expect((await repo.getAllServers()).single.authPassword, 'typed-today');
    });

    test('an empty secret is not sent to the channel', () async {
      await insertLegacyServer(server(name: 'nas', authPassword: ''));
      final repo = repositoryWith();
      expect(await repo.migrateLegacySecrets(), 0);
      expect(decryptCalls, isEmpty);
    });
  });

  group('LegacySecretChannel', () {
    const channel = MethodChannel(LegacySecretChannel.channelName);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    test('it asks the platform once whether a legacy key exists', () async {
      var keyChecks = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          if (call.method == 'hasLegacyKey') {
            keyChecks++;
            return true;
          }
          return 'plaintext';
        },
      );

      final bridge = LegacySecretChannel(channel: channel);
      // The check is cached so a fresh install pays one round trip, not one per secret.
      await bridge.decrypt('enc:v1:A');
      await bridge.decrypt('enc:v1:B');
      expect(keyChecks, LegacySecretChannel.isSupported ? 1 : 0);
    });

    test('a platform failure returns null rather than throwing into the read path', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          if (call.method == 'hasLegacyKey') return true;
          throw PlatformException(code: 'KEY_INVALIDATED');
        },
      );

      final bridge = LegacySecretChannel(channel: channel);
      expect(await bridge.decrypt('enc:v1:A'), isNull);
    });

    test('a host build without the bridge degrades instead of failing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );

      final bridge = LegacySecretChannel(channel: channel);
      expect(await bridge.hasLegacyKey(), isFalse);
      expect(await bridge.decrypt('enc:v1:A'), isNull);
    });

    test('no legacy key means no decrypt call at all', () async {
      var decryptCallsMade = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          if (call.method == 'hasLegacyKey') return false;
          decryptCallsMade++;
          return null;
        },
      );

      final bridge = LegacySecretChannel(channel: channel);
      expect(await bridge.decrypt('enc:v1:A'), isNull);
      expect(decryptCallsMade, 0);
    });
  });
}
