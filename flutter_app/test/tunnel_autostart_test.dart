import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_tunnel_manager.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/tunnel_autostart.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
  });

  tearDown(() => db.close());

  Server server({int id = 0, String name = 'nas'}) => Server(
    id: id,
    name: name,
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: 'pw',
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
    agentForwarding: false,
    healthScore: 100,
    lastLatency: 0,
    status: 'online',
    authStatus: 'ok',
  );

  Future<int> addTunnel({required bool autoStart, int serverId = 1, String name = 'web'}) =>
      repo.insertPortForward(
        PortForwardsCompanion.insert(
          serverId: serverId,
          name: name,
          bindPort: 8080,
          destHost: const Value('10.0.0.5'),
          destPort: const Value(80),
          autoStart: Value(autoStart),
        ),
      );

  /// Records what was asked of it and always fails to connect, which is the interesting case: a
  /// tunnel that cannot start at launch must not take anything else down with it.
  ({List<int> dialled, SshTunnelManager manager}) failingManager() {
    final dialled = <int>[];
    return (
      dialled: dialled,
      manager: SshTunnelManager((creds) async {
        dialled.add(creds.port);
        throw Exception('host asleep');
      }),
    );
  }

  /// A trust store with nothing pinned, and one that trusts everything.
  SshHostKeyTrust trustStore({required bool pinned}) {
    final store = InMemoryHostKeyStore();
    if (pinned) {
      // The alias form the trust store itself computes, so this is a real pin rather than a
      // hand-written key that only looks like one.
      store.write('${SshHostKeyTrust.canonicalAlias('10.0.0.1', 22)}|ssh-ed25519', 'SHA256:abc');
    }
    return SshHostKeyTrust(store);
  }

  test('a host whose key was never approved is skipped, not dialled', () async {
    // Observed on a device: dialling one throws the "Trust this server?" prompt over whatever the
    // user opened the app to do, then fails closed two minutes later. A trust decision asked out
    // of context at launch is the one most likely to be tapped through.
    await repo.insertServer(server());
    await addTunnel(autoStart: true);
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager, trust: trustStore(pinned: false)).start();

    expect(harness.dialled, isEmpty);
  });

  test('a host that has been approved is dialled', () async {
    await repo.insertServer(server());
    await addTunnel(autoStart: true);
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager, trust: trustStore(pinned: true)).start();

    expect(harness.dialled, hasLength(1));
  });

  test('hosts come from the repository, not from an app state that has not loaded yet', () async {
    // The hazard this pins: the starter runs eagerly at launch, before `AppState.start()` has
    // finished loading hosts. Reading the in-memory list there could hand back an empty one and
    // skip every tunnel with nothing reporting why. Note there is no AppState anywhere in this
    // file — the repository is the only source of hosts, and it has no such ordering to get wrong.
    await repo.insertServer(server());
    await addTunnel(autoStart: true);
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager).start();

    expect(harness.dialled, hasLength(1));
  });

  test('only the tunnels marked auto-start are dialled', () async {
    await repo.insertServer(server());
    await addTunnel(autoStart: true, name: 'auto');
    await addTunnel(autoStart: false, name: 'manual');
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager).start();

    expect(harness.dialled, hasLength(1), reason: 'the manual tunnel must be left alone');
  });

  test('it runs once, not once per call', () async {
    // The saved list is a stream that fires on every edit. Starting from it would re-dial a tunnel
    // each time an unrelated one was renamed.
    await repo.insertServer(server());
    await addTunnel(autoStart: true);
    final harness = failingManager();
    final starter = TunnelAutoStarter(repo, harness.manager);

    await starter.start();
    await starter.start();
    await starter.start();

    expect(harness.dialled, hasLength(1));
  });

  test('a tunnel whose host is gone is skipped rather than dialled at nothing', () async {
    await addTunnel(autoStart: true, serverId: 99);
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager).start();

    expect(harness.dialled, isEmpty);
  });

  test('one tunnel failing to start does not stop the next', () async {
    // Launch is exactly when a host is most likely to be unreachable, and a fleet where the first
    // machine is asleep must still bring up the rest.
    await repo.insertServer(server());
    await addTunnel(autoStart: true, name: 'first');
    await addTunnel(autoStart: true, name: 'second');
    final harness = failingManager();

    await TunnelAutoStarter(repo, harness.manager).start();

    expect(harness.dialled, hasLength(2));
  });

  test('without a forwarder it does nothing rather than throwing', () async {
    await repo.insertServer(server());
    await addTunnel(autoStart: true);

    await expectLater(TunnelAutoStarter(repo, null).start(), completes);
  });
}
