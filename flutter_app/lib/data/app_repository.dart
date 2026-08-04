import 'package:drift/drift.dart';

import '../platform/secret_store.dart';
import 'app_database.dart';

/// The single boundary between the database and everything above it, ported from
/// `data/AppRepository.kt`.
///
/// **Its most important job is credential hygiene.** Every secret is encrypted on the way in and
/// decrypted on the way out, in exactly one place: no plaintext ever reaches the database, and no
/// ciphertext ever reaches the UI. Scattering that across call sites is how a password eventually
/// gets written in the clear, so the ViewModels deliberately have no access to `SecretStore`.
///
/// Kotlin's `Flow` becomes `Stream`, and because decryption is asynchronous in Dart the decrypting
/// streams use `asyncMap` rather than `map`.
class AppRepository {
  AppRepository(this._db, SecretStore? secrets)
      : _secrets = secrets ??
            SecretStore(
              // Persisting the upgrade is what makes the §7.10 legacy migration happen *once* per
              // value instead of on every read. Fire-and-forget: a failed write simply means the
              // value is upgraded again next time, never that the secret is lost.
              onUpgraded: (legacy, upgraded) {},
            );

  final AppDatabase _db;
  SecretStore _secrets;

  /// Settings whose value is a secret. Everything else is stored in the clear — encrypting the
  /// theme name would only make it unreadable to no benefit.
  static const secureSettingKeys = {'app_pin'};

  /// Rebinds the secret store once the platform bridge is available, wiring the write-back that
  /// persists a §7.10 legacy upgrade.
  void attachSecretStore(SecretStore secrets) => _secrets = secrets;

  Future<T> inTransaction<T>(Future<T> Function() action) => _db.transaction(action);

  // ── §7.10 legacy credential migration ──────────────────────────────────────

  /// Re-encrypts every credential the Kotlin app wrote (`enc:v1:`) under the Dart key (`enc:v2:`).
  ///
  /// Returns the number of values upgraded, so a caller can log a one-line summary.
  ///
  /// Deliberately operates on the **raw, still-encrypted** rows rather than reading through the
  /// decrypting accessors and writing back. Those accessors map an unreadable secret to null or the
  /// empty string, so a read-then-write pass would overwrite exactly the values this migration
  /// exists to save. Here a field that cannot be read is left byte-identical on disk: a later OS or
  /// app version may still recover it, whereas an overwrite is final.
  ///
  /// Idempotent, and cheap to re-run: a value already tagged `enc:v2:` is skipped without touching
  /// the platform channel. It is safe to call on every launch.
  Future<int> migrateLegacySecrets() async {
    var upgraded = 0;

    /// Returns the upgraded ciphertext, or [current] unchanged when it cannot be read.
    Future<String?> lift(String? current) async {
      if (current == null || !SecretStore.isLegacyEncrypted(current)) return current;
      final next = await _secrets.upgradeLegacy(current);
      if (next == null) return current;
      upgraded++;
      return next;
    }

    for (final server in await _db.serverDao.getAllServers()) {
      final authPassword = await lift(server.authPassword);
      final sudoPassword = await lift(server.sudoPassword) ?? server.sudoPassword;
      final proxyPassword = await lift(server.proxyPassword) ?? server.proxyPassword;
      if (authPassword == server.authPassword &&
          sudoPassword == server.sudoPassword &&
          proxyPassword == server.proxyPassword) {
        continue;
      }
      await _db.serverDao.updateServer(server.copyWith(
        authPassword: Value(authPassword),
        sudoPassword: sudoPassword,
        proxyPassword: proxyPassword,
      ));
    }

    for (final key in await _db.appDataDao.getAllKeys()) {
      final privateKey = await lift(key.privateKey) ?? key.privateKey;
      if (privateKey == key.privateKey) continue;
      await _db.appDataDao.insertKey(key.copyWith(privateKey: privateKey).toCompanion(false));
    }

    for (final profile in await _db.appDataDao.getAllProfiles()) {
      final password = await lift(profile.password);
      if (password == profile.password) continue;
      await _db.appDataDao
          .insertProfile(profile.copyWith(password: Value(password)).toCompanion(false));
    }

    for (final share in await _db.appDataDao.getAllShares()) {
      final password = await lift(share.password) ?? share.password;
      if (password == share.password) continue;
      await _db.appDataDao.insertShare(share.copyWith(password: password).toCompanion(false));
    }

    for (final key in secureSettingKeys) {
      final row = await _db.appDataDao.getSetting(key);
      final value = await lift(row?.value);
      if (row == null || value == row.value) continue;
      await _db.appDataDao.insertSetting(
        AppSettingsCompanion.insert(key: key, value: value ?? ''),
      );
    }

    return upgraded;
  }

