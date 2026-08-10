import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/auth_keys_view_model.dart';

import 'support/ed25519_fixture.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  // Generated rather than committed: see test/support/ed25519_fixture.dart.
  late Ed25519Fixture keys;

  setUpAll(() async => keys = await sharedEd25519Fixture());

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({required String name, String? keyAlias, String? proxyKeyAlias, int? profileId}) =>
      Server(
        id: 0,
        name: name,
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: keyAlias != null ? 'key' : 'password',
        authKeyAlias: keyAlias,
        authProfileId: profileId,
        sudoPassword: '',
        notes: '',
        keepAlive: 30,
        sshCompression: false,
        persistentSession: false,
        proxyCommand: '',
        proxyType: 'none',
        proxyHost: '',
        proxyPort: 0,
        proxyUser: '',
        proxyPassword: '',
        proxyKeyAlias: proxyKeyAlias,
        agentForwarding: false,
        healthScore: 100,
        lastLatency: 0,
        status: 'offline',
        authStatus: 'unknown',
      );

  Future<AuthKeysViewModel> boot({SshHostKeyTrust? trust}) async {
    await app.start();
    final vm = AuthKeysViewModel(app, hostKeyTrust: trust);
    await vm.start();
    await Future<void>.delayed(Duration.zero);
    return vm;
  }

  group('importing a key', () {
    test('a valid key is stored with its type and fingerprint', () async {
      final vm = await boot();

      expect(
        await vm.importKey(alias: 'laptop', privateKey: keys.privateKey, publicKey: keys.publicKey),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);

      final stored = await repo.getAllKeys();
      expect(stored.single.alias, 'laptop');
      expect(stored.single.keyType, 'ED25519');
      expect(stored.single.fingerprint, startsWith('SHA256:'));
      expect(vm.status, contains('laptop'));
      vm.dispose();
    });

    test('the private key is encrypted at rest', () async {
      // The repository is the encrypt boundary; a key on disk in the clear would defeat it.
      final vm = await boot();
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await Future<void>.delayed(Duration.zero);

      final raw = await db.appDataDao.getAllKeys();
      expect(raw.single.privateKey, startsWith(SecretStore.prefix));
      expect((await repo.getAllKeys()).single.privateKey, keys.privateKey);
      vm.dispose();
    });

    test('a bad key is rejected with the parser\'s own reason', () async {
      final vm = await boot();

      final failure = await vm.importKey(alias: 'oops', privateKey: keys.publicKey);
      expect(failure, contains('public key'));
      expect(await repo.getAllKeys(), isEmpty, reason: 'nothing unusable reaches the store');
      vm.dispose();
    });

    test('a duplicate alias is refused', () async {
      final vm = await boot();
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await Future<void>.delayed(Duration.zero);

      expect(
        await vm.importKey(alias: 'laptop', privateKey: keys.privateKey),
        contains('already exists'),
      );
      vm.dispose();
    });
  });

  group('renaming a key', () {
    test('hosts referencing the alias follow it', () async {
      // The alias is what a host records; leaving it stale would break authentication silently.
      final vm = await boot();
      await vm.importKey(alias: 'old', privateKey: keys.privateKey);
      await Future<void>.delayed(Duration.zero);
      await repo.insertServer(server(name: 'a', keyAlias: 'old'));
      await repo.insertServer(server(name: 'b', proxyKeyAlias: 'old'));
      await Future<void>.delayed(Duration.zero);

      final key = (await repo.getAllKeys()).single;
      expect(await vm.renameKey(key, 'new'), isNull);
      await Future<void>.delayed(Duration.zero);

      final servers = await repo.getAllServers();
      expect(servers.firstWhere((s) => s.name == 'a').authKeyAlias, 'new');
      expect(servers.firstWhere((s) => s.name == 'b').proxyKeyAlias, 'new');
      vm.dispose();
    });

    test('a clashing or empty alias is refused', () async {
      final vm = await boot();
      await vm.importKey(alias: 'one', privateKey: keys.privateKey);
      // The same material under a second alias: only the alias must be unique.
      await vm.importKey(alias: 'two', privateKey: keys.privateKey);
      await Future<void>.delayed(Duration.zero);

      final key = (await repo.getAllKeys()).first;
      expect(await vm.renameKey(key, '  '), contains('required'));
      expect(await vm.renameKey(key, 'two'), contains('already exists'));
      vm.dispose();
    });
  });

  group('deleting', () {
    test('the hosts that would break are listed first', () async {
      // "Delete this key" gives no sense of blast radius, and the material cannot be recovered.
      final vm = await boot();
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await Future<void>.delayed(Duration.zero);
      await repo.insertServer(server(name: 'web', keyAlias: 'laptop'));
      await repo.insertServer(server(name: 'unrelated'));
      await Future<void>.delayed(Duration.zero);

      final key = (await repo.getAllKeys()).single;
      expect(vm.hostsUsingKey(key).map((s) => s.name), ['web']);

      await vm.deleteKey(key);
      await Future<void>.delayed(Duration.zero);
      expect(await repo.getAllKeys(), isEmpty);
      vm.dispose();
    });

    test('a profile reports its dependent hosts too', () async {
      final vm = await boot();
      await vm.saveProfile(profileName: 'shared', username: 'deploy', authType: 'password');
      await Future<void>.delayed(Duration.zero);
      final profile = (await repo.getAllProfiles()).single;
      await repo.insertServer(server(name: 'web', profileId: profile.id));
      await Future<void>.delayed(Duration.zero);

      expect(vm.hostsUsingProfile(profile).map((s) => s.name), ['web']);
      vm.dispose();
    });
  });

  group('credential profiles', () {
    test('a password profile is saved and encrypted', () async {
      final vm = await boot();
      expect(
        await vm.saveProfile(
          profileName: 'shared',
          username: 'deploy',
          authType: 'password',
          password: 'hunter2',
        ),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);

      expect((await repo.getAllProfiles()).single.password, 'hunter2');
      final raw = await db.appDataDao.getAllProfiles();
      expect(raw.single.password, startsWith(SecretStore.prefix));
      vm.dispose();
    });

    test('a key profile never also carries a password', () async {
      // A server that rejects the key could otherwise harvest it — the same rule the credential
      // resolver enforces at connect time.
      final vm = await boot();
      await vm.saveProfile(
        profileName: 'keyed',
        username: 'deploy',
        authType: 'key',
        keyAlias: 'laptop',
        password: 'should-be-dropped',
      );
      await Future<void>.delayed(Duration.zero);

      final profile = (await repo.getAllProfiles()).single;
      expect(profile.password, isNull);
      expect(profile.keyAlias, 'laptop');
      vm.dispose();
    });

    test('validation refuses incomplete profiles', () async {
      final vm = await boot();
      expect(
        await vm.saveProfile(profileName: '', username: 'u', authType: 'password'),
        contains('required'),
      );
      expect(
        await vm.saveProfile(profileName: 'p', username: ' ', authType: 'password'),
        contains('required'),
      );
      expect(
        await vm.saveProfile(profileName: 'p', username: 'u', authType: 'key'),
        contains('Pick a key'),
      );
      expect(await repo.getAllProfiles(), isEmpty);
      vm.dispose();
    });

    test('a duplicate name is refused, but editing one keeps its own', () async {
      final vm = await boot();
      await vm.saveProfile(profileName: 'shared', username: 'a', authType: 'password');
      await Future<void>.delayed(Duration.zero);

      expect(
        await vm.saveProfile(profileName: 'shared', username: 'b', authType: 'password'),
        contains('already exists'),
      );

      final existing = (await repo.getAllProfiles()).single;
      expect(
        await vm.saveProfile(
          existing: existing,
          profileName: 'shared',
          username: 'renamed',
          authType: 'password',
        ),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);
      expect((await repo.getAllProfiles()).single.username, 'renamed');
      vm.dispose();
    });

    test('an edit with a blank password keeps the stored one', () async {
      final vm = await boot();
      await vm.saveProfile(
        profileName: 'shared',
        username: 'a',
        authType: 'password',
        password: 'hunter2',
      );
      await Future<void>.delayed(Duration.zero);
      final existing = (await repo.getAllProfiles()).single;

      await vm.saveProfile(
        existing: existing,
        profileName: 'shared',
        username: 'a',
        authType: 'password',
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        (await repo.getAllProfiles()).single.password,
        'hunter2',
        reason: 'an empty field means unchanged, as on the host form',
      );
      vm.dispose();
    });
  });

  group('trusted host keys', () {
    test('pinned hosts are listed and can be revoked', () async {
      final store = InMemoryHostKeyStore();
      await store.write(
        '${SshHostKeyTrust.canonicalAlias('10.0.0.9', 2222)}|ssh-ed25519',
        'SHA256:abc',
      );
      final trust = SshHostKeyTrust(store);

      final vm = await boot(trust: trust);
      expect(vm.knownHosts, hasLength(1));
      expect(vm.knownHosts.single.fingerprint, 'SHA256:abc');

      await vm.revokeKnownHost(vm.knownHosts.single);
      expect(vm.knownHosts, isEmpty);
      expect(await store.readAll(), isEmpty, reason: 'the next connection must ask again');
      vm.dispose();
    });

    test('without a trust store the section says so', () async {
      final vm = await boot();
      expect(vm.canManageTrust, isFalse);
      expect(vm.knownHosts, isEmpty);
      vm.dispose();
    });
  });

  group('splitHostPort', () {
    test('splits a host and port', () {
      expect(AuthKeysViewModel.splitHostPort('10.0.0.1:2222'), ('10.0.0.1', 2222));
    });

    test('defaults to 22 when there is no port', () {
      expect(AuthKeysViewModel.splitHostPort('nas.local'), ('nas.local', 22));
    });

    test('the bracketed form is what the store actually writes', () {
      // Pins for a non-default port are stored as `[host]:port`; keeping the brackets would make
      // the revoke match nothing.
      expect(AuthKeysViewModel.splitHostPort('[10.0.0.1]:2222'), ('10.0.0.1', 2222));
      expect(AuthKeysViewModel.splitHostPort('[fe80::1]:2222'), ('fe80::1', 2222));
    });

    test('a bare IPv6 address is not split on one of its own colons', () {
      // Reading the last group as a port would revoke nothing at all.
      expect(AuthKeysViewModel.splitHostPort('fe80::1'), ('fe80::1', 22));
    });

    test('a non-numeric suffix is part of the host', () {
      expect(AuthKeysViewModel.splitHostPort('nas:notaport'), ('nas:notaport', 22));
    });
  });
}
