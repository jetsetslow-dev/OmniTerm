import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'server_dao.g.dart';

/// Hosts and their telemetry history, ported from `ServerDao` and `MetricHistoryDao` in
/// `data/Daos.kt`.
@DriftAccessor(tables: [Servers, MetricHistory])
class ServerDao extends DatabaseAccessor<AppDatabase> with _$ServerDaoMixin {
  ServerDao(super.db);

  // ── servers ────────────────────────────────────────────────────────────────

  Stream<List<Server>> watchAllServers() =>
      (select(servers)..orderBy([(s) => OrderingTerm.asc(s.name)])).watch();

  Future<List<Server>> getAllServers() =>
      (select(servers)..orderBy([(s) => OrderingTerm.asc(s.name)])).get();

  Future<Server?> getServerById(int id) =>
      (select(servers)..where((s) => s.id.equals(id))).getSingleOrNull();

  Future<Server?> getServerByName(String name) =>
      (select(servers)..where((s) => s.name.equals(name))..limit(1)).getSingleOrNull();

  Future<int> insertServer(ServersCompanion server) =>
      into(servers).insert(server, mode: InsertMode.replace);

  Future<bool> updateServer(Server server) => update(servers).replace(server);

  /// Clears every host's live connection state.
  ///
  /// Run at startup: a status persisted from the previous run is a lie until re-probed, and showing
  /// a stale "online" invites the user to act on a host that may be unreachable.
  Future<void> resetAllConnectionStates() => (update(servers)).write(
        const ServersCompanion(
          status: Value('offline'),
          healthScore: Value(0),
          lastLatency: Value(0),
          authStatus: Value('unknown'),
          authError: Value(null),
        ),
      );

  Future<void> updateConnectionState(int id, String status, int health, int latency) =>
      (update(servers)..where((s) => s.id.equals(id))).write(
        ServersCompanion(
          status: Value(status),
          healthScore: Value(health),
          lastLatency: Value(latency),
        ),
      );

  /// Auth state is tracked separately from TCP reachability: a host can be reachable yet reject the
  /// credentials, and metrics are only shown when authStatus is "ok".
  Future<void> updateAuthState(int id, String authStatus, String? authError) =>
      (update(servers)..where((s) => s.id.equals(id))).write(
        ServersCompanion(authStatus: Value(authStatus), authError: Value(authError)),
      );

  Future<void> deleteServerById(int serverId) =>
      (delete(servers)..where((s) => s.id.equals(serverId))).go();

  Future<void> deleteServersExcept(List<int> keepIds) =>
      (delete(servers)..where((s) => s.id.isNotIn(keepIds))).go();

  // ── metric history ─────────────────────────────────────────────────────────

  Stream<List<MetricHistoryRow>> watchMetricsForServer(int serverId) =>
      (select(metricHistory)
            ..where((m) => m.serverId.equals(serverId))
            ..orderBy([(m) => OrderingTerm.asc(m.timestamp)]))
          .watch();

  Future<List<MetricHistoryRow>> getMetricsForServer(int serverId) =>
      (select(metricHistory)
            ..where((m) => m.serverId.equals(serverId))
            ..orderBy([(m) => OrderingTerm.asc(m.timestamp)]))
          .get();

  Future<List<MetricHistoryRow>> getMetricsSince(int serverId, int since) =>
      (select(metricHistory)
            ..where((m) => m.serverId.equals(serverId) & m.timestamp.isBiggerOrEqualValue(since))
            ..orderBy([(m) => OrderingTerm.asc(m.timestamp)]))
          .get();

  Future<MetricHistoryRow?> getLatestMetricForServer(int serverId) =>
      (select(metricHistory)
            ..where((m) => m.serverId.equals(serverId))
            ..orderBy([(m) => OrderingTerm.desc(m.timestamp)])
            ..limit(1))
          .getSingleOrNull();

  /// The newest sample per host, in one round trip.
  ///
  /// Kept as raw SQL rather than rebuilt with the query builder, because the shape is deliberate:
  /// an inner join on `MAX(timestamp)` grouped by server, then a `MAX(id)` tie-break for two samples
  /// written in the same millisecond. Without the tie-break a host with a racing manual + periodic
  /// probe returns two rows and the dashboard flickers between them.
  ///
  /// This is also the query the `(serverId, timestamp)` index exists for — unindexed it degrades to
  /// repeated full scans whose cost tracks retained history, not fleet size (measured at 150k rows:
  /// 469s → 0.008s).
  Future<List<MetricHistoryRow>> getLatestMetricsForAllServers() {
    return customSelect(
      '''
      SELECT metric.* FROM metric_history AS metric
      INNER JOIN (
          SELECT serverId, MAX(timestamp) AS latestTimestamp
          FROM metric_history
          GROUP BY serverId
      ) AS latest
          ON metric.serverId = latest.serverId
          AND metric.timestamp = latest.latestTimestamp
      WHERE metric.id = (
          SELECT MAX(tie.id) FROM metric_history AS tie
          WHERE tie.serverId = metric.serverId
              AND tie.timestamp = metric.timestamp
      )
      ''',
      readsFrom: {metricHistory},
    ).map((row) => metricHistory.map(row.data)).get();
  }

  Future<int> insertMetric(MetricHistoryCompanion metric) =>
      into(metricHistory).insert(metric, mode: InsertMode.replace);

  /// Drop samples older than [cutoffTimestamp] — the retention window, 7 days by default.
  Future<void> pruneMetrics(int cutoffTimestamp) =>
      (delete(metricHistory)..where((m) => m.timestamp.isSmallerThanValue(cutoffTimestamp))).go();

  Future<void> deleteMetricsExceptServers(List<int> keepServerIds) =>
      (delete(metricHistory)..where((m) => m.serverId.isNotIn(keepServerIds))).go();

  Future<void> deleteMetricsForServer(int serverId) =>
      (delete(metricHistory)..where((m) => m.serverId.equals(serverId))).go();
}
