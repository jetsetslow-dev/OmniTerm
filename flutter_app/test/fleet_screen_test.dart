import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
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

class _StreamingDiagnosticTransport extends BroadcastTransport {
  final finish = Completer<void>();

  @override
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    SshCancellationToken? cancellation,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    hosts.add(creds.host);
    commands.add(command);
    await onChunk('first diagnostic chunk\n');
    await finish.future;
    await onChunk('last diagnostic chunk\n');
    return 'first diagnostic chunk\nlast diagnostic chunk\n';
  }
}

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

  // All three buttons, not just the first. They are generated from one list, so this is coverage
  // rather than a suspected defect — but DF and PS had none at all, which means a wrong command,
  // a button wired to the wrong host, or a diagnostic that quietly disturbed Broadcast would have
  // been caught for Uptime and missed for the other two.
  for (final (label, command) in [
    ('uptime', 'uptime'),
    ('df', 'df -h'),
    ('ps', 'ps aux | head -5'),
  ]) {
    testWidgets('the $label diagnostic streams without changing broadcast state', (tester) async {
      await repo.insertServer(server(name: 'diagnostic host', host: '10.0.0.8'));
      final transport = _StreamingDiagnosticTransport();
      await pump(tester, transport: transport);
      vm.commandText = 'my unsent broadcast';
      final host = vm.servers.single;
      try {
        final button = find.byKey(ValueKey('fleet.host.${host.id}.$label'));
        expect(button, findsOneWidget, reason: 'the $label button must exist to be tested');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const ValueKey('command.stream.dialog')), findsOneWidget);
        expect(find.textContaining('first diagnostic chunk'), findsOneWidget);
        expect(
          find.textContaining('last diagnostic chunk'),
          findsNothing,
          reason: 'output must appear as it arrives, not only once the command finishes',
        );
        expect(
          find.byType(CircularProgressIndicator),
          findsWidgets,
          reason: 'a command still running must show it is still running',
        );
        expect(transport.hosts, ['10.0.0.8'], reason: 'the popup must dial the host it names');
        expect(transport.commands, [
          command,
        ], reason: 'each button must send its own command, not the first one');

        // The defect this half guards against: a read-only diagnostic that quietly consumed the
        // Broadcast tab's unsent command or target selection.
        expect(vm.activeTab, FleetTab.dashboard);
        expect(vm.commandText, 'my unsent broadcast');
        expect(vm.targetServerIds, isEmpty);

        transport.finish.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('last diagnostic chunk'), findsOneWidget);
      } finally {
        if (!transport.finish.isCompleted) transport.finish.complete();
        vm.dispose();
        scriptsVm.dispose();
      }
    });
  }

  testWidgets('the summary shows the online count and average score', (tester) async {
    await repo.insertServer(server(name: 'a', host: '10.0.0.1', healthScore: 80));
    await repo.insertServer(server(name: 'b', host: '10.0.0.2', status: 'offline'));
    await pump(tester);

    expect(find.byKey(const ValueKey('fleet.summary')), findsOneWidget);
    expect(find.text('1 / 2 Online'), findsOneWidget);
    expect(find.text('Avg Score: —'), findsOneWidget);
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

  Future<void> pickTargets(WidgetTester tester, List<String> names) async {
    await tester.tap(find.byKey(const ValueKey('fleet.targets.hosts')));
    await tester.pumpAndSettle();
    for (final name in names) {
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(name)));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  Future<void> runAndConfirm(WidgetTester tester, {bool settle = true}) async {
    await tester.tap(find.byKey(const ValueKey('fleet.run')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('run.confirm')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('the dashboard lists online hosts in saved order under Kotlin\'s stat cards', (
    tester,
  ) async {
    // Kotlin's dashboard is fed only the online hosts, in the order they are saved (by name).
    await repo.insertServer(server(name: 'healthy', host: '10.0.0.1', healthScore: 95));
    await repo.insertServer(server(name: 'sick', host: '10.0.0.2', healthScore: 20));
    await repo.insertServer(
      server(name: 'gone', host: '10.0.0.3', status: 'offline', healthScore: 10),
    );
    await pump(tester);

    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('healthy'), lessThan(top('sick')));
    expect(find.text('gone'), findsNothing, reason: 'offline hosts are not on the dashboard');
    expect(find.bySemanticsLabel('Hosts: 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Online: 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Critical: 0'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('an offline fleet says details return when hosts come back online', (tester) async {
    await repo.insertServer(
      server(name: 'down', host: '10.0.0.1', status: 'offline', healthScore: 88),
    );
    await pump(tester);

    expect(find.byKey(const ValueKey('fleet.dashboard.empty')), findsOneWidget);
    expect(find.text('down'), findsNothing);
    expect(find.text('88'), findsNothing, reason: 'no stale score for an unreachable host');
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  group('broadcast', () {
    testWidgets('a short landscape viewport keeps broadcast controls reachable at large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 240);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);
      expect(tester.takeException(), isNull);
      final command = find.byKey(const ValueKey('fleet.command'));
      await tester.ensureVisible(command);
      expect(command.hitTestable(), findsOneWidget);
      final run = find.byKey(const ValueKey('fleet.run'));
      await tester.ensureVisible(run);
      expect(run.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('Run only asks to confirm once a command and a target exist', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);

      expect(find.text('RUN ON 0 HOSTS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run.dialog')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run.dialog')), findsNothing, reason: 'still no targets');

      await pickTargets(tester, ['a']);
      expect(find.text('RUN ON 1 HOSTS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run.dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the dialog names every host that will be hit', (tester) async {
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
      expect(
        find.text('\$ uptime\n\n• alpha (root@10.0.0.1)\n• beta (root@10.0.0.2)'),
        findsOneWidget,
        reason: 'Kotlin\'s ConfirmHost message: the command, then every host by name',
      );

      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      expect(transport.commands, isEmpty, reason: 'cancelling must send nothing');
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a destructive command is flagged in the confirmation', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'rm -rf /var/lib');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.textContaining('⚠ This command looks destructive'), findsOneWidget);
      expect(find.textContaining('recursive/forced delete'), findsOneWidget);

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
      await runAndConfirm(tester);

      expect(transport.commands, hasLength(2));
      expect(find.byKey(const ValueKey('fleet.results')), findsOneWidget);
      expect(find.text('complete'), findsNWidgets(2));
      expect(find.textContaining('up 3 days'), findsWidgets);
      expect(
        find.text('RUN 2'),
        findsOneWidget,
        reason: 'Kotlin collapses the controls to a compact Run once outputs arrive',
      );
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a running broadcast exposes a stop action', (tester) async {
      await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      final stall = Completer<void>();
      final transport = BroadcastTransport()..stalls = {'10.0.0.1': stall};
      await pump(tester, transport: transport);
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'sleep 600');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pump();
      await runAndConfirm(tester, settle: false);
      await tester.pump();

      expect(find.text('streaming'), findsOneWidget);
      expect(find.textContaining('STOP'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
      expect(find.textContaining('Cancelled.'), findsOneWidget);

      stall.complete();
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
      await runAndConfirm(tester);

      expect(find.text('complete'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
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

      await tester.tap(find.byKey(const ValueKey('fleet.targetMode.groups')));
      await tester.pumpAndSettle();
      expect(find.text('prod (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.targetGroup.prod')));
      await tester.pumpAndSettle();

      expect(find.text('2 target(s) · no command'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      expect(find.text('3 target(s) · no command'), findsOneWidget, reason: 'All Groups');
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('without a transport Run explains that broadcasting is unavailable', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await pump(tester);
      await goToBroadcast(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.command')), 'uptime');
      await tester.tap(find.byKey(const ValueKey('fleet.targets.all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.run')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unavailable in this build'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('logs', () {
    testWidgets('picking hosts and fetching merges their lines', (tester) async {
      await repo.insertServer(server(name: 'alpha', host: '10.0.0.1'));
      await pump(
        tester,
        transport: BroadcastTransport(
          replies: {'journalctl': '2026-08-04T10:00:00+0000 host kernel: disk errors detected\n'},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fleet.tab.logs')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fleet.logs.empty')), findsOneWidget);
      expect(find.text('No logs. Select hosts and tap Fetch Logs.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fleet.logs.hosts')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('alpha')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fleet.logs.reload')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fleet.logs.list')), findsOneWidget);
      expect(find.textContaining('disk errors detected'), findsOneWidget);
      expect(find.text('1 entries'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  testWidgets('hide-sensitive-info masks addresses on the dashboard', (tester) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.9'));
    await pump(tester);
    expect(find.text('root@10.0.0.9:22'), findsOneWidget);

    HostDisplay.instance.hideSensitiveInfo = true;
    await tester.pumpAndSettle();
    expect(find.textContaining('10.0.0.9'), findsNothing);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  group('the dashboard reads the fleet poller', () {
    /// 40% memory, in the shape `free -b` prints.
    const reply =
        '@OS\nLinux\n@CPU\n%Cpu(s): 100.0 id\n@MEM\nMem: 100 40 0 0 0 60\n@DISK\n/dev/sda1 100 1 1 1% /\n';

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

      final scoreSemantics = tester.getSemantics(find.byKey(ValueKey('fleet.host.$id.score.open')));
      expect(scoreSemantics.label, matches(RegExp(r'Health score: \d+ out of 100')));
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

    testWidgets('a host nothing has sampled yet explains that health is unavailable', (
      tester,
    ) async {
      // A breakdown assembled from empty metrics reads as a host at 0% on everything, which is a
      // description of a machine that does not exist.
      final id = await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: reply));
      await pump(tester, poller: poller);

      await tester.tap(find.byKey(ValueKey('fleet.host.$id.score.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('health.unavailable')), findsOneWidget);
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
      expect(
        tester.getSemantics(find.byKey(const ValueKey('fleet.summary.countdown'))).label,
        'Refreshing in 15 seconds',
      );
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

  group('the broadcast preset picker', () {
    Future<void> seedPresets(int count) async {
      for (var i = 0; i < count; i++) {
        await repo.insertScript(
          QuickScriptsCompanion.insert(
            emoji: '*',
            name: 'preset$i',
            command: i == 0 ? 'journalctl -xe' : 'echo $i',
            color: 'cyan',
            availableForQuick: const Value(false),
            availableForFleet: const Value(true),
          ),
        );
      }
    }

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('fleet.presets.open')));
      await tester.pumpAndSettle();
    }

    testWidgets('Presets opens Kotlin\'s searchable chooser', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await seedPresets(3);
      await pump(tester);
      await goToBroadcast(tester);
      await openPicker(tester);

      expect(find.text('Choose fleet script'), findsOneWidget);
      expect(find.byKey(const ValueKey('fleet.presets.search')), findsOneWidget);
      expect(find.text('* preset0'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the search matches name or command', (tester) async {
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await seedPresets(9);
      await pump(tester);
      await goToBroadcast(tester);
      await openPicker(tester);

      await tester.enterText(find.byKey(const ValueKey('fleet.presets.search')), 'journalctl');
      await tester.pumpAndSettle();
      expect(find.text('* preset0'), findsOneWidget);
      expect(find.text('* preset1'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('fleet.presets.search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No presets match your search.'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('picking a preset fills the field rather than running it', (tester) async {
      // The confirmation dialog is where a broadcast gets approved; a preset must not skip it.
      await repo.insertServer(server(name: 'a', host: '10.0.0.1'));
      await seedPresets(2);
      await pump(tester, transport: BroadcastTransport());
      await goToBroadcast(tester);
      await openPicker(tester);

      final id = (await repo.getAllScripts()).first.id;
      await tester.tap(find.byKey(ValueKey('fleet.preset.$id')));
      await tester.pumpAndSettle();

      expect(vm.commandText, 'journalctl -xe');
      expect(find.byKey(const ValueKey('run.dialog')), findsNothing);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
