import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/monitor/monitor_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';
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

  Server server({required String name, String status = 'online', int healthScore = 100}) => Server(
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
    healthScore: healthScore,
    lastLatency: 0,
    status: status,
    authStatus: 'ok',
  );

  late MonitorViewModel vm;

  Future<void> pump(WidgetTester tester, {RecordingTransport? transport}) async {
    await app.start();
    vm = MonitorViewModel(app, transport: transport);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<MonitorViewModel>.value(value: vm),
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
  });

  testWidgets('an online host shows the selector, health score and tabs', (tester) async {
    await repo.insertServer(server(name: 'nas', healthScore: 82));
    await pump(tester, transport: RecordingTransport());

    expect(find.byKey(const ValueKey('monitor.hostPicker')), findsOneWidget);
    expect(find.text('82'), findsOneWidget);
    for (final tab in MonitorTab.values) {
      expect(find.byKey(ValueKey('monitor.tab.${tab.name}')), findsOneWidget);
    }
    vm.dispose();
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
      (MonitorTab.processes, 'monitor.processes.list'),
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
  });

  testWidgets('tabs not yet ported say so rather than showing an empty pane', (tester) async {
    // A blank pane reads as "this host has nothing", which is a different and misleading claim.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport());

    await tester.tap(find.byKey(const ValueKey('monitor.tab.cron')));
    await tester.pumpAndSettle();
    expect(find.textContaining('not available in this build yet'), findsOneWidget);
    vm.dispose();
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
  });

  testWidgets('a host with no log source explains why the pane is empty', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: {'journalctl': '---NOLOGS---'}));

    await tester.tap(find.byKey(const ValueKey('monitor.tab.logs')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('monitor.logs.unsupported')), findsOneWidget);
    expect(find.textContaining('No readable log source'), findsOneWidget);
    vm.dispose();
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
  });
}
