import 'package:drift/drift.dart' show Value;
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/domain/health_scoring.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/monitor/monitor_screen.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/theme/typography.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';
import 'package:omniterm/ui/view_model/scripts_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';
import 'package:provider/provider.dart';

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
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({
    required String name,
    String status = 'online',
    int healthScore = 100,
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
    healthScore: healthScore,
    lastLatency: 0,
    status: status,
    authStatus: 'ok',
  );

  late MonitorViewModel vm;
  late ScriptsViewModel scriptsVm;
  late AppLockController lock;

  Future<void> pump(
    WidgetTester tester, {
    RecordingTransport? transport,
    TelemetryPoller? poller,
  }) async {
    await app.start();
    vm = MonitorViewModel(app, transport: transport, poller: poller);
    scriptsVm = ScriptsViewModel(app);
    // Reboot and service actions re-authenticate before using a stored sudo password, so the lock
    // is in scope here as it is in the real app. Left unconfigured — no PIN, no biometrics — so the
    // gate is inert and these tests still exercise the actions themselves.
    lock = AppLockController(repo);
    await lock.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<MonitorViewModel>.value(value: vm),
          // The Scripts tab offers the saved quick scripts, so the store is in scope.
          ChangeNotifierProvider<ScriptsViewModel>.value(value: scriptsVm),
          ChangeNotifierProvider<AppLockController>.value(value: lock),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: MonitorScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing online it says so instead of showing a blank screen', (tester) async {
    await repo.insertServer(server(name: 'a', status: 'offline'));
    await pump(tester);

    expect(find.byKey(const ValueKey('monitor.noHosts')), findsOneWidget);
    expect(find.text('No online hosts available to monitor'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('an online host shows the selector, health score and tabs', (tester) async {
    await repo.insertServer(server(name: 'nas', healthScore: 82));
    await pump(tester, transport: RecordingTransport());

    expect(find.byKey(const ValueKey('monitor.hostPicker')), findsOneWidget);
    expect(find.text('82'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('monitor.healthScore.open'))).label,
      'Health score: 82 out of 100',
    );
    for (final tab in MonitorTab.values) {
      expect(find.byKey(ValueKey('monitor.tab.${tab.name}')), findsOneWidget);
    }
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('every tab is reachable and renders', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    // Each tab is given something to show: an empty tab now renders its own explanation rather
    // than an empty list, which is the right behaviour but not what this test is about.
    await pump(
      tester,
      transport: RecordingTransport(
        replies: {'journalctl': '2026-08-04T10:00:00+0000 host unit[1]: started nginx'},
      ),
    );

    for (final (tab, probe) in [
      // The sort chip rather than the list: this test is about the tab *rendering*, and the list
      // is legitimately absent when the fixture host returns no processes.
      (MonitorTab.processes, 'monitor.processes.sortCpu'),
      (MonitorTab.services, 'monitor.services.list'),
      (MonitorTab.logs, 'monitor.logs.list'),
      (MonitorTab.overview, 'monitor.overview'),
    ]) {
      await tester.tap(find.byKey(ValueKey('monitor.tab.${tab.name}')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey(probe)),
        findsOneWidget,
        reason: 'the ${tab.name} tab did not render',
      );
    }
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('every tab renders its own content, with none left as a placeholder', (tester) async {
    // Scripts and CRON were the last two notes saying "not available in this build yet"; both are
    // ported, so nothing in Monitor is a placeholder any more.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport());

    for (final tab in MonitorTab.values) {
      await tester.tap(find.byKey(ValueKey('monitor.tab.${tab.name}')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not available in this build yet'),
        findsNothing,
        reason: '${tab.name} still shows a placeholder',
      );
    }
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('the overview renders the host metrics it fetched', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(
      tester,
      transport: RecordingTransport(
        replies: {
          "echo '@OS'":
              '@OS\nLinux\n'
              '@CPU\n%Cpu(s):  4.0 us,  1.0 sy,  0.0 ni, 75.0 id\n'
              '@MEM\nMem: 8589934592 4294967296 0 0 0 4294967296\n'
              '@LOAD\n0.50 0.40 0.30 1/200 1234\n'
              '@UP\n86400.00 100000.00\n'
              '@PROC\n200\n',
        },
      ),
    );

    expect(find.byKey(const ValueKey('monitor.overview.cpu')), findsOneWidget);
    expect(find.byKey(const ValueKey('monitor.overview.memory')), findsOneWidget);
    expect(find.text('25%'), findsOneWidget, reason: '100 - 75 idle');
    expect(find.textContaining('Load: 0.5'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('processes list, and the sort chips switch order without refetching', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = RecordingTransport(
      replies: {
        'ps -eo':
            '  PID USER     %CPU %MEM    VSZ     ELAPSED STAT COMMAND\n'
            '  101 root      5.0 40.0 100000    01:00:00 S    lowcpu-highmem\n'
            '  102 root     90.0  1.0 100000    01:00:00 S    highcpu-lowmem\n',
      },
    );
    await pump(tester, transport: transport);

    await tester.tap(find.byKey(const ValueKey('monitor.tab.processes')));
    await tester.pumpAndSettle();

    expect(find.text('highcpu-lowmem'), findsOneWidget);
    expect(find.text('2 Procs'), findsOneWidget);

    final callsBefore = transport.commands.length;
    await tester.tap(find.byKey(const ValueKey('monitor.processes.sortMem')));
    await tester.pumpAndSettle();
    expect(transport.commands.length, callsBefore, reason: 'the list is re-sorted locally');
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('killing a process asks first and names what it will kill', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = RecordingTransport(
      replies: {
        'ps -eo':
            '  PID USER     %CPU %MEM    VSZ     ELAPSED STAT COMMAND\n'
            '  102 root     90.0  1.0 100000    01:00:00 S    runaway\n',
      },
    );
    await pump(tester, transport: transport);
    await tester.tap(find.byKey(const ValueKey('monitor.tab.processes')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('monitor.process.102')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.process.102.kill')));
    await tester.pumpAndSettle();

    expect(find.text('Kill runaway?'), findsOneWidget);
    expect(find.text('Sends SIGTERM to pid 102 (root).'), findsOneWidget);

    // Cancelling must not send anything: the list re-sorts live, so a row can move under a finger.
    await tester.tap(find.byKey(const ValueKey('monitor.kill.cancel')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('kill -')), isFalse);

    await tester.tap(find.byKey(const ValueKey('monitor.process.102.kill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.kill.confirm')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('kill -15 102')), isTrue);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a wedged process can be force killed with SIGKILL', (tester) async {
    // Defect 68. `killProcess` has always taken a signal, but the only caller used the default, so
    // the app could send SIGTERM and nothing else — precisely the signal a stuck process ignores.
    // Kotlin offers both as separate actions (`ui/MonitorScreen.kt:920` and `:934`).
    await repo.insertServer(server(name: 'nas'));
    final transport = RecordingTransport(
      replies: {
        'ps -eo':
            '  PID USER     %CPU %MEM    VSZ     ELAPSED STAT COMMAND\n'
            '  102 root     90.0  1.0 100000    01:00:00 S    runaway\n',
      },
    );
    await pump(tester, transport: transport);
    await tester.tap(find.byKey(const ValueKey('monitor.tab.processes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.process.102')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('monitor.process.102.forceKill')));
    await tester.pumpAndSettle();

    expect(find.text('Force kill (SIGKILL)?'), findsOneWidget);
    expect(
      find.textContaining('Unsaved work in that process is lost'),
      findsOneWidget,
      reason: 'the consequence is the whole difference between the two actions',
    );

    // Cancelling sends nothing, as with the graceful path.
    await tester.tap(find.byKey(const ValueKey('monitor.kill.cancel')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('kill -')), isFalse);

    await tester.tap(find.byKey(const ValueKey('monitor.process.102.forceKill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.kill.confirm')));
    await tester.pumpAndSettle();

    expect(transport.commands.any((c) => c.contains('kill -9 102')), isTrue);
    expect(
      transport.commands.any((c) => c.contains('kill -15 102')),
      isFalse,
      reason: 'force must not also send the graceful signal',
    );
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('rebooting asks first and says what it will run', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = RecordingTransport();
    await pump(tester, transport: transport);

    await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
    await tester.pumpAndSettle();
    expect(find.text('Reboot nas?'), findsOneWidget);
    expect(find.textContaining('sudo reboot'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('monitor.reboot.cancel')));
    await tester.pumpAndSettle();
    expect(
      transport.commands.any((c) => c.contains('reboot')),
      isFalse,
      reason: 'a cancelled reboot must not reach the host',
    );

    await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.reboot.confirm')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('reboot')), isTrue);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a host with no log source explains why the pane is empty', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: {'journalctl': '---NOLOGS---'}));

    await tester.tap(find.byKey(const ValueKey('monitor.tab.logs')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.logs.unsupported')), findsOneWidget);
    expect(find.textContaining('No readable log source'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a host that simply has no log lines says so, distinctly', (tester) async {
    // A working log source that returned nothing rendered as a bare black pane with no message at
    // all — indistinguishable from a broken screen. Found on a real Alpine host (§15.10).
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: {'journalctl': ''}));

    await tester.tap(find.byKey(const ValueKey('monitor.tab.logs')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.logs.empty')), findsOneWidget);
    expect(find.textContaining('No log entries'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a filter that matches nothing blames the filter, not the host', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(
      tester,
      transport: RecordingTransport(
        replies: {'journalctl': '2026-08-04T10:00:00+0000 host unit[1]: started nginx'},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('monitor.tab.logs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.logs.filter.ERROR')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.logs.empty')), findsOneWidget);
    expect(find.textContaining('No ERROR entries'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a host with no service manager explains why the list is empty', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(
      tester,
      transport: RecordingTransport(replies: {'systemctl list-units': '---NOSYSTEMD---'}),
    );

    await tester.tap(find.byKey(const ValueKey('monitor.tab.services')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.services.unsupported')), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('the log level filter narrows the rendered lines', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(
      tester,
      transport: RecordingTransport(
        replies: {
          'journalctl':
              '2026-08-04T10:00:00+0000 host sshd: accepted connection\n'
              '2026-08-04T10:00:01+0000 host kernel: disk errors detected\n',
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('monitor.tab.logs')));
    await tester.pumpAndSettle();
    expect(find.textContaining('accepted connection'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('monitor.logs.filter.ERROR')));
    await tester.pumpAndSettle();

    expect(find.textContaining('accepted connection'), findsNothing);
    expect(
      find.textContaining('disk errors detected'),
      findsOneWidget,
      reason: 'the §15.1 inferLevel fix makes this an ERROR rather than INFO',
    );
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('a credential failure is shown as an error banner', (tester) async {
    await repo.insertServer(
      server(name: 'nas').copyWith(authType: 'key', authKeyAlias: const Value('gone')),
    );
    await pump(tester, transport: RecordingTransport());

    await tester.tap(find.byKey(const ValueKey('monitor.tab.services')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.error')), findsOneWidget);
    expect(find.textContaining('gone'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('hide-sensitive-info masks the address in the reboot dialog', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport());

    HostDisplay.instance.hideSensitiveInfo = true;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('10.0.0.1'),
      findsNothing,
      reason: 'a screenshot of this dialog must not leak the address',
    );
    await tester.tap(find.byKey(const ValueKey('monitor.reboot.cancel')));
    await tester.pumpAndSettle();
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  group('the health score', () {
    /// 95% memory and 1% disk, in the shapes `free -b` and `df -PB1 /` print.
    const strained =
        '@OS\nLinux\n'
        '@MEM\nMem: 100 95 0 0 0 5\n'
        '@DISK\n/dev/sda1 100 1 1 1% /\n';

    testWidgets('the ring explains itself when tapped', (tester) async {
      // A number between 0 and 100 with no stated reason is not information.
      await repo.insertServer(server(name: 'nas', healthScore: 88));
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: strained));
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('monitor.healthScore.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('health.dialog')), findsOneWidget);
      // The deduction names the reading and its threshold, not just a number.
      expect(find.byKey(const ValueKey('health.factor.0')), findsOneWidget);
      expect(find.textContaining('Memory 95%'), findsOneWidget);
      expect(find.byKey(const ValueKey('health.healthy')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('health.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('health.dialog')), findsNothing);
      vm.dispose();
      poller.dispose();
    });

    testWidgets('a host with nothing wrong says exactly that', (tester) async {
      // "No deductions" and "we did not check" are different facts, and an empty factor list would
      // render as the second.
      await repo.insertServer(server(name: 'nas'));
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(
          fallback: '@OS\nLinux\n@MEM\nMem: 100 5 0 0 0 95\n@DISK\n/dev/sda1 100 1 1 1% /\n',
        ),
      );
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('monitor.healthScore.open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('health.healthy')), findsOneWidget);
      expect(find.byKey(const ValueKey('health.factor.0')), findsNothing);
      vm.dispose();
      poller.dispose();
    });

    testWidgets("the user's own thresholds explain the score", (tester) async {
      // The explanation and the number both come from the shared config; two copies of it is how
      // the dialog ends up justifying a score nobody computed.
      await repo.insertServer(server(name: 'nas'));
      const strict = HealthScoringConfig(mem: MetricTiers(10, 20, 30, 40, 50, 60));
      await repo.insertSetting(HealthScoringConfig.settingKey, strict.encode());

      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: strained));
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('monitor.healthScore.open')));
      await tester.pumpAndSettle();

      expect(find.text('Score: ${strict.score(0, 95, 1, 0)} / 100'), findsOneWidget);
      vm.dispose();
      poller.dispose();
    });
  });

  group('the overview charts', () {
    const reply = '@OS\nLinux\n@MEM\nMem: 100 40 0 0 0 60\n@DISK\n/dev/sda1 100 1 1 1% /\n';

    testWidgets('a chart per headline reading, fed by the poller', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final poller = TelemetryPoller(app, transport: RecordingTransport(fallback: reply));
      await pump(tester, poller: poller);
      await poller.cycle();
      await poller.cycle();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('monitor.overview.cpuChart')), findsOneWidget);
      expect(find.byKey(const ValueKey('monitor.overview.ramChart')), findsOneWidget);
      expect(find.text('RAM utilisation · 2 samples'), findsOneWidget);
      vm.dispose();
      poller.dispose();
    });

    testWidgets('with no poller the charts are honest about having no series', (tester) async {
      // Every build without SSH wired. A line drawn from one on-demand fetch would be a claim about
      // a period nobody sampled.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.text('CPU utilisation · 0 samples'), findsOneWidget);
      vm.dispose();
    });
  });

  group('the CRON tab', () {
    const crontab =
        'MAILTO=ops@example.com\n'
        '# nightly jobs\n'
        '0 2 * * * /usr/bin/backup # OmniTerm: Nightly backup\n'
        '*/5 * * * * /usr/local/bin/ping-check\n';

    String reply(String body, {int status = 0}) => '$body\n$cronExitMarker$status\n';

    Future<void> openCron(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('monitor.tab.cron')));
      await tester.pumpAndSettle();
    }

    testWidgets('the host crontab is listed, described and kept whole', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {'crontab -l': reply(crontab)});
      await pump(tester, transport: transport);
      await openCron(tester);

      expect(find.byKey(const ValueKey('cron.list')), findsOneWidget);
      // The label the app wrote, and a description for the one written by hand.
      expect(find.text('Nightly backup'), findsOneWidget);
      expect(find.text('Every 5 minutes'), findsOneWidget);
      // The lines it does not understand are shown, not hidden — they are what a save carries.
      expect(find.text('MAILTO=ops@example.com'), findsOneWidget);
      expect(find.text('Kept as written'), findsNWidgets(2));
      vm.dispose();
    });

    testWidgets('a crontab that could not be read offers no editing at all', (tester) async {
      // The defect this guards: the Kotlin sends `crontab -l 2>/dev/null || true`, so a refusal
      // arrives as an empty crontab — and the first Add would replace a file nobody has seen.
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(
        replies: {'crontab -l': reply('You (root) are not allowed to use this program', status: 1)},
      );
      await pump(tester, transport: transport);
      await openCron(tester);

      expect(find.byKey(const ValueKey('cron.unreadable')), findsOneWidget);
      expect(find.textContaining('not allowed'), findsOneWidget);
      expect(find.byKey(const ValueKey('cron.empty')), findsNothing);
      final add = tester.widget<TextButton>(find.byKey(const ValueKey('cron.add')));
      expect(add.onPressed, isNull, reason: 'writing a crontab we could not read would replace it');
      vm.dispose();
    });

    testWidgets('a user with no crontab can still add their first job', (tester) async {
      // cron says this on stderr and exits non-zero; treating that as a failure would lock a
      // first-time user out of the feature entirely.
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(
        replies: {'crontab -l': reply('no crontab for root', status: 1)},
      );
      await pump(tester, transport: transport);
      await openCron(tester);

      expect(find.byKey(const ValueKey('cron.empty')), findsOneWidget);
      final add = tester.widget<TextButton>(find.byKey(const ValueKey('cron.add')));
      expect(add.onPressed, isNotNull);
      vm.dispose();
    });

    testWidgets('adding a job writes the whole file, with every other line intact', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {'crontab -l': reply(crontab)});
      await pump(tester, transport: transport);
      await openCron(tester);

      await tester.tap(find.byKey(const ValueKey('cron.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cron.editor.command')), '/usr/bin/tidy');
      await tester.enterText(find.byKey(const ValueKey('cron.editor.label')), 'Tidy');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('cron.preset.hourly')));
      await tester.tap(find.byKey(const ValueKey('cron.preset.hourly')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('cron.editor.summary'))).data,
        'Every hour',
        reason: 'the preset is described in words before it is written',
      );

      await tester.tap(find.byKey(const ValueKey('cron.editor.save')));
      await tester.pumpAndSettle();

      final write = transport.commands.firstWhere((c) => c.contains('| crontab -'));
      final encoded = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(write)!.group(1)!;
      final sent = utf8.decode(base64Decode(encoded));

      expect(sent, contains('0 * * * * /usr/bin/tidy # OmniTerm: Tidy'));
      expect(sent, contains('MAILTO=ops@example.com'), reason: 'the whole file is rewritten');
      expect(sent, contains('# nightly jobs'));
      expect(sent, contains('*/5 * * * * /usr/local/bin/ping-check'));
      expect(sent, endsWith('\n'));
      vm.dispose();
    });

    testWidgets('deleting says what it will actually do, and asks first', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {'crontab -l': reply(crontab)});
      await pump(tester, transport: transport);
      await openCron(tester);

      await tester.tap(find.byKey(const ValueKey('cron.line.2.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('rewrites the crontab'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cron.delete.cancel')));
      await tester.pumpAndSettle();
      expect(
        transport.commands.where((c) => c.contains('| crontab -')),
        isEmpty,
        reason: 'cancelling must not have written anything',
      );
      vm.dispose();
    });

    testWidgets('an invalid field blocks the save rather than writing a broken schedule', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: RecordingTransport(replies: {'crontab -l': reply(crontab)}));
      await openCron(tester);

      await tester.tap(find.byKey(const ValueKey('cron.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('cron.editor.command')), '/bin/true');
      await tester.enterText(find.byKey(const ValueKey('cron.field.hour')), '99');
      await tester.pumpAndSettle();

      expect(find.text('Not a hour cron accepts'), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('cron.editor.save')));
      expect(save.onPressed, isNull);
      vm.dispose();
    });
  });

  group('the Quick scripts tab', () {
    Future<void> addScript({
      required String name,
      String command = '/bin/true',
      String category = 'General',
      String targetOs = 'Any',
      String targetSystem = 'Any',
      bool quick = true,
    }) => repo.insertScript(
      QuickScriptsCompanion.insert(
        emoji: '*',
        name: name,
        command: command,
        color: 'cyan',
        category: Value(category),
        targetOs: Value(targetOs),
        targetSystem: Value(targetSystem),
        availableForQuick: Value(quick),
      ),
    );

    /// A metrics reply that says what the host is, which is what the targeting reads.
    String metricsFor(String os, {String platforms = 'docker'}) =>
        '@OS\n$os\n@PLATFORM\n$platforms\n@MEM\nMem: 100 10 0 0 0 90\n'
        '@DISK\n/dev/sda1 100 1 1 1% /\n';

    Future<void> openScripts(WidgetTester tester) async {
      // The Monitor tab strip scrolls, and Scripts is the fifth chip.
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('monitor.tab.scripts')),
        find.byKey(const ValueKey('monitor.tabs')),
        const Offset(-120, 0),
      );
      await tester.tap(find.byKey(const ValueKey('monitor.tab.scripts')));
      await tester.pumpAndSettle();
      // The saved scripts arrive on a drift watch stream, so the list is a turn or two behind the
      // tap that opened the tab.
      for (var i = 0; i < 5 && scriptsVm.allScripts.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('only the scripts that target this host are offered', (tester) async {
      // The whole point of the tab, and the first thing to consume `quickScriptMatchesHost` — the
      // targeting columns have round-tripped through the editor since the Tools port with nothing
      // reading them, so a Proxmox helper was offered on a Raspberry Pi.
      await repo.insertServer(server(name: 'nas'));
      await addScript(name: 'Anywhere');
      await addScript(name: 'Linux only', targetOs: 'Linux');
      await addScript(name: 'Mac only', targetOs: 'Darwin');
      await addScript(name: 'Proxmox only', targetSystem: 'Proxmox');

      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsFor('Linux')),
      );
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();
      await openScripts(tester);

      expect(find.text('* Anywhere'), findsOneWidget);
      expect(find.text('* Linux only'), findsOneWidget);
      expect(find.text('* Mac only'), findsNothing);
      expect(find.text('* Proxmox only'), findsNothing);
      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a host that has not said what it is says why the list is short', (tester) async {
      // A script that names an OS does not match a host that has not reported one, so the list
      // starts short. Without the note that reads as "your scripts are gone".
      await repo.insertServer(server(name: 'nas'));
      await addScript(name: 'Mac only', targetOs: 'Darwin');
      await addScript(name: 'Anywhere');
      await pump(tester);
      await openScripts(tester);

      expect(find.byKey(const ValueKey('monitor.scripts.unfiltered')), findsOneWidget);
      expect(find.text('* Anywhere'), findsOneWidget);
      expect(find.text('* Mac only'), findsNothing);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('"nothing saved" and "nothing matches" are different sentences', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final poller = TelemetryPoller(
        app,
        transport: RecordingTransport(fallback: metricsFor('Linux')),
      );
      await pump(tester, poller: poller);
      await poller.cycle();
      await tester.pumpAndSettle();
      await openScripts(tester);
      expect(find.textContaining('No quick scripts saved yet'), findsOneWidget);

      await addScript(name: 'Mac only', targetOs: 'Darwin');
      await tester.pumpAndSettle();
      expect(find.textContaining('None of your quick scripts target this host'), findsOneWidget);
      vm.dispose();
      scriptsVm.dispose();
      poller.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('running asks first, naming the command and the host', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await addScript(name: 'Disk usage', command: 'df -h');
      final transport = RecordingTransport(fallback: 'Filesystem  Size\n/dev/sda1  20G\n');
      await pump(tester, transport: transport);
      await openScripts(tester);

      await tester.tap(find.text('* Disk usage'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('run.dialog')), findsOneWidget);
      expect(find.text('\$ df -h'), findsOneWidget);
      expect(find.textContaining('nas'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      expect(
        transport.commands,
        isNot(contains('df -h')),
        reason: 'cancelling must not run the script',
      );
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a destructive script is flagged before it runs', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await addScript(name: 'Wipe', command: 'rm -rf /var/log');
      await pump(tester, transport: RecordingTransport());
      await openScripts(tester);

      await tester.tap(find.text('* Wipe'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('run.dialog.danger')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('confirmed output is shown, and a silent command says it printed nothing', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await addScript(name: 'Echo', command: 'echo hello');
      final transport = RecordingTransport(fallback: 'hello\n');
      await pump(tester, transport: transport);
      await openScripts(tester);

      await tester.tap(find.text('* Echo'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('monitor.scripts.output')), findsOneWidget);
      expect(find.text('* Echo'), findsWidgets);
      expect(transport.commands, contains('echo hello'));

      await tester.tap(find.byKey(const ValueKey('monitor.scripts.output.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('monitor.scripts.output')), findsNothing);
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a second one-off command replaces the first, and is what gets confirmed', (
      tester,
    ) async {
      // Observed on a device: after running one command and closing the output, the confirmation
      // for the next one still named the previous command.
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(fallback: 'ok\n');
      await pump(tester, transport: transport);
      await openScripts(tester);

      await tester.enterText(find.byKey(const ValueKey('monitor.scripts.command')), 'uptime');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.scripts.run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run.confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.scripts.output.close')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('monitor.scripts.command')),
        'rm -rf /tmp/x',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.scripts.run')));
      await tester.pumpAndSettle();

      expect(find.text('\$ rm -rf /tmp/x'), findsOneWidget);
      expect(find.byKey(const ValueKey('run.dialog.danger')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('a one-off command runs through the same confirmation', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(fallback: 'ok\n');
      await pump(tester, transport: transport);
      await openScripts(tester);

      await tester.enterText(find.byKey(const ValueKey('monitor.scripts.command')), 'uptime');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.scripts.run')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('run.dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('run.confirm')));
      await tester.pumpAndSettle();

      expect(transport.commands, contains('uptime'));
      vm.dispose();
      scriptsVm.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  /// Re-authentication before a stored sudo password is used, ported from `withSudoAuth`
  /// (`ui/AppViewModel.kt:2521`).
  ///
  /// Confirming a reboot answers "did you mean this". It does not answer "are you the person who
  /// saved that password" — and on a host with one saved, the action needs no credential at all.
  group('privileged actions', () {
    testWidgets('rebooting a host with a stored sudo password asks to authenticate', (
      tester,
    ) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final transport = RecordingTransport();
      await pump(tester, transport: transport);
      await lock.load();

      await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.reboot.confirm')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sudoAuth.dialog')),
        findsOneWidget,
        reason: 'the stored password must not be used on a bare confirmation',
      );
      expect(
        transport.commands.any((c) => c.contains('reboot')),
        isFalse,
        reason: 'nothing may run before the user is re-identified',
      );

      await tester.tap(find.byKey(const ValueKey('sudoAuth.cancel')));
      await tester.pumpAndSettle();
      expect(transport.commands.any((c) => c.contains('reboot')), isFalse);
      vm.dispose();
    });

    testWidgets('a host with no stored sudo password is not gated', (tester) async {
      // Nothing extra to protect: the user supplies the password themselves.
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport();
      await pump(tester, transport: transport);
      await lock.load();

      await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.reboot.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsNothing);
      vm.dispose();
    });

    testWidgets('the correct PIN lets the reboot through', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final transport = RecordingTransport();
      await pump(tester, transport: transport);
      await lock.load();

      await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.reboot.confirm')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sudoAuth.pin')), '1234');
      await tester.tap(find.byKey(const ValueKey('sudoAuth.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsNothing);
      expect(transport.commands.any((c) => c.contains('reboot')), isTrue);
      vm.dispose();
    });

    testWidgets('a wrong PIN keeps the dialog open and runs nothing', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final transport = RecordingTransport();
      await pump(tester, transport: transport);
      await lock.load();

      await tester.tap(find.byKey(const ValueKey('monitor.reboot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('monitor.reboot.confirm')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sudoAuth.pin')), '9999');
      await tester.tap(find.byKey(const ValueKey('sudoAuth.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.error')), findsOneWidget);
      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsOneWidget);
      expect(transport.commands.any((c) => c.contains('reboot')), isFalse);
      vm.dispose();
    });
  });

  /// Service-action output, ported from `ActionStreamDialog` (`ui/AppUi.kt:263`).
  ///
  /// It was a bare proportional-font `Text` with no copy button and no height bound. `systemctl`
  /// returns a page of text on a failure, so a unit that would not start pushed the service list off
  /// the screen and the error could not be pasted anywhere.
  testWidgets('service output is copyable and monospace', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport());
    vm.activeTab = MonitorTab.services;
    await tester.pumpAndSettle();

    await vm.runServiceAction(
      SimService(name: 'nginx', desc: '', status: 'active', subState: 'running'),
      'restart',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.services.feedback')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('monitor.services.feedback.copy')),
      findsOneWidget,
      reason: 'this is the text an operator pastes into a search or a bug report',
    );
    final text = tester.widget<Text>(find.byKey(const ValueKey('monitor.services.feedback.text')));
    expect(text.style?.fontFamily, OmniFonts.mono);
    vm.dispose();
  });

  testWidgets('a first process load says it is loading, not that there are none', (tester) async {
    // The defect: a 2px bar above an empty list is indistinguishable from a host with nothing
    // running. Kotlin splits first-load from refresh for exactly this reason.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: const {}));
    await tester.tap(find.byKey(const ValueKey('monitor.tab.processes')));
    await tester.pump();

    expect(find.byKey(const ValueKey('monitor.processes.list')), findsNothing);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('an empty process list blames the read, not the host', (tester) async {
    // Every host runs something, so an empty list after a successful read is the parse failing.
    // "No processes" would be a confident false statement about the machine.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: const {}));
    await tester.tap(find.byKey(const ValueKey('monitor.tab.processes')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.processes.empty')), findsOneWidget);
    expect(find.textContaining('not understood'), findsOneWidget);
    vm.dispose();
    scriptsVm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });
}
