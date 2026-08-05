import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/health_scoring.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

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

  Server server({required String name, String status = 'online', int latency = 0}) => Server(
    id: 0,
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
    lastLatency: latency,
    status: status,
    authStatus: 'ok',
  );

  /// A metrics reply shaped like the real one: the `@` sections `parseMetrics` splits on, with
  /// `free -b` and `df -PB1 /` in the shapes those tools actually print, because the health score
  /// is computed from what the parser makes of them.
  String metricsReply({required int memUsedPct, int diskUsedPct = 1}) =>
      '@OS\nLinux\n'
      '@MEM\nMem: 100 $memUsedPct 0 0 0 ${100 - memUsedPct}\n'
      '@DISK\n/dev/sda1 100 $diskUsedPct 1 $diskUsedPct% /\n'
      '@STAT\ncpu 0 0 100 900 0\n'
      '@NETDEV\neth0: 1000 0 0 0 0 0 0 0 500\n';

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('what the poller visits', () {
    test('nothing at all without a transport', () async {
      await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final poller = TelemetryPoller(app);
      expect(poller.canPoll, isFalse);
      await poller.cycle();

      expect(
        poller.lastCycleStart,
        isNull,
        reason: 'a cycle that cannot run must not look like one',
      );
      poller.dispose();
    });

    test('only hosts believed to be online', () async {
      // The down host is [HostStatusProbe]'s business. Asking it for metrics can only time out,
      // once per host per cycle, forever.
      await repo.insertServer(server(name: 'up'));
      await repo.insertServer(server(name: 'down', status: 'offline'));
      await app.start();
      await settle();

      final transport = RecordingTransport(fallback: metricsReply(memUsedPct: 1));
      final poller = TelemetryPoller(app, transport: transport);
      await poller.cycle();

      // One OS probe and one metrics command, for the one online host.
      expect(transport.commands, hasLength(2));
      poller.dispose();
    });

    test('the OS is probed once and then reused', () async {
      await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final transport = RecordingTransport(fallback: metricsReply(memUsedPct: 1));
      final poller = TelemetryPoller(app, transport: transport);
      await poller.cycle();
      await poller.cycle();

      expect(transport.commands.where((c) => c.startsWith('uname -s')), hasLength(1));
      poller.dispose();
    });

    test('a host that fails does not stop the rest of the fleet', () async {
      await repo.insertServer(server(name: 'a'));
      await repo.insertServer(server(name: 'b'));
      await app.start();
      await settle();

      final transport = RecordingTransport(fallback: metricsReply(memUsedPct: 1))
        ..failure = Exception('connection refused');
      final poller = TelemetryPoller(app, transport: transport);
      await poller.cycle();

      expect(poller.metricsForServer(app.servers.first.id), isNull);
      expect(poller.isCycling, isFalse, reason: 'the cycle still finished');
      poller.dispose();
    });

    test('a failed probe leaves the host status alone', () async {
      // Status belongs to the reachability probe, which actually measured it. A metrics command
      // failing says nothing certain about whether the host is up.
      final id = await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final transport = RecordingTransport()..failure = Exception('auth failed');
      final poller = TelemetryPoller(app, transport: transport);
      await poller.cycle();

      final row = (await repo.getAllServers()).firstWhere((s) => s.id == id);
      expect(row.status, 'online');
      poller.dispose();
    });
  });

  group('what a cycle produces', () {
    test('a sample the screens can read, and a history row for the charts', () async {
      final id = await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 50)),
      );
      await poller.cycle();

      expect(poller.metricsForServer(id)!.memPercent, closeTo(50, 0.001));
      expect(poller.historyForServer(id), hasLength(1));

      final history = await repo.getMetricsForServer(id);
      expect(history, hasLength(1));
      expect(history.single.ramUsage, closeTo(50, 0.001));
      poller.dispose();
    });

    test(
      'a health score computed from the readings, replacing the 100 every host starts at',
      () async {
        // Nothing else in the app writes this column, so before the poller existed every host looked
        // perfectly healthy no matter what it was doing.
        final id = await repo.insertServer(server(name: 'a', latency: 0));
        await app.start();
        await settle();

        final poller = TelemetryPoller(
          app,
          // 95% of memory used: the default tiers put that in the highest band.
          transport: RecordingTransport(fallback: metricsReply(memUsedPct: 95)),
        );
        await poller.cycle();

        final row = (await repo.getAllServers()).firstWhere((s) => s.id == id);
        expect(row.healthScore, lessThan(100));
        expect(
          row.healthScore,
          HealthScoringConfig.defaults.score(0, 95, 1, 0),
          reason: 'the score is the configured one, not a second implementation',
        );
        poller.dispose();
      },
    );

    test("the user's own thresholds are used, not the defaults", () async {
      final id = await repo.insertServer(server(name: 'a'));
      // A config that punishes memory far harder than the default.
      const strict = HealthScoringConfig(mem: MetricTiers(10, 20, 30, 40, 50, 60));
      await repo.insertSetting(HealthScoringConfig.settingKey, strict.encode());
      await app.start();
      await settle();

      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 50)),
      );
      await poller.cycle();

      final row = (await repo.getAllServers()).firstWhere((s) => s.id == id);
      expect(row.healthScore, strict.score(0, 50, 1, 0));
      poller.dispose();
    });

    test('the in-memory history is bounded', () async {
      final id = await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 1)),
      );
      for (var i = 0; i < TelemetryPoller.historyLength + 5; i++) {
        await poller.cycle();
      }

      expect(poller.historyForServer(id), hasLength(TelemetryPoller.historyLength));
      poller.dispose();
    });
  });

  group('hosts that come and go', () {
    test('a deleted host takes its samples with it', () async {
      // Otherwise a new host reusing the freed row id inherits the old one's counters, and its
      // first sample is measured against a machine it has never met.
      final id = await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 1)),
      );
      await poller.cycle();
      expect(poller.metricsForServer(id), isNotNull);

      await repo.deleteServerAndDependents(id);
      await settle();
      await poller.cycle();

      expect(poller.metricsForServer(id), isNull);
      expect(poller.historyForServer(id), isEmpty);
      poller.dispose();
    });
  });

  group('the cadence', () {
    test('the countdown is anchored to the cycle that actually ran', () async {
      await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final at = DateTime(2026, 8, 5, 12);
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 1)),
        interval: const Duration(seconds: 15),
        clock: () => at,
      );
      await poller.cycle();

      expect(poller.lastCycleStart, at);
      expect(poller.nextCycleAt, at.add(const Duration(seconds: 15)));
      poller.dispose();
    });

    test('a cycle still running skips the next tick rather than doubling up', () async {
      // Two cycles in flight would probe the same host twice at once, and each would measure its
      // rates against the other's baseline.
      await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      final transport = RecordingTransport(fallback: metricsReply(memUsedPct: 1));
      final poller = TelemetryPoller(app, transport: transport);

      final first = poller.cycle();
      final second = poller.cycle();
      await Future.wait([first, second]);

      // One OS probe and one metrics command: the second cycle found the first still running and
      // skipped its tick entirely.
      expect(transport.commands, hasLength(2));
      expect(poller.historyForServer(app.servers.first.id), hasLength(1));
      poller.dispose();
    });
  });

  group('what a sample is handed to', () {
    test('every sample is offered to the caller that decides what it means', () async {
      // Alert rules, the evaluation and the notifier were all ported and tested, and nothing ever
      // called them: every configured rule sat inert. This callback is that call.
      final id = await repo.insertServer(server(name: 'a', latency: 12));
      await app.start();
      await settle();

      final seen = <(int, double)>[];
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsReply(memUsedPct: 40)),
        onSample: (server, metrics) async => seen.add((server.id, metrics.memPercent)),
      );
      await poller.cycle();

      expect(seen, hasLength(1));
      expect(seen.single.$1, id);
      expect(seen.single.$2, closeTo(40, 0.001));
      poller.dispose();
    });

    test('a host that could not be reached produces no sample to judge', () async {
      // An alert raised from a reading nobody took would be a claim about a machine the app never
      // spoke to.
      await repo.insertServer(server(name: 'a'));
      await app.start();
      await settle();

      var called = 0;
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport()..failure = Exception('connection refused'),
        onSample: (_, _) async => called++,
      );
      await poller.cycle();

      expect(called, 0);
      poller.dispose();
    });

  });
}
