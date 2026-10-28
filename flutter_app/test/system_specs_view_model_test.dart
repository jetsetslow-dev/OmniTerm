import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/system_specs.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/system_specs_view_model.dart';

import 'fixtures/system_specs_fixtures.dart';
import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

/// System specs are read once per host, kept for the session, and never use sudo unless asked.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late RecordingTransport transport;
  late SystemSpecsViewModel vm;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    await app.start();
    // The specs command also runs `uname -srm`, so it is matched first, by a word only it uses.
    transport = RecordingTransport(replies: {'lscpu': linuxCommon, 'uname': 'Linux\n'});
    vm = SystemSpecsViewModel(app, transport: transport);
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await db.close();
  });

  Future<Server> addServer(String name, {String host = '10.0.0.1', String sudo = ''}) async {
    final id = await repo.insertServer(
      Server(
        id: 0,
        name: name,
        host: host,
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: 'password',
        authPassword: 'pw',
        sudoPassword: sudo,
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
      ),
    );
    await pumpEventQueue();
    return app.servers.firstWhere((s) => s.id == id);
  }

  Iterable<String> specsCommands() => transport.commands.where((c) => c.contains('lscpu'));

  test('specs are read once per host and kept for the session', () async {
    final nas = await addServer('nas');
    await vm.load(nas);
    vm.loadIfNeeded(nas);
    await pumpEventQueue();

    expect(specsCommands(), hasLength(1));
    expect(vm.stateFor(nas.id)!.specs!.section(SpecKind.cpu), isNotNull);
    expect(transport.commands.first, osProbeCommand, reason: 'the command is picked per OS');
  });

  test(
    'sudo is used only when asked, with the password on stdin, and a refresh keeps it',
    () async {
      final nas = await addServer('nas', sudo: 'pw-123');
      await vm.load(nas);
      expect(transport.stdins.last, isNull);
      expect(specsCommands().last, isNot(contains('sudo')));

      await vm.load(nas, withSudo: true);
      expect(specsCommands().last, contains("sudo -S -p ''"));
      expect(specsCommands().last, isNot(contains('pw-123')));
      expect(transport.stdins.last, 'pw-123\n');

      await vm.load(nas);
      expect(transport.stdins.last, 'pw-123\n', reason: 'the detail must not vanish on refresh');
    },
  );

  test('a failed read keeps the last specs and says what went wrong', () async {
    final nas = await addServer('nas');
    await vm.load(nas);
    transport.replies = {'lscpu': 'SSH Error: Connection refused', 'uname': 'Linux\n'};
    await vm.load(nas);

    final state = vm.stateFor(nas.id)!;
    expect(state.error, 'Connection refused');
    expect(state.specs, isNotNull);
    expect(state.loading, isFalse);
  });

  test('a deleted or moved host forgets its specs and its OS', () async {
    final nas = await addServer('nas');
    final pi = await addServer('pi', host: '10.0.0.2');
    await vm.load(nas);
    await vm.load(pi);
    vm.toggleExpanded(pi.id, 'cpu');

    await repo.updateServer(pi.copyWith(host: '10.0.0.9'));
    await pumpEventQueue();
    expect(vm.stateFor(pi.id), isNull);
    expect(vm.isExpanded(pi.id, 'cpu'), isFalse);
    expect(app.osForServer(pi.id), '', reason: 'the new address may be another machine');

    await repo.updateServer(nas.copyWith(name: 'nas-renamed'));
    await pumpEventQueue();
    expect(vm.stateFor(nas.id), isNotNull, reason: 'a rename is the same machine');

    await repo.deleteServerAndDependents(nas.id);
    await pumpEventQueue();
    expect(vm.stateFor(nas.id), isNull);
  });

  test('each host keeps its own expanded sections', () async {
    final nas = await addServer('nas');
    final pi = await addServer('pi', host: '10.0.0.2');
    vm.toggleExpanded(nas.id, 'cpu');
    vm.toggleExpanded(pi.id, 'memory');

    expect(vm.isExpanded(nas.id, 'cpu'), isTrue);
    expect(vm.isExpanded(nas.id, 'memory'), isFalse);
    expect(vm.isExpanded(pi.id, 'memory'), isTrue);
    expect(vm.isExpanded(pi.id, 'cpu'), isFalse);
  });
}
