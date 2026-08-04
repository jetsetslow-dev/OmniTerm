import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'alerts_dao.g.dart';

/// Alert rules, live incidents and the resolved-incident archive, ported from `AlertRuleDao`,
/// `ActiveAlertDao` and `AlertHistoryDao` in `data/Daos.kt`.
///
/// Note the recurring `serverId != 0` guard in the "delete except these servers" queries: **rule 0
/// is the fleet-wide rule**, applying to every host, so it must survive a restore that keeps only a
/// subset of hosts. Dropping it would silently disable fleet-wide alerting.
@DriftAccessor(tables: [AlertRules, ActiveAlerts, AlertHistory])
class AlertsDao extends DatabaseAccessor<AppDatabase> with _$AlertsDaoMixin {
  AlertsDao(super.db);

  // ── rules ──────────────────────────────────────────────────────────────────

  Stream<List<AlertRule>> watchAllRules() => select(alertRules).watch();

  Future<List<AlertRule>> getAllRules() => select(alertRules).get();

  Future<List<AlertRule>> getRulesForServer(int serverId) =>
      (select(alertRules)..where((r) => r.serverId.equals(serverId))).get();

  Future<int> insertRule(AlertRulesCompanion rule) =>
      into(alertRules).insert(rule, mode: InsertMode.replace);

  Future<void> deleteRuleById(int id) => (delete(alertRules)..where((r) => r.id.equals(id))).go();

  Future<void> deleteRulesExceptServers(List<int> keepServerIds) => (delete(
    alertRules,
  )..where((r) => r.serverId.equals(0).not() & r.serverId.isNotIn(keepServerIds))).go();

  Future<void> deleteRulesForServer(int serverId) =>
      (delete(alertRules)..where((r) => r.serverId.equals(serverId))).go();

  // ── active incidents ───────────────────────────────────────────────────────

  Stream<List<ActiveAlert>> watchActiveAlerts() =>
      (select(activeAlerts)..orderBy([(a) => OrderingTerm.desc(a.triggeredTime)])).watch();

  Future<List<ActiveAlert>> getActiveAlerts() =>
      (select(activeAlerts)..orderBy([(a) => OrderingTerm.desc(a.triggeredTime)])).get();

  /// Replace-on-conflict is what enforces one live incident per (rule, host): the unique index makes
  /// a re-trigger update the existing row rather than accumulating duplicates.
  Future<int> insertAlert(ActiveAlertsCompanion alert) =>
      into(activeAlerts).insert(alert, mode: InsertMode.replace);

  Future<void> deleteAlert(int id) => (delete(activeAlerts)..where((a) => a.id.equals(id))).go();

  Future<void> setAcknowledged(int id, bool acknowledged) => (update(
    activeAlerts,
  )..where((a) => a.id.equals(id))).write(ActiveAlertsCompanion(acknowledged: Value(acknowledged)));

  Future<void> acknowledgeAll() =>
      update(activeAlerts).write(const ActiveAlertsCompanion(acknowledged: Value(true)));

  Future<void> muteAlert(int id, int mutedUntil) => (update(
    activeAlerts,
  )..where((a) => a.id.equals(id))).write(ActiveAlertsCompanion(mutedUntil: Value(mutedUntil)));

  Future<void> deleteAlertsExceptServers(List<int> keepServerIds) => (delete(
    activeAlerts,
  )..where((a) => a.serverId.equals(0).not() & a.serverId.isNotIn(keepServerIds))).go();

  Future<void> deleteAlertsForServer(int serverId) =>
      (delete(activeAlerts)..where((a) => a.serverId.equals(serverId))).go();

  // ── history ────────────────────────────────────────────────────────────────

  Stream<List<AlertHistoryRow>> watchAlertHistory() =>
      (select(alertHistory)..orderBy([(h) => OrderingTerm.desc(h.historyTime)])).watch();

  Future<List<AlertHistoryRow>> getAlertHistory() =>
      (select(alertHistory)..orderBy([(h) => OrderingTerm.desc(h.historyTime)])).get();

  Future<int> insertHistory(AlertHistoryCompanion history) =>
      into(alertHistory).insert(history, mode: InsertMode.replace);

  /// Keep only the newest [limit] entries for one host.
  ///
  /// Raw SQL because the counting subquery is the point: a row is deleted when at least [limit]
  /// *newer* rows exist for the same host, with `(historyTime, id)` as the ordering so two entries
  /// written in the same millisecond still have a deterministic winner. A naive
  /// `ORDER BY … LIMIT -1 OFFSET n` delete is not portable across SQLite builds.
  Future<void> pruneHistoryForServer(int serverId, int limit) => customUpdate(
    '''
        DELETE FROM alert_history
        WHERE serverId = ?
        AND (
            SELECT COUNT(*) FROM alert_history AS newer
            WHERE newer.serverId = alert_history.serverId
            AND (
                newer.historyTime > alert_history.historyTime
                OR (newer.historyTime = alert_history.historyTime AND newer.id > alert_history.id)
            )
        ) >= ?
        ''',
    variables: [Variable.withInt(serverId), Variable.withInt(limit)],
    updates: {alertHistory},
  );

  /// The same cap, applied independently to every host — so one noisy server cannot evict another's
  /// history.
  Future<void> pruneHistoryPerServer(int limit) => customUpdate(
    '''
        DELETE FROM alert_history
        WHERE (
            SELECT COUNT(*) FROM alert_history AS newer
            WHERE newer.serverId = alert_history.serverId
            AND (
                newer.historyTime > alert_history.historyTime
                OR (newer.historyTime = alert_history.historyTime AND newer.id > alert_history.id)
            )
        ) >= ?
        ''',
    variables: [Variable.withInt(limit)],
    updates: {alertHistory},
  );

  Future<void> clearHistory() => delete(alertHistory).go();

  Future<void> deleteHistoryExceptServers(List<int> keepServerIds) => (delete(
    alertHistory,
  )..where((h) => h.serverId.equals(0).not() & h.serverId.isNotIn(keepServerIds))).go();

  Future<void> deleteHistoryForServer(int serverId) =>
      (delete(alertHistory)..where((h) => h.serverId.equals(serverId))).go();
}
