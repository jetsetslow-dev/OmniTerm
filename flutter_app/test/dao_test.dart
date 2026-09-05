import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';

/// Exercises the DAOs against a real in-memory database, concentrating on the queries whose shape
/// is deliberate rather than the plain CRUD.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> addServer(String name) => db.serverDao.insertServer(
    ServersCompanion.insert(name: name, host: '10.0.0.1', username: 'root'),
  );

  Future<void> addMetric(int serverId, int timestamp, double cpu) => db.serverDao.insertMetric(
    MetricHistoryCompanion.insert(
      serverId: serverId,
      timestamp: timestamp,
      cpuUsage: cpu,
      ramUsage: 0,
      diskUsage: 0,
      latency: 0,
      networkIn: 0,
      networkOut: 0,
    ),
  );

  group('ServerDao', () {
    test('servers come back ordered by name', () async {
      await addServer('zulu');
      await addServer('alpha');
      await addServer('mike');
      expect((await db.serverDao.getAllServers()).map((s) => s.name), ['alpha', 'mike', 'zulu']);
    });

    test('lookup by id and name', () async {
      final id = await addServer('nas');
      expect((await db.serverDao.getServerById(id))?.name, 'nas');
      expect((await db.serverDao.getServerByName('nas'))?.id, id);
      expect(await db.serverDao.getServerByName('absent'), isNull);
    });

    test('resetAllConnectionStates clears every live field', () async {
      final id = await addServer('nas');
      await db.serverDao.updateConnectionState(id, 'online', 95, 12);
      await db.serverDao.updateAuthState(id, 'ok', null);

      await db.serverDao.resetAllConnectionStates();

      final server = (await db.serverDao.getServerById(id))!;
      // A status persisted from the previous run is a lie until re-probed.
      expect(server.status, 'offline');
      expect(server.healthScore, 0);
      expect(server.lastLatency, 0);
      expect(server.authStatus, 'unknown');
      expect(server.authError, isNull);
    });

    test('auth state is tracked independently of reachability', () async {
      final id = await addServer('nas');
      await db.serverDao.updateConnectionState(id, 'online', 100, 5);
      await db.serverDao.updateAuthState(id, 'failed', 'Auth fail');

      final server = (await db.serverDao.getServerById(id))!;
      expect(server.status, 'online', reason: 'the port is reachable');
      expect(server.authStatus, 'failed', reason: 'but the credentials are not accepted');
      expect(server.authError, 'Auth fail');
    });

    test('deleteServersExcept keeps only the listed ids', () async {
      final keep = await addServer('keep');
      await addServer('drop1');
      await addServer('drop2');
      await db.serverDao.deleteServersExcept([keep]);
      expect((await db.serverDao.getAllServers()).map((s) => s.name), ['keep']);
    });
  });

  group('getLatestMetricsForAllServers', () {
    test('returns the newest sample per host', () async {
      final a = await addServer('a');
      final b = await addServer('b');
      await addMetric(a, 100, 10);
      await addMetric(a, 300, 30);
      await addMetric(b, 200, 20);

      final latest = await db.serverDao.getLatestMetricsForAllServers();
      expect(latest, hasLength(2));
      expect(latest.firstWhere((m) => m.serverId == a).cpuUsage, 30);
      expect(latest.firstWhere((m) => m.serverId == b).cpuUsage, 20);
    });

    test('a same-millisecond tie yields exactly one row per host', () async {
      // Two samples written in the same millisecond is the real case: a manual refresh racing the
      // periodic poller. Without the MAX(id) tie-break both rows come back and the dashboard
      // flickers between them.
      final a = await addServer('a');
      await addMetric(a, 500, 11);
      await addMetric(a, 500, 22);

      final latest = await db.serverDao.getLatestMetricsForAllServers();
      expect(latest, hasLength(1));
      expect(latest.single.cpuUsage, 22, reason: 'the later-inserted row wins');
    });

    test('a host with no samples is simply absent', () async {
      await addServer('quiet');
      expect(await db.serverDao.getLatestMetricsForAllServers(), isEmpty);
    });
  });

  group('metric retention', () {
    test('pruneMetrics drops only samples older than the cutoff', () async {
      final a = await addServer('a');
      await addMetric(a, 100, 1);
      await addMetric(a, 500, 2);
      await db.serverDao.pruneMetrics(300);
      final rows = await db.serverDao.getMetricsForServer(a);
      expect(rows.map((r) => r.timestamp), [500]);
    });

    test('getMetricsSince is inclusive of the boundary', () async {
      final a = await addServer('a');
      await addMetric(a, 100, 1);
      await addMetric(a, 200, 2);
      expect((await db.serverDao.getMetricsSince(a, 200)).map((r) => r.timestamp), [200]);
    });
  });

  group('AlertsDao', () {
    Future<int> addRule(int serverId) => db.alertsDao.insertRule(
      AlertRulesCompanion.insert(
        serverId: serverId,
        metricName: 'CPU Usage',
        thresholdValue: 90,
        severity: 'CRITICAL',
      ),
    );

    Future<int> addAlert(int ruleId, int serverId, {int triggered = 0}) => db.alertsDao.insertAlert(
      ActiveAlertsCompanion.insert(
        ruleId: ruleId,
        serverId: serverId,
        metricName: 'CPU Usage',
        currentValue: 95,
        thresholdValue: 90,
        severity: 'CRITICAL',
        triggeredTime: triggered,
      ),
    );

    test('the fleet-wide rule (serverId 0) survives a partial restore', () async {
      // This is the guard the `serverId != 0` clause exists for: dropping rule 0 would silently
      // disable alerting for every host at once.
      await addRule(0);
      await addRule(7);
      await addRule(9);

      await db.alertsDao.deleteRulesExceptServers([7]);

      final remaining = (await db.alertsDao.getAllRules()).map((r) => r.serverId).toSet();
      expect(remaining, {0, 7});
    });

    test('one live incident per (rule, host)', () async {
      final rule = await addRule(1);
      await addAlert(rule, 1);
      await addAlert(rule, 1); // re-trigger
      expect(await db.alertsDao.getActiveAlerts(), hasLength(1));
    });

    test('the same rule on two hosts is two incidents', () async {
      final rule = await addRule(0);
      await addAlert(rule, 1);
      await addAlert(rule, 2);
      expect(await db.alertsDao.getActiveAlerts(), hasLength(2));
    });

    test('acknowledge and mute update in place', () async {
      final rule = await addRule(1);
      final id = await addAlert(rule, 1);
      await db.alertsDao.setAcknowledged(id, true);
      await db.alertsDao.muteAlert(id, 12345);

      final alert = (await db.alertsDao.getActiveAlerts()).single;
      expect(alert.acknowledged, isTrue);
      expect(alert.mutedUntil, 12345);
    });

    test('acknowledgeAll marks every incident', () async {
      final rule = await addRule(0);
      await addAlert(rule, 1);
      await addAlert(rule, 2);
      await db.alertsDao.acknowledgeAll();
      expect((await db.alertsDao.getActiveAlerts()).every((a) => a.acknowledged), isTrue);
    });

    test('active alerts are newest first', () async {
      final rule = await addRule(0);
      await addAlert(rule, 1, triggered: 100);
      await addAlert(rule, 2, triggered: 300);
      expect((await db.alertsDao.getActiveAlerts()).first.triggeredTime, 300);
    });
  });

  group('alert history pruning', () {
    Future<void> addHistory(int serverId, int time) => db.alertsDao.insertHistory(
      AlertHistoryCompanion.insert(
        activeAlertId: time,
        serverId: serverId,
        serverName: 'host$serverId',
        metricName: 'CPU Usage',
        currentValue: 95,
        thresholdValue: 90,
        severity: 'CRITICAL',
        triggeredTime: time,
        historyTime: time,
        status: 'RESOLVED',
      ),
    );

    test('keeps the newest N for one host', () async {
      for (var i = 1; i <= 5; i++) {
        await addHistory(1, i * 100);
      }
      await db.alertsDao.pruneHistoryForServer(1, 2);
      final times = (await db.alertsDao.getAlertHistory()).map((h) => h.historyTime).toList();
      expect(times, [500, 400]);
    });

    test(
      'the per-server cap is applied independently, so one noisy host cannot evict another',
      () async {
        for (var i = 1; i <= 4; i++) {
          await addHistory(1, i * 100);
        }
        await addHistory(2, 50);

        await db.alertsDao.pruneHistoryPerServer(2);

        final byServer = <int, int>{};
        for (final h in await db.alertsDao.getAlertHistory()) {
          byServer[h.serverId] = (byServer[h.serverId] ?? 0) + 1;
        }
        expect(byServer[1], 2);
        expect(byServer[2], 1, reason: 'the quiet host keeps its single entry');
      },
    );
  });

  group('AppDataDao', () {
    test('settings round-trip and delete', () async {
      await db.appDataDao.insertSetting(AppSettingsCompanion.insert(key: 'theme', value: 'amoled'));
      expect((await db.appDataDao.getSetting('theme'))?.value, 'amoled');
      await db.appDataDao.deleteSetting('theme');
      expect(await db.appDataDao.getSetting('theme'), isNull);
    });

    test('inserting an existing key replaces it', () async {
      await db.appDataDao.insertSetting(AppSettingsCompanion.insert(key: 'k', value: 'a'));
      await db.appDataDao.insertSetting(AppSettingsCompanion.insert(key: 'k', value: 'b'));
      expect((await db.appDataDao.getSetting('k'))?.value, 'b');
      expect(await db.appDataDao.getAllSettings(), hasLength(1));
    });

    test('deleteSftpBookmarksExcept touches only bookmark rows', () async {
      await db.appDataDao.insertSetting(
        AppSettingsCompanion.insert(key: 'sftp_bookmarks_1', value: 'a'),
      );
      await db.appDataDao.insertSetting(
        AppSettingsCompanion.insert(key: 'sftp_bookmarks_2', value: 'b'),
      );
      await db.appDataDao.insertSetting(AppSettingsCompanion.insert(key: 'theme', value: 'dark'));

      await db.appDataDao.deleteSftpBookmarksExcept(['sftp_bookmarks_1']);

      final keys = (await db.appDataDao.getAllSettings()).map((s) => s.key).toSet();
      expect(keys, {
        'sftp_bookmarks_1',
        'theme',
      }, reason: 'an unrelated setting must never be collateral damage');
    });

    test('quick scripts order by category, sortOrder, then name', () async {
      Future<void> add(String category, int order, String name) => db.appDataDao.insertScript(
        QuickScriptsCompanion.insert(
          emoji: '*',
          name: name,
          command: 'true',
          color: 'cyan',
          category: Value(category),
          sortOrder: Value(order),
        ),
      );

      await add('B', 0, 'first');
      await add('A', 5, 'later');
      await add('A', 1, 'earlier');

      expect((await db.appDataDao.getAllScripts()).map((s) => s.name), [
        'earlier',
        'later',
        'first',
      ]);
    });

    test('stack registry upserts on (server, runtime, project)', () async {
      Future<void> upsert(String workingDir) => db.appDataDao.upsertStacks([
        StackRegistryCompanion.insert(
          serverId: 1,
          runtime: 'docker',
          project: 'web',
          workingDir: workingDir,
          configFiles: 'compose.yml',
          lastSeenAt: 0,
        ),
      ]);

      await upsert('/old');
      await upsert('/new');

      final stacks = await db.appDataDao.getStacksForServer(1);
      expect(stacks, hasLength(1), reason: 're-seeing a stack must refresh, not duplicate');
      expect(stacks.single.workingDir, '/new');
    });

    test('persistent sessions are keyed by tmux name', () async {
      Future<void> upsert(String name, String server) => db.appDataDao.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: name,
          serverId: 1,
          serverName: server,
          createdAt: 0,
          backgroundedAt: 0,
        ),
      );

      await upsert('omni-1', 'old');
      await upsert('omni-1', 'new');
      final sessions = await db.appDataDao.getAllPersistentSessions();
      expect(sessions, hasLength(1));
      expect(sessions.single.serverName, 'new');

      await db.appDataDao.deletePersistentSession('omni-1');
      expect(await db.appDataDao.getAllPersistentSessions(), isEmpty);
    });
  });
}