  // ── servers ────────────────────────────────────────────────────────────────

  Stream<List<Server>> get serversStream =>
      _db.serverDao.watchAllServers().asyncMap(_decryptServers);

  Future<List<Server>> getAllServers() async =>
      _decryptServers(await _db.serverDao.getAllServers());

  Future<Server?> getServerById(int id) async =>
      _decryptServerOrNull(await _db.serverDao.getServerById(id));

  Future<Server?> getServerByName(String name) async =>
      _decryptServerOrNull(await _db.serverDao.getServerByName(name));

  Future<int> insertServer(Server server) async {
    final encrypted = await _encryptServer(server);
    return _db.serverDao
        .insertServer(encrypted.toCompanion(false).copyWith(id: _newOrExisting(server.id)));
  }

  Future<void> updateServer(Server server) async =>
      _db.serverDao.updateServer(await _encryptServer(server));

  Future<void> updateConnectionState(int id, String status, int health, int latency) =>
      _db.serverDao.updateConnectionState(id, status, health, latency);

  Future<void> resetAllConnectionStates() => _db.serverDao.resetAllConnectionStates();

  Future<void> updateAuthState(int id, String authStatus, String? authError) =>
      _db.serverDao.updateAuthState(id, authStatus, authError);

  /// Remove a host and everything that referenced it, atomically.
  ///
  /// Transactional because a half-deleted host is worse than either outcome: orphaned alert rules
  /// keep firing against an id that no longer resolves to anything.
  Future<void> deleteServerAndDependents(int serverId) => _db.transaction(() async {
        await _db.serverDao.deleteMetricsForServer(serverId);
        await _db.alertsDao.deleteRulesForServer(serverId);
        await _db.alertsDao.deleteAlertsForServer(serverId);
        await _db.alertsDao.deleteHistoryForServer(serverId);
        await _db.appDataDao.deletePortForwardsForServer(serverId);
        await _db.appDataDao.deleteStacksForServer(serverId);
        await _db.appDataDao.deletePersistentSessionsForServer(serverId);
        await _db.appDataDao.deleteSetting('sftp_bookmarks_$serverId');
        await _db.serverDao.deleteServerById(serverId);
      });

  /// Keep only [keepServerIds] and drop every dependent row belonging to any other host.
  ///
  /// The sentinel matters: an empty `IN ()` list is handled inconsistently across SQLite versions,
  /// so "keep none" is made explicit with an id no auto-generated key can take. Fleet-wide rows
  /// (serverId 0) are preserved by the DAO's own `serverId != 0` guard, not by this list.
  Future<void> keepOnlyServers(Set<int> keepServerIds) async {
    final ids = keepServerIds.isEmpty ? <int>[_impossibleServerId] : keepServerIds.toList();
    await _db.transaction(() async {
      await _db.serverDao.deleteMetricsExceptServers(ids);
      await _db.alertsDao.deleteRulesExceptServers(ids);
      await _db.alertsDao.deleteAlertsExceptServers(ids);
      await _db.alertsDao.deleteHistoryExceptServers(ids);
      await _db.appDataDao.deletePortForwardsExceptServers(ids);
      await _db.appDataDao.deletePersistentSessionsExceptServers(ids);
      await _db.appDataDao
          .deleteSftpBookmarksExcept([for (final id in ids) 'sftp_bookmarks_$id']);
      await _db.serverDao.deleteServersExcept(ids);
    });
  }

