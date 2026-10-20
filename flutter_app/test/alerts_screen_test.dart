import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/alert_presets.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/alert_evaluation.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/alerts_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/alerts_view_model.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late AlertsViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({required String name}) => Server(
    id: 0,
    name: name,
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
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

  Future<void> pump(WidgetTester tester) async {
    await app.start();
    vm = AlertsViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<AlertsViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: AlertsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Cancelling a drift `watch` subscription schedules zero-duration timers, and
  /// the framework's end-of-test check fails while any remain queued.
  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> goTo(WidgetTester tester, AlertsTab tab) async {
    await tester.tap(find.byKey(ValueKey('alerts.tab.${tab.name}')));
    await tester.pumpAndSettle();
  }

  /// Raises one incident by feeding sustained breaching samples at a realistic poll cadence.
  Future<void> raiseIncident(WidgetTester tester, {String severity = 'WARNING'}) async {
    final id = await repo.insertServer(server(name: 'nas'));
    await vm.saveRule(
      metricName: 'CPU Usage',
      thresholdValue: 80,
      severity: severity,
      triggerWindow: '2m',
    );
    await tester.pumpAndSettle();
    final host = (await repo.getServerById(id))!;
    for (var now = 0; now <= 130000; now += 30000) {
      await vm.evaluate(host, const AlertSample(cpuPercent: 95), nowMs: now);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('all three tabs render with Kotlin labels and empty states', (tester) async {
    await pump(tester);

    expect(find.text('Alerts Center'), findsOneWidget);
    expect(find.text('Active (0)'), findsOneWidget);
    expect(find.text('No active alert incidents.'), findsOneWidget);
    await goTo(tester, AlertsTab.rules);
    expect(find.byKey(const ValueKey('alerts.rules.list')), findsOneWidget);
    expect(find.text('Default alert rules'), findsOneWidget);
    await goTo(tester, AlertsTab.history);
    expect(find.text('No alert history yet.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the monitoring card states the in-app scope and the switch state', (tester) async {
    await pump(tester);
    expect(find.text('In-app monitoring'), findsOneWidget);
    expect(find.text('Global alerts are on.'), findsOneWidget);
    expect(find.textContaining('Alerts will not fire in the background'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('alerts.masterSwitch.toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Global alerts are off.'), findsOneWidget);
    expect(vm.alertsEnabled, isFalse);
    await finish(tester);
  });

  testWidgets('the add action is offered on the Rules tab only', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('alerts.add')), findsNothing);
    await goTo(tester, AlertsTab.rules);
    expect(find.byKey(const ValueKey('alerts.add')), findsOneWidget);
    await goTo(tester, AlertsTab.history);
    expect(find.byKey(const ValueKey('alerts.add')), findsNothing);
    await finish(tester);
  });

  group('rules', () {
    Future<void> openEditor(WidgetTester tester) async {
      await goTo(tester, AlertsTab.rules);
      await tester.tap(find.byKey(const ValueKey('alerts.add')));
      await tester.pumpAndSettle();
    }

    testWidgets('the dialog creates a critical All Hosts rule like Kotlin', (tester) async {
      await pump(tester);
      await openEditor(tester);

      expect(find.text('Add Alert Rule Trigger'), findsOneWidget);
      expect(find.text('Threshold value (%)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '75');
      await tester.tap(find.byKey(const ValueKey('alerts.editor.window.10m')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alerts.editor.save')));
      await tester.pumpAndSettle();

      final rule = vm.rules.single;
      expect(rule.thresholdValue, 75);
      expect(rule.severity, 'CRITICAL');
      expect(rule.serverId, 0);
      expect(find.text('All Hosts · Threshold > 75.0% for 10m'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unreachable percentage threshold disables Confirm', (tester) async {
      await pump(tester);
      await openEditor(tester);
      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '150');
      await tester.pumpAndSettle();

      expect(find.text('Must be 100 or less'), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('alerts.editor.save')));
      expect(save.onPressed, isNull, reason: 'a rule that can never fire would look healthy');
      await finish(tester);
    });

    testWidgets('choosing a metric resets the threshold to its Kotlin default', (tester) async {
      await pump(tester);
      await openEditor(tester);

      await tester.tap(find.byKey(const ValueKey('alerts.editor.metric.Latency')));
      await tester.pumpAndSettle();
      expect(find.text('Threshold value (ms)'), findsOneWidget);
      expect(find.text('250'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.editor.metric.Temperature')));
      await tester.pumpAndSettle();
      expect(find.text('Threshold value (°C)'), findsOneWidget);
      expect(find.text('80.0'), findsOneWidget);
      expect(find.textContaining('Only triggers on hosts that report a CPU temperature'), findsOne);
      await finish(tester);
    });

    testWidgets('picking several hosts creates one rule per host', (tester) async {
      await repo.insertServer(server(name: 'alpha'));
      await repo.insertServer(server(name: 'beta'));
      await pump(tester);
      await openEditor(tester);

      await tester.tap(find.byKey(const ValueKey('alerts.editor.hosts')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha').last);
      await tester.tap(find.text('beta').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alerts.editor.save')));
      await tester.pumpAndSettle();

      expect(
        vm.rules.map((r) => vm.serverFor(r.serverId)?.name),
        unorderedEquals(['alpha', 'beta']),
      );
      await finish(tester);
    });

    testWidgets('editing keeps the rule and pre-fills its values', (tester) async {
      await pump(tester);
      await vm.saveRule(
        metricName: 'Memory Usage',
        thresholdValue: 85,
        severity: 'WARNING',
        notes: 'swap pressure',
      );
      await tester.pumpAndSettle();
      await goTo(tester, AlertsTab.rules);
      expect(find.text('swap pressure'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('alerts.rule.${vm.rules.single.id}.edit')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Alert Rule'), findsOneWidget);
      expect(find.text('85.0'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '70');
      await tester.tap(find.byKey(const ValueKey('alerts.editor.save')));
      await tester.pumpAndSettle();

      expect(vm.rules.single.thresholdValue, 70);
      expect(vm.rules.single.severity, 'WARNING', reason: 'editing keeps the severity');
      await finish(tester);
    });

    testWidgets('deleting a rule asks with Kotlin wording first', (tester) async {
      await pump(tester);
      await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 80, severity: 'WARNING');
      await tester.pumpAndSettle();
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(ValueKey('alerts.rule.${vm.rules.single.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete rule?'), findsOneWidget);
      expect(find.text('Delete the CPU Usage alert rule for this host?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.deleteRule.cancel')));
      await tester.pumpAndSettle();
      expect(vm.rules, hasLength(1));

      await tester.tap(find.byKey(ValueKey('alerts.rule.${vm.rules.single.id}.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alerts.deleteRule.confirm')));
      await tester.pumpAndSettle();
      expect(vm.rules, isEmpty);
      await finish(tester);
    });

    testWidgets('the defaults toggle confirms before seeding', (tester) async {
      await pump(tester);
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.switch')));
      await tester.pumpAndSettle();
      expect(find.text('Enable default rules?'), findsOneWidget);
      expect(find.textContaining('resetting any earlier edits to them'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.cancel')));
      await tester.pumpAndSettle();
      expect(vm.rules, isEmpty);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alerts.presets.confirm')));
      await tester.pumpAndSettle();

      expect(vm.rules, hasLength(kAlertPresets.length));
      expect(find.textContaining('All Hosts · Threshold >'), findsWidgets);
      await finish(tester);
    });
  });

  group('firing incidents', () {
    testWidgets('an incident is listed with Kotlin threshold and server lines', (tester) async {
      await pump(tester);
      await raiseIncident(tester, severity: 'CRITICAL');

      expect(find.text('Active (1)'), findsOneWidget);
      expect(find.text('Threshold: 80.0% · Current: 95.0%'), findsOneWidget);
      expect(find.text('Server: nas'), findsOneWidget);
      expect(find.text('CRITICAL'), findsOneWidget);
      expect(find.text('Ack All'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('acknowledging hides it and records history', (tester) async {
      await pump(tester);
      await raiseIncident(tester);

      final alert = vm.activeAlerts.single;
      await tester.tap(find.byKey(ValueKey('alerts.active.${alert.id}.ack')));
      await tester.pumpAndSettle();

      expect(vm.activeAlerts, hasLength(1), reason: 'acknowledging is not resolving');
      expect(find.text('Active (0)'), findsOneWidget);
      // Kotlin shows the empty state when nothing is visible or muted, even with acknowledged
      // incidents waiting to recover.
      expect(find.text('No active alert incidents.'), findsOneWidget);
      await goTo(tester, AlertsTab.history);
      expect(find.text('ACKNOWLEDGED'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('mute 1h moves it to the muted section and unmute brings it back', (tester) async {
      await pump(tester);
      await raiseIncident(tester);
      final alert = vm.activeAlerts.single;

      await tester.tap(find.byKey(ValueKey('alerts.active.${alert.id}.mute')));
      await tester.pumpAndSettle();

      expect(vm.unmutedCount, 0);
      expect(find.text('Muted incidents'), findsOneWidget);
      expect(find.text('MUTED'), findsOneWidget);
      expect(find.textContaining('Until '), findsOneWidget);
      expect(find.text('Active (0)'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('alerts.muted.${alert.id}.unmute')));
      await tester.pumpAndSettle();
      expect(find.text('Active (1)'), findsOneWidget);
      // One history row per incident (Kotlin's unique activeAlertId), showing the latest step.
      await goTo(tester, AlertsTab.history);
      expect(find.text('UNMUTED'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting the rule resolves its incident', (tester) async {
      await pump(tester);
      await raiseIncident(tester);
      await vm.deleteRule(vm.rules.single);
      await tester.pumpAndSettle();

      expect(find.text('No active alert incidents.'), findsOneWidget);
      await goTo(tester, AlertsTab.history);
      expect(find.text('RESOLVED'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets('history keeps the name the host had and clears after confirming', (tester) async {
    // The archive is denormalised so a row stays readable on its own terms. Renaming the host must
    // not rewrite what the incident said when it happened.
    await pump(tester);
    await raiseIncident(tester);
    final serverId = vm.activeAlerts.single.serverId;
    await vm.dismiss(vm.activeAlerts.single);
    await tester.pumpAndSettle();

    final host = (await repo.getServerById(serverId))!;
    await repo.updateServer(host.copyWith(name: 'renamed-later'));
    await tester.pumpAndSettle();

    await goTo(tester, AlertsTab.history);
    expect(find.text('nas'), findsOneWidget);
    expect(find.textContaining('renamed-later'), findsNothing);
    expect(find.text('Current 95.0% · threshold 80.0% · WARNING'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('alerts.history.clear')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all alert history?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alerts.history.clearDialog.confirm')));
    await tester.pumpAndSettle();
    expect(find.text('No alert history yet.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a 200% landscape window scrolls instead of overflowing', (tester) async {
    // The API 35 route sweep at 420 dpi: landscape at 200% leaves roughly this much body.
    tester.view.physicalSize = const Size(800, 230);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
