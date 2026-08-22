import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';

/// In-memory keystore so the real crypto runs off-device.
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
  }) async => _values[key];

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
  late AppDatabase db;
  late AppRepository repo;
  late Map<String, String> keychain;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    keychain = {};
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(keychain)));
  });
  tearDown(() => db.close());

  Server server({
    String name = 'nas',
    String? authPassword,
    String sudoPassword = '',
    String proxyPassword = '',
  }) => Server(
    id: 0,
    name: name,
    host: '10.0.0.2',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: authPassword,
    sudoPassword: sudoPassword,
    proxyPassword: proxyPassword,
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: false,
    proxyCommand: '',
    proxyType: 'none',
    proxyHost: '',
    proxyPort: 0,
    proxyUser: '',
    agentForwarding: false,
    healthScore: 100,
    lastLatency: 0,
    status: 'offline',
    authStatus: 'unknown',
  );

  /// Reads a column straight from the table, bypassing the repository's decryption.
  Future<String?> rawServerColumn(int id, String column) async {
    final row = await db
        .customSelect(
          'SELECT $column AS v FROM servers WHERE id = ?',
          variables: [Variable.withInt(id)],
        )
        .getSingle();
    return row.data['v'] as String?;
  }

  group('credentials never reach the database in the clear', () {
    test('server passwords are encrypted at rest and decrypted on read', () async {
      final id = await repo.insertServer(
        server(
          authPassword: 'auth-secret',
          sudoPassword: 'sudo-secret',
          proxyPassword: 'proxy-secret',
        ),
      );

      // The stored bytes must not contain any plaintext.
      for (final column in ['authPassword', 'sudoPassword', 'proxyPassword']) {
        final stored = await rawServerColumn(id, column);
        expect(stored, startsWith(SecretStore.prefix), reason: column);
        expect(stored, isNot(contains('secret')), reason: column);
      }

      // …and the repository hands back plaintext.
      final loaded = (await repo.getServerById(id))!;
      expect(loaded.authPassword, 'auth-secret');
      expect(loaded.sudoPassword, 'sudo-secret');
      expect(loaded.proxyPassword, 'proxy-secret');
    });

    test('private keys are encrypted at rest', () async {
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----';
      await repo.insertKey(
        SshKey(
          id: 0,
          alias: 'laptop',
          keyType: 'Ed25519',
          privateKey: pem,
          publicKey: 'ssh-ed25519 AAAA',
          fingerprint: 'SHA256:x',
        ),
      );

      final raw = await db.customSelect('SELECT privateKey AS v FROM ssh_keys').getSingle();
      expect(raw.data['v'] as String, isNot(contains('PRIVATE KEY')));
      expect((await repo.getAllKeys()).single.privateKey, pem);
      // The public half is not a secret and must stay readable.
      expect((await repo.getAllKeys()).single.publicKey, 'ssh-ed25519 AAAA');
    });

    test('credential-profile and share passwords are encrypted at rest', () async {
      await repo.insertProfile(
        CredentialProfile(
          id: 0,
          profileName: 'admin',
          username: 'root',
          authType: 'password',
          password: 'profile-secret',
          groupName: 'General',
        ),
      );
      await repo.insertNetworkShare(
        NetworkShare(
          id: 0,
          name: 'media',
          protocol: 'SMB',
          address: '10.0.0.5',
          port: 445,
          sharePath: 'Public',
          workgroup: '',
          username: 'guest',
          password: 'share-secret',
          anonymous: false,
          useHttps: false,
          notes: '',
          lastChecked: 0,
          lastStatus: 'unknown',
        ),
      );

      final profileRaw = await db
          .customSelect('SELECT password AS v FROM credential_profiles')
          .getSingle();
      final shareRaw = await db
          .customSelect('SELECT password AS v FROM network_shares')
          .getSingle();
      expect(profileRaw.data['v'] as String, isNot(contains('secret')));
      expect(shareRaw.data['v'] as String, isNot(contains('secret')));

      expect((await repo.getAllProfiles()).single.password, 'profile-secret');
      expect((await repo.getAllNetworkShares()).single.password, 'share-secret');
    });

    test('the decrypting stream also yields plaintext', () async {
      await repo.insertServer(server(authPassword: 'streamed'));
      final servers = await repo.serversStream.first;
      expect(servers.single.authPassword, 'streamed');
    });

    test('an empty password stays empty rather than becoming ciphertext', () async {
      final id = await repo.insertServer(server(sudoPassword: ''));
      expect(await rawServerColumn(id, 'sudoPassword'), '');
      expect((await repo.getServerById(id))!.sudoPassword, '');
    });

    test('a null password round-trips as null', () async {
      final id = await repo.insertServer(server());
      expect((await repo.getServerById(id))!.authPassword, isNull);
    });
  });

  group('secure settings', () {
    test('only the listed keys are encrypted', () async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('theme', 'amoled');

      final pin = await db.appDataDao.getSetting('app_pin');
      final theme = await db.appDataDao.getSetting('theme');
      expect(pin!.value, startsWith(SecretStore.prefix));
      expect(
        theme!.value,
        'amoled',
        reason: 'encrypting the theme name would only make it unreadable to no benefit',
      );

      expect(await repo.getSetting('app_pin'), '1234');
      expect(await repo.getSetting('theme'), 'amoled');
    });

    test('a missing setting reads as null', () async {
      expect(await repo.getSetting('absent'), isNull);
    });
  });

  group('deleteServerAndDependents', () {
    test('removes the host and everything referencing it', () async {
      final id = await repo.insertServer(server());
      await repo.insertRule(
        AlertRulesCompanion.insert(
          serverId: id,
          metricName: 'CPU Usage',
          thresholdValue: 90,
          severity: 'CRITICAL',
        ),
      );
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: id, name: 'tunnel', bindPort: 8080),
      );
      await repo.insertSetting('sftp_bookmarks_$id', '/var/log');
      await db.serverDao.insertMetric(
        MetricHistoryCompanion.insert(
          serverId: id,
          timestamp: 1,
          cpuUsage: 1,
          ramUsage: 1,
          diskUsage: 1,
          latency: 1,
          networkIn: 1,
          networkOut: 1,
        ),
      );

      await repo.deleteServerAndDependents(id);

      expect(await repo.getServerById(id), isNull);
      expect(await repo.getRulesForServer(id), isEmpty);
      expect(await repo.getAllPortForwards(), isEmpty);
      expect(await repo.getMetricsForServer(id), isEmpty);
      expect(await repo.getSetting('sftp_bookmarks_$id'), isNull);
    });

    test('leaves another host untouched', () async {
      final doomed = await repo.insertServer(server(name: 'doomed'));
      final kept = await repo.insertServer(server(name: 'kept'));
      await repo.insertSetting('sftp_bookmarks_$kept', '/home');

      await repo.deleteServerAndDependents(doomed);

      expect((await repo.getAllServers()).map((s) => s.name), ['kept']);
      expect(await repo.getSetting('sftp_bookmarks_$kept'), '/home');
    });
  });

  group('keepOnlyServers', () {
    test('keeps the listed hosts and drops the rest with their dependents', () async {
      final keep = await repo.insertServer(server(name: 'keep'));
      final drop = await repo.insertServer(server(name: 'drop'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: drop, name: 'gone', bindPort: 1),
      );
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: keep, name: 'stays', bindPort: 2),
      );

      await repo.keepOnlyServers({keep});

      expect((await repo.getAllServers()).map((s) => s.name), ['keep']);
      expect((await repo.getAllPortForwards()).map((p) => p.name), ['stays']);
    });

    test('an empty keep-set removes every host without tripping on an empty IN list', () async {
      // SQLite handles `IN ()` inconsistently across versions, which is why the sentinel exists.
      await repo.insertServer(server(name: 'a'));
      await repo.insertServer(server(name: 'b'));

      await repo.keepOnlyServers({});

      expect(await repo.getAllServers(), isEmpty);
    });

    test('fleet-wide alert rules survive a partial restore', () async {
      final keep = await repo.insertServer(server(name: 'keep'));
      await repo.insertServer(server(name: 'drop'));
      await repo.insertRule(
        AlertRulesCompanion.insert(
          serverId: 0, // fleet-wide
          metricName: 'CPU Usage',
          thresholdValue: 90,
          severity: 'CRITICAL',
        ),
      );

      await repo.keepOnlyServers({keep});

      expect(
        (await repo.getAllRules()).map((r) => r.serverId),
        [0],
        reason: 'dropping rule 0 would silently disable fleet-wide alerting',
      );
    });
  });

  group('retention clamping', () {
    test('an out-of-range history limit is clamped, not obeyed', () async {
      Future<void> addHistory(int time) => repo.insertAlertHistory(
        AlertHistoryCompanion.insert(
          activeAlertId: time,
          serverId: 1,
          serverName: 'h',
          metricName: 'CPU Usage',
          currentValue: 95,
          thresholdValue: 90,
          severity: 'CRITICAL',
          triggeredTime: time,
          historyTime: time,
          status: 'RESOLVED',
        ),
      );

      for (var i = 1; i <= 12; i++) {
        await addHistory(i * 10);
      }
      // A limit of 0 would otherwise delete the entire history on the next prune.
      await repo.pruneAlertHistoryPerServer(0);
      expect(await repo.getAlertHistory(), hasLength(10));
    });
  });

  test('inTransaction rolls back on failure', () async {
    await repo.insertServer(server(name: 'before'));
    await expectLater(
      repo.inTransaction(() async {
        await repo.insertServer(server(name: 'during'));
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect((await repo.getAllServers()).map((s) => s.name), ['before']);
  });
}