  /// A server id is an auto-generated positive integer, so this can never match a real row.
  static const _impossibleServerId = -9223372036854775808;

  /// Id 0 means "new row, assign one".
  ///
  /// Room omits an `autoGenerate` primary key when it is 0, but Drift's `toCompanion(false)` carries
  /// it through — and SQLite happily accepts 0 as a literal rowid. Left as-is, every insert of a new
  /// record would write rowid 0 and, under `InsertMode.replace`, silently overwrite the previous
  /// one: adding a second host would delete the first.
  static Value<int> _newOrExisting(int id) =>
      id == 0 ? const Value.absent() : Value(id);

  // ── metrics ────────────────────────────────────────────────────────────────

  Stream<List<MetricHistoryRow>> watchMetricsForServer(int serverId) =>
      _db.serverDao.watchMetricsForServer(serverId);

  Future<List<MetricHistoryRow>> getMetricsForServer(int serverId) =>
      _db.serverDao.getMetricsForServer(serverId);

  Future<List<MetricHistoryRow>> getMetricsSince(int serverId, int since) =>
      _db.serverDao.getMetricsSince(serverId, since);

  Future<List<MetricHistoryRow>> getLatestMetricsForAllServers() =>
      _db.serverDao.getLatestMetricsForAllServers();

  Future<void> insertMetric(MetricHistoryCompanion metric) =>
      _db.serverDao.insertMetric(metric);

  Future<void> pruneMetrics(int cutoff) => _db.serverDao.pruneMetrics(cutoff);

  // ── ssh keys ───────────────────────────────────────────────────────────────

  Stream<List<SshKey>> get keysStream => _db.appDataDao.watchAllKeys().asyncMap(_decryptKeys);

  Future<List<SshKey>> getAllKeys() async => _decryptKeys(await _db.appDataDao.getAllKeys());

  Future<int> insertKey(SshKey key) async {
    final encrypted = await _encryptKey(key);
    return _db.appDataDao
        .insertKey(encrypted.toCompanion(false).copyWith(id: _newOrExisting(key.id)));
  }

  Future<void> deleteKeyById(int id) => _db.appDataDao.deleteKeyById(id);

  // ── credential profiles ────────────────────────────────────────────────────

  Stream<List<CredentialProfile>> get profilesStream =>
      _db.appDataDao.watchAllProfiles().asyncMap(_decryptProfiles);

  Future<void> deleteKey(SshKey key) => _db.appDataDao.deleteKeyById(key.id);

  Future<List<CredentialProfile>> getAllProfiles() async =>
      _decryptProfiles(await _db.appDataDao.getAllProfiles());

  Future<CredentialProfile?> getCredentialProfileById(int id) async {
    final profile = await _db.appDataDao.getProfileById(id);
    if (profile == null) return null;
    return profile.copyWith(password: Value(await _secrets.decrypt(profile.password)));
  }

  Future<void> deleteProfile(CredentialProfile profile) =>
      _db.appDataDao.deleteProfileById(profile.id);

  Future<int> insertProfile(CredentialProfile profile) async {
    final encrypted = await _encryptProfile(profile);
    return _db.appDataDao
        .insertProfile(encrypted.toCompanion(false).copyWith(id: _newOrExisting(profile.id)));
  }

  Future<void> deleteProfileById(int id) => _db.appDataDao.deleteProfileById(id);

  // ── alert rules, incidents, history ────────────────────────────────────────

  Stream<List<AlertRule>> get rulesStream => _db.alertsDao.watchAllRules();
  Future<List<AlertRule>> getAllRules() => _db.alertsDao.getAllRules();
  Future<List<AlertRule>> getRulesForServer(int serverId) =>
      _db.alertsDao.getRulesForServer(serverId);
  Future<int> insertRule(AlertRulesCompanion rule) => _db.alertsDao.insertRule(rule);
  Future<void> deleteRuleById(int id) => _db.alertsDao.deleteRuleById(id);

