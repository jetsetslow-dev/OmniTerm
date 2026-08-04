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

  /// See MIGRATION.md: cancelling a drift `watch` subscription schedules zero-duration timers, and
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

  testWidgets('all three tabs render', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('alerts.active.empty')), findsOneWidget);
    await goTo(tester, AlertsTab.rules);
    expect(find.byKey(const ValueKey('alerts.rules.list')), findsOneWidget);
    await goTo(tester, AlertsTab.history);
    expect(find.byKey(const ValueKey('alerts.history.empty')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('with no rules, the empty state does not read as reassurance', (tester) async {
    // "Nothing is firing" is misleading when there is nothing that could fire.
    await pump(tester);
    expect(find.textContaining('nothing is being watched'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the master switch says what turning it off costs', (tester) async {
    await pump(tester);
    expect(find.textContaining('evaluated on every telemetry poll'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('alerts.masterSwitch.toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('no rules are evaluated'), findsOneWidget);
    expect(vm.alertsEnabled, isFalse);
    await finish(tester);
  });

  group('rules', () {
    testWidgets('the editor creates a rule and previews what it will do', (tester) async {
      await pump(tester);
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(const ValueKey('alerts.addRule')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '75');
      await tester.pumpAndSettle();

      // The preview is what stops a rule being written that does not say what the author meant.
      expect(find.text('CPU Usage above 75% for 5m'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.editor.save')));
      await tester.pumpAndSettle();

      expect(vm.rules.single.thresholdValue, 75);
      expect(find.text('CPU Usage above 75% for 5m'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unreachable percentage threshold is refused in the sheet', (tester) async {
      await pump(tester);
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(const ValueKey('alerts.addRule')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '150');
      await tester.tap(find.byKey(const ValueKey('alerts.editor.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('alerts.editor.error')), findsOneWidget);
      expect(vm.rules, isEmpty, reason: 'a rule that can never fire would look healthy');
      await finish(tester);
    });

    testWidgets('the mount field appears only for disk rules', (tester) async {
      await pump(tester);
      await goTo(tester, AlertsTab.rules);
      await tester.tap(find.byKey(const ValueKey('alerts.addRule')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('alerts.editor.mount')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('alerts.editor.metric')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disk Usage').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('alerts.editor.mount')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting a rule says the metric stops being watched', (tester) async {
      await pump(tester);
      await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 80, severity: 'WARNING');
      await tester.pumpAndSettle();
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(ValueKey('alerts.rule.${vm.rules.single.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing will watch this metric'), findsOneWidget);

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

    testWidgets('the defaults toggle warns before seeding', (tester) async {
      await pump(tester);
      await goTo(tester, AlertsTab.rules);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('resets any thresholds you changed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.cancel')));
      await tester.pumpAndSettle();
      expect(vm.rules, isEmpty);

      await tester.tap(find.byKey(const ValueKey('alerts.presets.switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alerts.presets.confirm')));
      await tester.pumpAndSettle();

      expect(vm.rules, hasLength(kAlertPresets.length));
      expect(find.text('DEFAULT'), findsWidgets);
      await finish(tester);
    });
  });

  group('firing incidents', () {
    testWidgets('an incident is listed with its value and threshold', (tester) async {
      await pump(tester);
      await raiseIncident(tester, severity: 'CRITICAL');

      expect(find.byKey(const ValueKey('alerts.active.list')), findsOneWidget);
      expect(find.textContaining('CPU Usage'), findsWidgets);
      expect(find.text('95% (threshold 80%)'), findsOneWidget);
      expect(find.text('CRITICAL'), findsWidgets);
      await finish(tester);
    });

    testWidgets('acknowledging marks it seen without hiding it', (tester) async {
      await pump(tester);
      await raiseIncident(tester);

      final alert = vm.activeAlerts.single;
      await tester.tap(find.byKey(ValueKey('alerts.active.${alert.id}.ack')));
      await tester.pumpAndSettle();

      expect(vm.activeAlerts, hasLength(1));
      expect(find.text('SEEN'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('muting explains that it is not a fix, and clears the badge', (tester) async {
      await pump(tester);
      await raiseIncident(tester);
      expect(vm.unmutedCount, 1);

      await tester.tap(find.byKey(ValueKey('alerts.active.${vm.activeAlerts.single.id}.mute')));
      await tester.pumpAndSettle();
      expect(find.textContaining('stops it re-alerting'), findsOneWidget);
      expect(find.textContaining('still resolves on its own'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alerts.mute.1 hour')));
      await tester.pumpAndSettle();

      expect(vm.activeAlerts, hasLength(1), reason: 'muting is not dismissing');
      expect(vm.unmutedCount, 0);
      expect(find.text('MUTED'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('dismissing archives it', (tester) async {
      await pump(tester);
      await raiseIncident(tester);

      await tester.tap(find.byKey(ValueKey('alerts.active.${vm.activeAlerts.single.id}.dismiss')));
      await tester.pumpAndSettle();

      expect(vm.activeAlerts, isEmpty);
      await goTo(tester, AlertsTab.history);
      expect(find.text('DISMISSED'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the tab badge counts unmuted incidents only', (tester) async {
      await pump(tester);
      await raiseIncident(tester);
      expect(find.text('1'), findsWidgets);

      await vm.mute(vm.activeAlerts.single, const Duration(hours: 1));
      await tester.pumpAndSettle();
      expect(vm.unmutedCount, 0);
      await finish(tester);
    });
  });

  testWidgets('history keeps the name the host had at the time', (tester) async {
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
    expect(find.textContaining('nas'), findsOneWidget);
    expect(find.textContaining('renamed-later'), findsNothing);
    await finish(tester);
  });
}
