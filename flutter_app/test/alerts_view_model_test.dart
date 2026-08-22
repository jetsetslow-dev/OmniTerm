import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/alert_presets.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/domain/alert_evaluation.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/alerts_view_model.dart';
import 'package:omniterm/ui/view_model/app_state.dart';

import 'support/fake_alert_notifier.dart';
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

  late FakeAlertNotifier notifier;

  Future<AlertsViewModel> boot() async {
    await app.start();
    notifier = FakeAlertNotifier();
    final vm = AlertsViewModel(app, notifier: notifier);
    await vm.start();
    await Future<void>.delayed(Duration.zero);
    return vm;
  }

  /// Lets the drift `watch` streams deliver. Two turns, because a write and the stream emission
  /// that follows it are separate microtask hops.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<List<ActiveAlert>> fire(
    AlertsViewModel vm,
    Server host,
    AlertSample sample, {
    int? nowMs,
  }) => vm.evaluate(host, sample, nowMs: nowMs);

  /// Feeds samples at a realistic poll cadence from [from] to [to].
  ///
  /// The step must stay under the stale gap (90s), or the tracker correctly treats each sample as
  /// arriving after an unobserved period and restarts the window — which is the behaviour the
  /// gap test below exercises deliberately.
  Future<void> sustain(
    AlertsViewModel vm,
    Server host,
    AlertSample sample, {
    int from = 0,
    required int to,
    int step = 30000,
  }) async {
    for (var now = from; now <= to; now += step) {
      await fire(vm, host, sample, nowMs: now);
    }
  }

  group('rules', () {
    test('a rule is saved and listed', () async {
      final vm = await boot();
      expect(
        await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 80, severity: 'WARNING'),
        isNull,
      );
      await settle();

      expect(vm.rules.single.metricName, 'CPU Usage');
      expect(vm.rules.single.thresholdValue, 80);
      vm.dispose();
    });

    test('each new rule gets its own row', () async {
      final vm = await boot();
      await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 80, severity: 'WARNING');
      await settle();
      await vm.saveRule(metricName: 'Memory Usage', thresholdValue: 85, severity: 'WARNING');
      await settle();
      expect(vm.rules, hasLength(2));
      vm.dispose();
    });

    test('validation refuses rules that could never work', () async {
      final vm = await boot();
      expect(
        await vm.saveRule(metricName: 'Gremlins', thresholdValue: 1, severity: 'WARNING'),
        contains('metric'),
      );
      expect(
        await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 0, severity: 'WARNING'),
        contains('greater than zero'),
      );
      // A rule that can never be reached is worse than a noisy one: nothing signals it is broken.
      expect(
        await vm.saveRule(metricName: 'CPU Usage', thresholdValue: 150, severity: 'WARNING'),
        contains('cannot exceed 100'),
      );
      expect(
        await vm.saveRule(
          metricName: 'CPU Usage',
          thresholdValue: 80,
          severity: 'WARNING',
          triggerWindow: '1h',
        ),
        contains('trigger window'),
      );
      await settle();
      expect(vm.rules, isEmpty);
      vm.dispose();
    });

    test('a latency threshold above 100 is fine, since it is not a percentage', () async {
      final vm = await boot();
      expect(
        await vm.saveRule(metricName: 'Latency', thresholdValue: 250, severity: 'WARNING'),
        isNull,
      );
      await settle();
      expect(vm.rules.single.thresholdValue, 250);
      vm.dispose();
    });

    test('a mount point is kept only for disk rules', () async {
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        mountPoint: '/srv',
      );
      await settle();
      expect(vm.rules.single.mountPoint, '/', reason: 'a mount means nothing to a CPU rule');
      vm.dispose();
    });

    test('a fleet-wide rule is labelled as such', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await settle();
      expect(vm.scopeLabel(0), 'All hosts');
      expect(vm.scopeLabel(id), 'nas');
      vm.dispose();
    });
  });

  group('evaluation', () {
    test('a breach raises an incident once the window has passed', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'CRITICAL',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      // First breaching sample: the window has not elapsed, so nothing fires yet.
      await fire(vm, host, const AlertSample(cpuPercent: 95), nowMs: 0);
      await settle();
      expect(vm.activeAlerts, isEmpty, reason: 'a 2m rule must not fire instantly');

      await sustain(vm, host, const AlertSample(cpuPercent: 95), from: 30000, to: 130000);
      await settle();
      expect(vm.activeAlerts, hasLength(1));
      expect(vm.activeAlerts.single.severity, 'CRITICAL');
      expect(vm.activeAlerts.single.currentValue, 95);
      vm.dispose();
    });

    test('a single clean sample does not resolve it', () async {
      // Hysteresis: one jittery dip must not flap the incident closed and straight back open.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();
      expect(vm.activeAlerts, hasLength(1));

      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 140000);
      await settle();
      expect(vm.activeAlerts, hasLength(1), reason: 'one clean sample is not a recovery');

      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 150000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('resolving archives the incident', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 140000);
      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 150000);
      await settle();

      expect(vm.history.single.status, 'resolved');
      expect(
        vm.history.single.serverName,
        'nas',
        reason: 'the archive must stay readable after the host is deleted',
      );
      vm.dispose();
    });

    test('a sampling gap restarts the window rather than firing on unobserved time', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '5m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await fire(vm, host, const AlertSample(cpuPercent: 95), nowMs: 0);
      // The app was asleep for an hour. Wall-clock time passed, but nothing was measured.
      await fire(vm, host, const AlertSample(cpuPercent: 95), nowMs: 3600000);
      await settle();
      expect(
        vm.activeAlerts,
        isEmpty,
        reason: 'an alert about a period nobody measured is not evidence of anything',
      );
      vm.dispose();
    });

    test('a fleet-wide rule fires per host, not once overall', () async {
      // A shared rule id means the host must be part of the incident match, or one machine would
      // suppress every other machine's alert.
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();

      final a = (await repo.getServerById(aId))!;
      final b = (await repo.getServerById(bId))!;
      for (var now = 0; now <= 130000; now += 30000) {
        await fire(vm, a, const AlertSample(cpuPercent: 95), nowMs: now);
        await fire(vm, b, const AlertSample(cpuPercent: 95), nowMs: now);
      }
      await settle();

      expect(vm.activeAlerts, hasLength(2));
      expect(vm.activeAlerts.map((x) => x.serverId).toSet(), {aId, bId});
      vm.dispose();
    });

    test('a host-specific rule does not evaluate on other hosts', () async {
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
        serverId: aId,
      );
      await settle();

      final b = (await repo.getServerById(bId))!;
      await sustain(vm, b, const AlertSample(cpuPercent: 99), to: 130000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('a disabled rule is not evaluated', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
        enabled: false,
      );
      await settle();

      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 99), to: 130000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('the master switch stops evaluation entirely', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await vm.setAlertsEnabled(false);
      await settle();

      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 99), to: 130000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('a temperature rule never fires on a host with no sensor', () async {
      final id = await repo.insertServer(server(name: 'vm'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'Temperature',
        thresholdValue: 1,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();

      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 99), to: 130000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });
  });

  group('incident actions', () {
    Future<(AlertsViewModel, Server)> fired() async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();
      return (vm, host);
    }

    test('acknowledging keeps the incident but marks it seen', () async {
      final (vm, _) = await fired();
      await vm.acknowledge(vm.activeAlerts.single);
      await settle();

      expect(vm.activeAlerts, hasLength(1));
      expect(vm.activeAlerts.single.acknowledged, isTrue);
      vm.dispose();
    });

    test('muting keeps it visible and out of the badge count', () async {
      // The point is to stop being told about something you already know, not to pretend it is
      // fixed.
      final (vm, _) = await fired();
      expect(vm.unmutedCount, 1);

      await vm.mute(vm.activeAlerts.single, const Duration(hours: 1));
      await settle();

      expect(vm.activeAlerts, hasLength(1));
      expect(vm.unmutedCount, 0);
      vm.dispose();
    });

    test('dismissing archives it and drops the breach window', () async {
      final (vm, host) = await fired();
      await vm.dismiss(vm.activeAlerts.single);
      await settle();

      expect(vm.activeAlerts, isEmpty);
      expect(vm.history.single.status, 'dismissed');

      // The window was forgotten, so the next breach starts a fresh one rather than firing at once.
      await fire(vm, host, const AlertSample(cpuPercent: 95), nowMs: 140000);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('critical incidents sort above warnings', () async {
      // An alerts list is read top-down under pressure; a CRITICAL under six newer warnings is a
      // warning that has been hidden.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await vm.saveRule(
        metricName: 'Memory Usage',
        thresholdValue: 80,
        severity: 'CRITICAL',
        triggerWindow: '2m',
      );
      await settle();

      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 95, memoryPercent: 95), to: 130000);
      await settle();

      expect(vm.activeAlerts.first.severity, 'CRITICAL');
      vm.dispose();
    });
  });

  group('editing a firing rule', () {
    test('changing the threshold clears the incident', () async {
      // Keeping it would report a breach against a threshold the rule no longer has.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();
      expect(vm.activeAlerts, hasLength(1));

      await vm.saveRule(
        existing: vm.rules.single,
        metricName: 'CPU Usage',
        thresholdValue: 99,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();

      expect(vm.activeAlerts, isEmpty);
      expect(vm.history.single.status, 'rule changed');
      vm.dispose();
    });

    test('disabling a rule clears its incident', () async {
      // A disabled rule cannot re-evaluate, so its banner could never resolve on its own.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();

      await vm.setRuleEnabled(vm.rules.single, false);
      await settle();
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });

    test('deleting a rule clears its incident too', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();

      await vm.deleteRule(vm.rules.single);
      await settle();
      expect(vm.rules, isEmpty);
      expect(vm.activeAlerts, isEmpty);
      vm.dispose();
    });
  });

  group('default rules', () {
    test('enabling seeds them fleet-wide', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(true);
      await settle();

      expect(vm.rules, hasLength(kAlertPresets.length));
      expect(
        vm.rules.every((r) => r.serverId == 0),
        isTrue,
        reason: 'a per-host copy would silently miss any host added later',
      );
      expect(await repo.getSetting(alertPresetsSetting), 'true');
      vm.dispose();
    });

    test('enabling twice does not duplicate', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(true);
      await settle();
      await vm.setPresetsEnabled(true);
      await settle();
      expect(vm.rules, hasLength(kAlertPresets.length));
      vm.dispose();
    });

    test('disabling keeps the user\'s own rules', () async {
      final vm = await boot();
      await vm.saveRule(metricName: 'Latency', thresholdValue: 500, severity: 'WARNING');
      await vm.setPresetsEnabled(true);
      await settle();

      await vm.setPresetsEnabled(false);
      await settle();

      expect(vm.rules, hasLength(1));
      expect(vm.rules.single.thresholdValue, 500);
      vm.dispose();
    });

    test('a retuned default is still removed, because matching is by key', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(true);
      await settle();

      final cpu = vm.rules.firstWhere((r) => r.presetKey == 'alert.cpu');
      await vm.saveRule(
        existing: cpu,
        metricName: cpu.metricName,
        thresholdValue: 70,
        severity: cpu.severity,
      );
      await settle();
      expect(
        vm.isPristinePresetRule(vm.rules.firstWhere((r) => r.presetKey == 'alert.cpu')),
        isFalse,
      );

      await vm.setPresetsEnabled(false);
      await settle();
      expect(vm.rules, isEmpty);
      vm.dispose();
    });

    test('an untouched default is recognised as pristine', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(true);
      await settle();
      expect(vm.rules.every(vm.isPristinePresetRule), isTrue);
      vm.dispose();
    });

    test('the flag is read back on a later start', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(true);
      await settle();
      vm.dispose();

      final reopened = AlertsViewModel(app);
      await reopened.start();
      expect(reopened.presetsEnabled, isTrue);
      reopened.dispose();
    });
  });

  test('history can be cleared', () async {
    final id = await repo.insertServer(server(name: 'nas'));
    final vm = await boot();
    await vm.saveRule(
      metricName: 'CPU Usage',
      thresholdValue: 80,
      severity: 'WARNING',
      triggerWindow: '2m',
    );
    await settle();
    final host = (await repo.getServerById(id))!;
    await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
    await settle();
    await vm.dismiss(vm.activeAlerts.single);
    await settle();
    expect(vm.history, hasLength(1));

    await vm.clearHistory();
    await settle();
    expect(vm.history, isEmpty);
    vm.dispose();
  });

  group('notifications', () {
    Future<(AlertsViewModel, Server)> firingRule({
      String metric = 'CPU Usage',
      double threshold = 80,
      String severity = 'CRITICAL',
      String mountPoint = '',
      AlertSample sample = const AlertSample(cpuPercent: 95),
    }) async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await vm.saveRule(
        metricName: metric,
        thresholdValue: threshold,
        severity: severity,
        triggerWindow: '2m',
        mountPoint: mountPoint,
      );
      await settle();
      final host = (await repo.getServerById(id))!;
      await sustain(vm, host, sample, to: 130000);
      await settle();
      return (vm, host);
    }

    test('a fired alert reaches the notification shade', () async {
      // Without this the Alerts screen is a dashboard: a rule that only changes a colour on a
      // screen nobody is looking at has not alerted anyone.
      final (vm, _) = await firingRule();

      expect(notifier.posted, hasLength(1));
      expect(notifier.posted.single.title, 'CRITICAL: nas');
      expect(notifier.posted.single.body, contains('CPU Usage'));
      vm.dispose();
    });

    test('the body carries the threshold, not just the value', () async {
      // "94%" means nothing without knowing whether the line was drawn at 90 or 50.
      final (vm, _) = await firingRule(threshold: 80);

      expect(notifier.posted.single.body, contains('95%'));
      expect(notifier.posted.single.body, contains('threshold 80%'));
      vm.dispose();
    });

    test('a disk rule names its mount point', () async {
      // "Disk Usage at 95%" does not say which disk to go and clear.
      final (vm, _) = await firingRule(
        metric: 'Disk Usage',
        mountPoint: '/var',
        sample: const AlertSample(
          mounts: [
            DiskUsage(mount: '/var', filesystem: '/dev/sda2', totalBytes: 100, usedBytes: 95),
          ],
        ),
      );

      expect(notifier.posted.single.body, contains('on /var'));
      vm.dispose();
    });

    test('the same incident is not re-posted while it stays open', () async {
      final (vm, host) = await firingRule();
      await sustain(vm, host, const AlertSample(cpuPercent: 97), from: 160000, to: 300000);
      await settle();

      expect(notifier.posted, hasLength(1), reason: 'one incident, one banner');
      vm.dispose();
    });

    test('resolving clears the banner', () async {
      // A banner left in the shade for a host that recovered hours ago is how a user learns to
      // swipe them all away unread.
      final (vm, host) = await firingRule();
      final posted = notifier.posted.single.id;

      await sustain(vm, host, const AlertSample(cpuPercent: 5), from: 160000, to: 400000);
      await settle();

      expect(vm.activeAlerts, isEmpty);
      expect(notifier.cleared, contains(posted));
      vm.dispose();
    });

    test('dismissing clears the banner too', () async {
      final (vm, _) = await firingRule();
      final posted = notifier.posted.single.id;

      await vm.dismiss(vm.activeAlerts.single);
      await settle();

      expect(notifier.cleared, contains(posted));
      vm.dispose();
    });

    test('a refused notification does not lose the incident', () async {
      // The incident is the record; the banner is a courtesy. Losing the first must never follow
      // from losing the second.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      notifier.postFailure = StateError('notification service unavailable');
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();

      expect(vm.activeAlerts, hasLength(1));
      vm.dispose();
    });

    test('without a notifier the rule still fires', () async {
      // Convention 4: the feature degrades to "no banner", not to a crash or a lost alert.
      final id = await repo.insertServer(server(name: 'nas'));
      await app.start();
      final vm = AlertsViewModel(app);
      await vm.start();
      await Future<void>.delayed(Duration.zero);
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await settle();

      expect(vm.canNotify, isFalse);
      expect(vm.activeAlerts, hasLength(1));
      vm.dispose();
    });

    test('permission is asked for when alerts are switched on, never when off', () async {
      // The system prompt arrives with the context that explains it, rather than at launch.
      final vm = await boot();

      await vm.setAlertsEnabled(false);
      expect(notifier.permissionRequests, 0);

      await vm.setAlertsEnabled(true);
      expect(notifier.permissionRequests, 1);
      expect(vm.notificationsAllowed, isTrue);
      vm.dispose();
    });

    test('a refused permission is remembered so the screen can say so', () async {
      final vm = await boot();
      notifier.permission = false;

      await vm.setAlertsEnabled(true);

      expect(vm.notificationsAllowed, isFalse);
      vm.dispose();
    });
  });

  /// The "Alert history limit" setting, applied at the three points Kotlin applies it.
  ///
  /// It had no effect at all: the preference was stored and shown, `pruneAlertHistoryPerServer` and
  /// `pruneAlertHistoryForServer` both existed on the repository, and nothing ever called either —
  /// so a monitoring app archived an incident every time one resolved and never trimmed the table.
  group('history retention', () {
    /// Writes [count] archived incidents for [serverId] directly, oldest first.
    Future<void> seedHistory(int serverId, int count, {String name = 'nas'}) async {
      for (var i = 0; i < count; i++) {
        await repo.insertAlertHistory(
          AlertHistoryCompanion.insert(
            activeAlertId: i,
            serverId: serverId,
            serverName: name,
            metricName: 'CPU Usage',
            currentValue: 90,
            thresholdValue: 80,
            severity: 'WARNING',
            triggeredTime: 1000 + i,
            historyTime: 1000 + i,
            status: 'resolved',
          ),
        );
      }
    }

    Future<void> setLimit(int limit) async {
      await repo.insertSetting('alert_history_limit', '$limit');
      app.applyPreferences(AppPreferences.defaults.copyWith(alertHistoryLimit: limit));
    }

    test('archiving trims the host back to the configured limit', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      await setLimit(10);
      await seedHistory(id, 40);
      final vm = await boot();
      await vm.saveRule(
        metricName: 'CPU Usage',
        thresholdValue: 80,
        severity: 'WARNING',
        triggerWindow: '2m',
      );
      await settle();
      final host = (await repo.getServerById(id))!;

      await sustain(vm, host, const AlertSample(cpuPercent: 95), to: 130000);
      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 140000);
      await fire(vm, host, const AlertSample(cpuPercent: 10), nowMs: 150000);
      await settle();

      final rows = await repo.getAlertHistory();
      expect(
        rows.length,
        lessThanOrEqualTo(10),
        reason: 'the cap must bite on insert, not merely be stored in settings',
      );
      vm.dispose();
    });

    test('the newest rows are the ones kept', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      await setLimit(10);
      await seedHistory(id, 40);
      final vm = await boot();

      await vm.applyHistoryRetention();

      final rows = await repo.getAlertHistory();
      expect(rows.length, 10);
      // Seeded historyTime ascends with the index, so the survivors must be the highest.
      final times = rows.map((r) => r.historyTime).toList()..sort();
      expect(times.first, greaterThanOrEqualTo(1030));
      vm.dispose();
    });

    test('each host keeps its own allowance', () async {
      // A per-host cap, not a global one: a noisy host must not evict a quiet host's archive.
      final a = await repo.insertServer(server(name: 'a'));
      final b = await repo.insertServer(server(name: 'b'));
      await setLimit(10);
      await seedHistory(a, 30, name: 'a');
      await seedHistory(b, 5, name: 'b');
      final vm = await boot();

      await vm.applyHistoryRetention();

      final rows = await repo.getAlertHistory();
      expect(rows.where((r) => r.serverId == a).length, 10);
      expect(
        rows.where((r) => r.serverId == b).length,
        5,
        reason: 'a host under its limit must not be trimmed',
      );
      vm.dispose();
    });

    test('a history already within the limit is left alone', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      await setLimit(50);
      await seedHistory(id, 12);
      final vm = await boot();

      await vm.applyHistoryRetention();

      expect((await repo.getAlertHistory()).length, 12);
      vm.dispose();
    });
  });
}