  Stream<List<ActiveAlert>> get activeAlertsStream => _db.alertsDao.watchActiveAlerts();
  Future<List<ActiveAlert>> getActiveAlerts() => _db.alertsDao.getActiveAlerts();
  Future<int> insertAlert(ActiveAlertsCompanion alert) => _db.alertsDao.insertAlert(alert);
  Future<void> deleteAlert(int id) => _db.alertsDao.deleteAlert(id);
  Future<void> setAcknowledged(int id, bool ack) => _db.alertsDao.setAcknowledged(id, ack);
  Future<void> acknowledgeAll() => _db.alertsDao.acknowledgeAll();
  Future<void> muteAlert(int id, int mutedUntil) => _db.alertsDao.muteAlert(id, mutedUntil);

  Stream<List<AlertHistoryRow>> get alertHistoryStream => _db.alertsDao.watchAlertHistory();
  Future<List<AlertHistoryRow>> getAlertHistory() => _db.alertsDao.getAlertHistory();
  Future<int> insertAlertHistory(AlertHistoryCompanion history) =>
      _db.alertsDao.insertHistory(history);

  /// The retention cap is clamped here rather than trusted from the caller: a 0 would delete the
  /// entire history on the next prune, and an unbounded value defeats the cap.
  Future<void> pruneAlertHistoryForServer(int serverId, int limit) =>
      _db.alertsDao.pruneHistoryForServer(serverId, limit.clamp(10, 100));

  Future<void> pruneAlertHistoryPerServer(int limit) =>
      _db.alertsDao.pruneHistoryPerServer(limit.clamp(10, 100));

  Future<void> clearAlertHistory() => _db.alertsDao.clearHistory();

  // ── scripts, WoL, tunnels, stacks ──────────────────────────────────────────

  Stream<List<QuickScript>> get scriptsStream => _db.appDataDao.watchAllScripts();
  Future<List<QuickScript>> getAllScripts() => _db.appDataDao.getAllScripts();
  Future<int> insertScript(QuickScriptsCompanion script) => _db.appDataDao.insertScript(script);
  Future<void> deleteScriptById(int id) => _db.appDataDao.deleteScriptById(id);

  Stream<List<WolTarget>> get wolTargetsStream => _db.appDataDao.watchAllWolTargets();
  Future<List<WolTarget>> getAllWolTargets() => _db.appDataDao.getAllWolTargets();
  Future<int> insertWolTarget(WolTargetsCompanion target) =>
      _db.appDataDao.insertWolTarget(target);
  Future<void> deleteWolTargetById(int id) => _db.appDataDao.deleteWolTargetById(id);

  Stream<List<PortForward>> get portForwardsStream => _db.appDataDao.watchAllPortForwards();
  Future<List<PortForward>> getAllPortForwards() => _db.appDataDao.getAllPortForwards();
  Future<int> insertPortForward(PortForwardsCompanion pf) =>
      _db.appDataDao.insertPortForward(pf);
  Future<void> updatePortForward(PortForward pf) => _db.appDataDao.updatePortForward(pf);
  Future<void> deletePortForwardById(int id) => _db.appDataDao.deletePortForwardById(id);

  Future<List<StackRegistryRow>> getStacksForServer(int serverId) =>
      _db.appDataDao.getStacksForServer(serverId);
  Future<void> upsertStacks(List<StackRegistryCompanion> stacks) =>
      _db.appDataDao.upsertStacks(stacks);
  Future<void> deleteStack(int serverId, String runtime, String project) =>
      _db.appDataDao.deleteStack(serverId, runtime, project);

  // ── network shares ─────────────────────────────────────────────────────────

  Stream<List<NetworkShare>> get networkSharesStream =>
      _db.appDataDao.watchAllShares().asyncMap(_decryptShares);

  Future<List<NetworkShare>> getAllNetworkShares() async =>
      _decryptShares(await _db.appDataDao.getAllShares());

