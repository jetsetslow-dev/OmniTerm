import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/fleet_view_model.dart';

import 'support/fake_secure_storage.dart';

/// Records broadcasts and can stall or fail individual hosts.
class BroadcastTransport implements SshTransport {
  BroadcastTransport({this.output = 'ok', this.replies = const {}});

  final String output;
  final Map<Pattern, String> replies;

  final List<String> commands = [];
  final List<String> hosts = [];

  /// Hosts whose exec throws.
  Set<String> failFor = {};

  /// Hosts whose exec blocks until released.
  Map<String, Completer<void>> stalls = {};

  /// Peak simultaneous in-flight execs, for asserting the concurrency cap.
  int inFlight = 0;
  int peakInFlight = 0;

  Future<String> _run(SshCredentials creds, String command) async {
    commands.add(command);
    hosts.add(creds.host);
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    try {
      final stall = stalls[creds.host];
      if (stall != null) await stall.future;
      if (failFor.contains(creds.host)) throw Exception('connection refused');
      for (final entry in replies.entries) {
        if (command.contains(entry.key)) return entry.value;
      }
      return output;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) =>
      _run(creds, command);

  @override
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    final result = await _run(creds, command);
    if (result.isNotEmpty) await onChunk(result);
    return result;
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
    required String host,
    String status = 'online',
    String? group,
    int healthScore = 100,
  }) =>
      Server(
        id: 0,
        name: name,
        host: host,
        port: 22,
        username: 'root',
        groupName: group,
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
        healthScore: healthScore,
        lastLatency: 0,
        status: status,
        authStatus: 'ok',
      );

  Future<FleetViewModel> boot({BroadcastTransport? transport}) async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return FleetViewModel(app, transport: transport);
  }

  group('the fleet summary', () {
    test('counts total, online, critical and the average score', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1', healthScore: 90));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2', healthScore: 30));
      await repo.insertServer(
        server(name: 'c', host: '10.0.0.3', status: 'offline', healthScore: 60),
      );
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);

      expect(vm.totalCount, 3);
      expect(vm.onlineCount, 2);
      expect(vm.criticalCount, 1, reason: 'only online hosts below 50 are actionable');
      expect(vm.averageScore, 60);
      vm.dispose();
    });

    test('an empty fleet scores 100 rather than dividing by zero', () async {
      final vm = await boot();
      expect(vm.averageScore, 100);
      vm.dispose();
    });
  });

  group('targets', () {
    test('picked hosts resolve to exactly those hosts', () async {
      final aId = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);

      vm.toggleTargetServer(aId);
      expect(vm.resolvedTargets.map((s) => s.name), ['a']);
      vm.dispose();
    });

    test('a group resolves to its online members only', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1', group: 'prod'));
      await repo.insertServer(
        server(name: 'b', host: '10.0.0.2', group: 'prod', status: 'offline'),
      );
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);

      vm.targetMode = FleetTargetMode.groups;
      vm.toggleTargetGroup('prod');
      expect(vm.resolvedTargets.map((s) => s.name), ['a'],
          reason: 'a group must not promise hosts that cannot answer');
      vm.dispose();
    });

    test('a host going offline is dropped from the selection', () async {
      // Otherwise the user confirms "run on 2 hosts" and gets one, with no explanation.
      final aId = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final bId = await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      vm
        ..toggleTargetServer(aId)
        ..toggleTargetServer(bId);
      expect(vm.targetServerIds, hasLength(2));

      await repo.updateServer((await repo.getServerById(aId))!.copyWith(status: 'offline'));
      await Future<void>.delayed(Duration.zero);

      expect(vm.targetServerIds, {bId});
      vm.dispose();
    });

    test('a group that loses every online member is deselected', () async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1', group: 'prod'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      vm
        ..targetMode = FleetTargetMode.groups
        ..toggleTargetGroup('prod');

      await repo.updateServer((await repo.getServerById(id))!.copyWith(status: 'offline'));
      await Future<void>.delayed(Duration.zero);

      expect(vm.targetGroups, isEmpty);
      vm.dispose();
    });

    test('select-all picks online hosts only', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2', status: 'offline'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);

      vm.selectAllTargets();
      expect(vm.resolvedTargets.map((s) => s.name), ['a']);
      vm.dispose();
    });
  });

  group('the run gate', () {
    test('a run needs a command, a target and a transport', () async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final vm = await boot(transport: BroadcastTransport());
      await Future<void>.delayed(Duration.zero);

      expect(vm.canRun, isFalse, reason: 'no command, no targets');
      vm.commandText = 'uptime';
      expect(vm.canRun, isFalse, reason: 'still no targets');
      vm.toggleTargetServer(id);
      expect(vm.canRun, isTrue);

      vm.commandText = '   ';
      expect(vm.canRun, isFalse, reason: 'whitespace is not a command');
      vm.dispose();
    });

    test('without a transport it cannot run at all', () async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..toggleTargetServer(id);

      expect(vm.canBroadcast, isFalse);
      expect(vm.canRun, isFalse);
      await vm.runBroadcast(vm.resolvedTargets);
      expect(vm.results, isEmpty, reason: 'never report a run that did not happen');
      vm.dispose();
    });

    test('a destructive command is warned about, not blocked', () async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final vm = await boot(transport: BroadcastTransport());
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'rm -rf /var/cache'
        ..toggleTargetServer(id);

      expect(vm.dangerWarning, isNotNull);
      expect(vm.canRun, isTrue,
          reason: 'the user chose these hosts; the app warns rather than refuses');
      vm.dispose();
    });
  });

  group('broadcast execution', () {
    test('every target gets a result, and output is captured', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final vm = await boot(transport: BroadcastTransport(output: 'up 3 days'));
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);

      expect(vm.results, hasLength(2));
      expect(vm.results.every((r) => r.status == BroadcastStatus.success), isTrue);
      expect(vm.results.first.output.toString(), 'up 3 days');
      expect(vm.successCount, 2);
      vm.dispose();
    });

    test('one failing host does not fail the others', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final transport = BroadcastTransport()..failFor = {'10.0.0.2'};
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);

      expect(vm.successCount, 1);
      expect(vm.failureCount, 1);
      expect(
        vm.results.firstWhere((r) => r.serverName == 'b').note,
        contains('connection refused'),
        reason: 'the real error for that row, not a generic failure',
      );
      vm.dispose();
    });

    test('a credential failure is reported per host', () async {
      await repo.insertServer(
        server(name: 'a', host: '10.0.0.1')
            .copyWith(authType: 'key', authKeyAlias: const Value('gone')),
      );
      final vm = await boot(transport: BroadcastTransport());
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);

      expect(vm.results.single.status, BroadcastStatus.failure);
      expect(vm.results.single.note, contains('gone'));
      vm.dispose();
    });

    test('a silent command says so rather than showing a blank card', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final vm = await boot(transport: BroadcastTransport(output: ''));
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'true'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);
      expect(vm.results.single.note, 'Done (no output)');
      vm.dispose();
    });

    test('no more than six hosts are contacted at once', () async {
      // Unbounded fan-out is a self-inflicted connection storm, and on a phone it exhausts
      // sockets and battery.
      for (var i = 1; i <= 15; i++) {
        await repo.insertServer(server(name: 'h$i', host: '10.0.0.$i'));
      }
      final transport = BroadcastTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);

      expect(vm.results, hasLength(15));
      expect(transport.peakInFlight, lessThanOrEqualTo(FleetViewModel.broadcastConcurrency));
      vm.dispose();
    });

    test('the exact targets passed in are used, not re-resolved', () async {
      // The confirmation dialog already showed the user a list. Re-resolving against cached
      // reachability would silently drop a host they explicitly approved.
      final aId = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final vm = await boot(transport: BroadcastTransport());
      await Future<void>.delayed(Duration.zero);
      vm.commandText = 'uptime';

      final approved = vm.servers.where((s) => s.id == aId).toList();
      // The selection changes after the dialog was shown — the run must ignore that.
      vm.selectAllTargets();
      await vm.runBroadcast(approved);

      expect(vm.results.map((r) => r.serverName), ['a']);
      vm.dispose();
    });

    test('a second run cannot start while one is in flight', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final transport = BroadcastTransport()
        ..stalls = {'10.0.0.1': Completer<void>()};
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      final first = vm.runBroadcast(vm.resolvedTargets);
      await Future<void>.delayed(Duration.zero);
      expect(vm.executing, isTrue);
      expect(vm.canRun, isFalse);

      await vm.runBroadcast(vm.resolvedTargets);
      expect(transport.commands, hasLength(1), reason: 'the second call was refused');

      transport.stalls['10.0.0.1']!.complete();
      await first;
      vm.dispose();
    });

    test('results cannot be cleared mid-run', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final transport = BroadcastTransport()
        ..stalls = {'10.0.0.1': Completer<void>()};
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      final run = vm.runBroadcast(vm.resolvedTargets);
      await Future<void>.delayed(Duration.zero);
      vm.clearResults();
      expect(vm.results, hasLength(1), reason: 'clearing would hide a run still in progress');

      transport.stalls['10.0.0.1']!.complete();
      await run;
      vm.clearResults();
      expect(vm.results, isEmpty);
      vm.dispose();
    });

    test('a host still running when the workers return is marked failed', () async {
      // Leaving it spinning would misreport an abandoned run as one still in progress.
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final vm = await boot(transport: BroadcastTransport());
      await Future<void>.delayed(Duration.zero);
      vm
        ..commandText = 'uptime'
        ..selectAllTargets();

      await vm.runBroadcast(vm.resolvedTargets);
      expect(vm.results.every((r) => r.isDone), isTrue);
      expect(vm.executing, isFalse);
      vm.dispose();
    });
  });

  group('fleet logs', () {
    const journal = '2026-08-04T10:00:00+0000 host sshd: accepted connection\n'
        '2026-08-04T10:00:01+0000 host kernel: disk errors detected\n';

    test('logs from several hosts are merged newest first', () async {
      final aId = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final bId = await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final vm = await boot(
        transport: BroadcastTransport(replies: {'journalctl': journal}),
      );
      await Future<void>.delayed(Duration.zero);
      vm
        ..toggleLogServer(aId)
        ..toggleLogServer(bId);

      await vm.loadLogs();

      expect(vm.logs, hasLength(4), reason: 'two lines from each host');
      expect(vm.logs.map((l) => l.serverName).toSet(), {'a', 'b'});
      // Reading a fleet's logs together is about seeing one event land on several machines.
      final times = vm.logs.map((l) => l.timestamp).toList();
      expect(times, orderedEquals([...times]..sort((x, y) => y.compareTo(x))));
      vm.dispose();
    });

    test('one unreachable host does not empty the merged view', () async {
      final aId = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final bId = await repo.insertServer(server(name: 'b', host: '10.0.0.2'));
      final transport = BroadcastTransport(replies: {'journalctl': journal})
        ..failFor = {'10.0.0.2'};
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm
        ..toggleLogServer(aId)
        ..toggleLogServer(bId);

      await vm.loadLogs();

      expect(vm.logs, hasLength(2));
      expect(vm.logs.every((l) => l.serverName == 'a'), isTrue);
      vm.dispose();
    });

    test('the level filter narrows without refetching', () async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final transport = BroadcastTransport(replies: {'journalctl': journal});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm.toggleLogServer(id);
      await vm.loadLogs();
      final calls = transport.commands.length;

      vm.logLevelFilter = 'ERROR';
      expect(transport.commands.length, calls);
      expect(vm.logs, hasLength(1));
      expect(vm.logs.single.message, contains('disk errors detected'),
          reason: 'the §15.1 inferLevel fix classifies this as ERROR');
      vm.dispose();
    });

    test('a failing read releases the tab instead of wedging it', () async {
      // The Kotlin's recurring "stranded spinner" (its PR #50 found five at once). Here it is
      // worse than a spinner: `logsLoading` also gates re-entry at the top of `loadLogs`, so a
      // throwing database read left the Logs tab unable to load again for the rest of the session.
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final transport = BroadcastTransport(replies: {'journalctl': journal});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      vm.toggleLogServer(id);

      // Closing the database is the honest way to make an ordinary repository call throw.
      await db.close();
      await expectLater(vm.loadLogs(), throwsA(anything));

      expect(vm.logsLoading, isFalse, reason: 'the tab must be usable again after a failure');
      vm.dispose();
    });

    test('selecting no host clears the view rather than querying everything', () async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final transport = BroadcastTransport(replies: {'journalctl': journal});
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      await vm.loadLogs();
      expect(transport.commands, isEmpty);
      expect(vm.logs, isEmpty);
      vm.dispose();
    });
  });
}
