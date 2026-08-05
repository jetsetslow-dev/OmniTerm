import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/fleet/fleet_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/fleet_view_model.dart';
import 'package:omniterm/ui/view_model/scripts_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';
import 'package:provider/provider.dart';

import 'fleet_view_model_test.dart' show BroadcastTransport;
import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late FleetViewModel vm;
  late ScriptsViewModel scriptsVm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    HostDisplay.instance.hideSensitiveInfo = false;
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
  }) => Server(
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

  Future<void> pump(
    WidgetTester tester, {
    BroadcastTransport? transport,
    TelemetryPoller? poller,
  }) async {
    await app.start();
    vm = FleetViewModel(app, transport: transport, poller: poller);
    scriptsVm = ScriptsViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<FleetViewModel>.value(value: vm),
          // Broadcast offers saved fleet commands as presets, so the scripts store is in scope.
          ChangeNotifierProvider<ScriptsViewModel>.value(value: scriptsVm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: FleetScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goToBroadcast(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('fleet.tab.broadcast')));
    await tester.pumpAndSettle();
  }

  testWidgets('the summary shows the online count and average score', (tester) async {
    await repo.insertServer(server(name: 'a', host: '10.0.0.1', healthScore: 80));
    await repo.insertServer(server(name: 'b', host: '10.0.0.2', status: 'offline'));
    await pump(tester);

    expect(find.byKey(const ValueKey('fleet.summary')), findsOneWidget);
    expect(find.text('1 / 2 Online'), findsOneWidget);
    expect(find.text('Avg Score: 90'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('all three tabs render', (tester) async {
    await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
    await pump(tester, transport: BroadcastTransport());

    for (final (tab, probe) in [
      (FleetTab.broadcast, 'fleet.command'),
      (FleetTab.logs, 'fleet.logs.hosts'),
      (FleetTab.dashboard, 'fleet.dashboard.list'),
    ]) {
      await tester.tap(find.byKey(ValueKey('fleet.tab.${tab.name}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(probe)), findsOneWidget, reason: '${tab.name} did not render');
    }
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('the dashboard puts the worst host first', (tester) async {
    // The reason to open a fleet dashboard is to find what needs attention; a name-sorted list
    // buries it.
    await repo.insertServer(server(name: 'healthy', host: '10.0.0.1', healthScore: 95));
    await repo.insertServer(server(name: 'sick', host: '10.0.0.2', healthScore: 20));
    await repo.insertServer(
      server(name: 'gone', host: '10.0.0.3', status: 'offline', healthScore: 10),
    );
    await pump(tester);

    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('sick'), lessThan(top('healthy')));
    expect(
      top('healthy'),
      lessThan(top('gone')),
      reason: 'an offline host has no live score to rank on, so it sorts last',
    );
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('an offline host shows a tag, not a stale score', (tester) async {
    await repo.insertServer(
      server(name: 'down', host: '10.0.0.1', status: 'offline', healthScore: 88),
    );
    await pump(tester);

    expect(find.text('OFFLINE'), findsOneWidget);
    expect(
      find.text('88'),
      findsNothing,
      reason: 'a score for an unreachable host is a stale number pretending to be current',
    );
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  group('broadcast', () {
    testWidgets('running is blocked until a command and a target exist', (tester) async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);

      var button = tester.widget<FilledButton>(find.byKey(const ValueKey('fleet.run')));
      expect(button.onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.pumpAndSettle();
      button = tester.widget<FilledButton>(find.byKey(const ValueKey('fleet.run')));
      expect(button.onPressed, isNull, reason: 'still no targets');

      await tester.tap(find.byKey(ValueKey('fleet.target.$id')));
      await tester.pumpAndSettle();
      button = tester.widget<FilledButton>(find.byKey(const ValueKey('fleet.run')));
      expect(button.onPressed, isNotNull);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the dialog names every host that will be hit', (tester) async {
      // "5 hosts" is not something a user can check; a list is.
      await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'beta', host: '10.0.0.2'));
      final transport = BroadcastTransport();
      await pump(tester, transport: transport);
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();

      expect(find.text('Run on 2 hosts?'), findsOneWidget);
      expect(find.text('\$ uptime'), findsOneWidget);
      expect(find.textContaining('alpha'), findsWidgets);
      expect(find.textContaining('beta'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      expect(transport.commands, isEmpty, reason: 'cancelling must send nothing');
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a destructive command is flagged in the field and the dialog', (tester) async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'rm -rf /var/lib');
      await tester.tap(find.byKey(ValueKey('fleet.target.$id')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fleet.dangerWarning')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run.dialog.danger')), findsOneWidget);
      expect(find.textContaining('recursive/forced delete'), findsWidgets);

      // Flagged, not blocked — the user chose these hosts.
      expect(find.byKey(const ValueKey('run.confirm')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('confirming runs it and shows per-host output', (tester) async {
      await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'beta', host: '10.0.0.2'));
      final transport = BroadcastTransport(output: 'up 3 days');
      await pump(tester, transport: transport);
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run.confirm')));
      await tester.pumpAndSettle();

      expect(transport.commands, hasLength(2));
      expect(find.byKey(const ValueKey('fleet.results')), findsOneWidget);
      expect(find.text('OK'), findsNWidgets(2));
      expect(find.textContaining('up 3 days'), findsWidgets);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a failing host is marked failed with its real error', (tester) async {
      await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await repo.insertServer(server(name: 'beta', host: '10.0.0.2'));
      final transport = BroadcastTransport()..failFor = {'10.0.0.2'};
      await pump(tester, transport: transport);
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run.confirm')));
      await tester.pumpAndSettle();

      expect(find.text('OK'), findsOneWidget);
      expect(find.text('FAILED'), findsOneWidget);
      expect(find.textContaining('connection refused'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('group mode targets whole groups', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1', group: 'prod'));
      await repo.insertServer(server(name: 'b', host: '10.0.0.2', group: 'prod'));
      await repo.insertServer(server(name: 'c', host: '10.0.0.3', group: 'lab'));
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);

      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.targetGroup.prod')));
      await tester.pumpAndSettle();

      expect(find.text('2 targets'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('without a transport it says broadcasting is unavailable', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester);
      await goToBroadcast(tester);

      expect(find.textContaining('unavailable in this build'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('logs', () {
    testWidgets('picking hosts and fetching merges their lines', (tester) async {
      final aId = await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await pump(
        tester,
        transport: BroadcastTransport(
          replies: {'journalctl': '2026-08-04T10:00:00+0000 host kernel: disk errors detected\n'},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fleet.tab.logs')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fleet.logs.empty')), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('fleet.logs.host.$aId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.logs.reload')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fleet.logs.list')), findsOneWidget);
      expect(find.textContaining('disk errors detected'), findsOneWidget);
      // The host name leads: in a merged view, which machine a line came from comes first.
      expect(find.text('alpha'), findsWidgets);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the level filter narrows the rendered lines', (tester) async {
      final aId = await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await pump(
        tester,
        transport: BroadcastTransport(
          replies: {
            'journalctl':
                '2026-08-04T10:00:00+0000 host sshd: accepted connection\n'
                '2026-08-04T10:00:01+0000 host kernel: disk errors detected\n',
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fleet.tab.logs')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('fleet.logs.host.$aId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.logs.reload')));
      await tester.pumpAndSettle();

      expect(find.textContaining('accepted connection'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.logs.filter.ERROR')));
      await tester.pumpAndSettle();

      expect(find.textContaining('accepted connection'), findsNothing);
      expect(find.textContaining('disk errors detected'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  testWidgets('hide-sensitive-info masks addresses on the dashboard', (tester) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.9'));
    await pump(tester);
    expect(find.text('root@10.0.0.9'), findsOneWidget);

    HostDisplay.instance.hideSensitiveInfo = true;
    await tester.pumpAndSettle();
    expect(find.text('root@10.0.0.9'), findsNothing);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  group('the dashboard reads the fleet poller', () {
    /// 40% memory, in the shape `free -b` prints.
    const reply = '@OS\nLinux\n@MEM\nMem: 100 40 0 0 0 60\n@DISK\n/dev/sda1 100 1 1 1% /\n';

    testWidgets('every online host gets its own CPU chart', (tester) async {
      // The dashboard's job is comparing hosts, and a column of bare numbers cannot show which
      // machine is climbing.
      final upId = await repo.insertServer(server(name: 'up', host: '10.0.0.1'));
      final downId = await repo.insertServer(
        server(name: 'down', host: '10.0.0.2', status: 'offline'),
      );
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: reply));
      await pump(tester, poller: poller);
      await poller.cycle();
      await poller.cycle();
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('fleet.host.$upId.chart')), findsOneWidget);
      expect(find.text('CPU · 2 samples'), findsOneWidget);
      expect(
        find.byKey(ValueKey('fleet.host.$downId.chart')),
        findsNothing,
        reason: 'an offline host has no current series, and a line ending mid-air reads as one',
      );
      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a host score explains itself when tapped', (tester) async {
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1', healthScore: 95));
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: reply));
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('fleet.host.$id.score.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('health.dialog')), findsOneWidget);
      expect(find.textContaining('Health score · a'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('health.close')));
      await tester.pumpAndSettle();

      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a host nothing has sampled yet does not open an invented breakdown', (tester) async {
      // A breakdown assembled from empty metrics reads as a host at 0% on everything, which is a
      // description of a machine that does not exist.
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: reply));
      await pump(tester, poller: poller);

      await tester.tap(find.byKey(ValueKey('fleet.host.$id.score.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('health.dialog')), findsNothing);
      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the summary counts down to the next sweep', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final at = DateTime.now();
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: reply),
        interval: const Duration(seconds: 15),
        clock: () => at,
      );
      await pump(tester, poller: poller);
      expect(
        find.byKey(const ValueKey('fleet.summary.countdown')),
        findsNothing,
        reason: 'nothing has swept yet, so there is no cadence to describe',
      );

      await poller.cycle();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fleet.summary.countdown')), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('with no poller the dashboard says nothing about a cadence', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester);

      expect(find.byKey(const ValueKey('fleet.summary.countdown')), findsNothing);
      expect(find.text('CPU · 0 samples'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