  Future<int> insertNetworkShare(NetworkShare share) async {
    final encrypted = await _encryptShare(share);
    return _db.appDataDao
        .insertShare(encrypted.toCompanion(false).copyWith(id: _newOrExisting(share.id)));
  }

  Future<void> deleteNetworkShareById(int id) => _db.appDataDao.deleteShareById(id);

  // ── settings ───────────────────────────────────────────────────────────────

  Future<String?> getSetting(String key) async {
    final row = await _db.appDataDao.getSetting(key);
    if (row == null) return null;
    if (!secureSettingKeys.contains(key)) return row.value;
    return await _secrets.decrypt(row.value) ?? '';
  }

  Future<void> insertSetting(String key, String value) async {
    final stored =
        secureSettingKeys.contains(key) ? (await _secrets.encrypt(value) ?? '') : value;
    await _db.appDataDao
        .insertSetting(AppSettingsCompanion.insert(key: key, value: stored));
  }

  Future<void> deleteSetting(String key) => _db.appDataDao.deleteSetting(key);

  // ── persistent (tmux) sessions ─────────────────────────────────────────────

  Future<List<PersistentSession>> getPersistentSessions() =>
      _db.appDataDao.getAllPersistentSessions();
  Future<int> upsertPersistentSession(PersistentSessionsCompanion session) =>
      _db.appDataDao.upsertPersistentSession(session);
  Future<void> deletePersistentSession(String tmuxName) =>
      _db.appDataDao.deletePersistentSession(tmuxName);
  Future<void> deletePersistentSessionsForServer(int serverId) =>
      _db.appDataDao.deletePersistentSessionsForServer(serverId);

  // ── the encrypt/decrypt boundary ───────────────────────────────────────────
  //
  // `decrypt` returns null for a value that is not encrypted at all, which the `?? ''` fallbacks
  // below deliberately preserve: a field holding unrecognised content is surfaced as empty rather
  // than leaking whatever was stored there.

  Future<List<Server>> _decryptServers(List<Server> servers) async =>
      [for (final s in servers) await _decryptServer(s)];

  Future<Server?> _decryptServerOrNull(Server? server) async =>
      server == null ? null : _decryptServer(server);

  Future<Server> _decryptServer(Server server) async => server.copyWith(
        authPassword: Value(await _secrets.decrypt(server.authPassword)),
        sudoPassword: await _secrets.decrypt(server.sudoPassword) ?? '',
        proxyPassword: await _secrets.decrypt(server.proxyPassword) ?? '',
      );

  Future<Server> _encryptServer(Server server) async => server.copyWith(
        authPassword: Value(await _secrets.encrypt(server.authPassword)),
        sudoPassword: await _secrets.encrypt(server.sudoPassword) ?? '',
        proxyPassword: await _secrets.encrypt(server.proxyPassword) ?? '',
      );

  Future<List<SshKey>> _decryptKeys(List<SshKey> keys) async => [
        for (final k in keys)
          k.copyWith(privateKey: await _secrets.decrypt(k.privateKey) ?? ''),
      ];

  Future<SshKey> _encryptKey(SshKey key) async =>
      key.copyWith(privateKey: await _secrets.encrypt(key.privateKey) ?? '');

  Future<List<CredentialProfile>> _decryptProfiles(List<CredentialProfile> profiles) async => [
        for (final p in profiles)
          p.copyWith(password: Value(await _secrets.decrypt(p.password))),
      ];

  Future<CredentialProfile> _encryptProfile(CredentialProfile profile) async =>
      profile.copyWith(password: Value(await _secrets.encrypt(profile.password)));

  Future<List<NetworkShare>> _decryptShares(List<NetworkShare> shares) async => [
        for (final s in shares)
          s.copyWith(password: await _secrets.decrypt(s.password) ?? ''),
      ];

  Future<NetworkShare> _encryptShare(NetworkShare share) async =>
      share.copyWith(password: await _secrets.encrypt(share.password) ?? '');
}
