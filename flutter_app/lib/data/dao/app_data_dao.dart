import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'app_data_dao.g.dart';

/// The remaining stores: credentials, scripts, network endpoints, infra registry and settings.
///
/// Ported from `SshKeyDao`, `CredentialProfileDao`, `QuickScriptDao`, `PortForwardDao`,
/// `WolTargetDao`, `NetworkShareDao`, `StackRegistryDao`, `AppSettingDao` and
/// `PersistentSessionDao` in `data/Daos.kt`. Grouped rather than split into nine files: each is a
/// handful of plain CRUD methods, and nine one-screen files would obscure rather than clarify.
@DriftAccessor(
  tables: [
    SshKeys,
    CredentialProfiles,
    QuickScripts,
    PortForwards,
    WolTargets,
    NetworkShares,
    StackRegistry,
    AppSettings,
    PersistentSessions,
  ],
)
class AppDataDao extends DatabaseAccessor<AppDatabase> with _$AppDataDaoMixin {
  AppDataDao(super.db);

  // ── ssh keys ───────────────────────────────────────────────────────────────

  Stream<List<SshKey>> watchAllKeys() =>
      (select(sshKeys)..orderBy([(k) => OrderingTerm.asc(k.alias)])).watch();

  Future<List<SshKey>> getAllKeys() =>
      (select(sshKeys)..orderBy([(k) => OrderingTerm.asc(k.alias)])).get();

  Future<int> insertKey(SshKeysCompanion key) =>
      into(sshKeys).insert(key, mode: InsertMode.replace);

  Future<void> deleteKeyById(int id) => (delete(sshKeys)..where((k) => k.id.equals(id))).go();

  // ── credential profiles ────────────────────────────────────────────────────

  Stream<List<CredentialProfile>> watchAllProfiles() =>
      (select(credentialProfiles)..orderBy([(p) => OrderingTerm.asc(p.profileName)])).watch();

  Future<List<CredentialProfile>> getAllProfiles() =>
      (select(credentialProfiles)..orderBy([(p) => OrderingTerm.asc(p.profileName)])).get();

  Future<CredentialProfile?> getProfileById(int id) =>
      (select(credentialProfiles)
            ..where((p) => p.id.equals(id))
            ..limit(1))
          .getSingleOrNull();

  Future<int> insertProfile(CredentialProfilesCompanion profile) =>
      into(credentialProfiles).insert(profile, mode: InsertMode.replace);

  Future<void> deleteProfileById(int id) =>
      (delete(credentialProfiles)..where((p) => p.id.equals(id))).go();

  // ── quick scripts ──────────────────────────────────────────────────────────

  /// Ordered category → sortOrder → name, which is the order the picker renders.
  Stream<List<QuickScript>> watchAllScripts() =>
      (select(quickScripts)..orderBy([
            (s) => OrderingTerm.asc(s.category),
            (s) => OrderingTerm.asc(s.sortOrder),
            (s) => OrderingTerm.asc(s.name),
          ]))
          .watch();

  Future<List<QuickScript>> getAllScripts() =>
      (select(quickScripts)..orderBy([
            (s) => OrderingTerm.asc(s.category),
            (s) => OrderingTerm.asc(s.sortOrder),
            (s) => OrderingTerm.asc(s.name),
          ]))
          .get();

  Future<int> insertScript(QuickScriptsCompanion script) =>
      into(quickScripts).insert(script, mode: InsertMode.replace);

  Future<void> deleteScriptById(int id) =>
      (delete(quickScripts)..where((s) => s.id.equals(id))).go();

  // ── port forwards ──────────────────────────────────────────────────────────

  Stream<List<PortForward>> watchAllPortForwards() =>
      (select(portForwards)..orderBy([(p) => OrderingTerm.asc(p.name)])).watch();

  Future<List<PortForward>> getAllPortForwards() =>
      (select(portForwards)..orderBy([(p) => OrderingTerm.asc(p.name)])).get();

  Future<int> insertPortForward(PortForwardsCompanion pf) =>
      into(portForwards).insert(pf, mode: InsertMode.replace);

  Future<bool> updatePortForward(PortForward pf) => update(portForwards).replace(pf);

  Future<void> deletePortForwardById(int id) =>
      (delete(portForwards)..where((p) => p.id.equals(id))).go();

  Future<void> deletePortForwardsForServer(int serverId) =>
      (delete(portForwards)..where((p) => p.serverId.equals(serverId))).go();

  Future<void> deletePortForwardsExceptServers(List<int> keepServerIds) =>
      (delete(portForwards)..where((p) => p.serverId.isNotIn(keepServerIds))).go();

  // ── wake-on-lan targets ────────────────────────────────────────────────────

  Stream<List<WolTarget>> watchAllWolTargets() =>
      (select(wolTargets)..orderBy([(w) => OrderingTerm.asc(w.name)])).watch();

  Future<List<WolTarget>> getAllWolTargets() =>
      (select(wolTargets)..orderBy([(w) => OrderingTerm.asc(w.name)])).get();

  Future<int> insertWolTarget(WolTargetsCompanion target) =>
      into(wolTargets).insert(target, mode: InsertMode.replace);

  Future<void> deleteWolTargetById(int id) =>
      (delete(wolTargets)..where((w) => w.id.equals(id))).go();

  Future<void> updateWolLastWoken(int id, int timestamp) => (update(
    wolTargets,
  )..where((w) => w.id.equals(id))).write(WolTargetsCompanion(lastWokenTime: Value(timestamp)));

  // ── network shares ─────────────────────────────────────────────────────────

  Stream<List<NetworkShare>> watchAllShares() =>
      (select(networkShares)..orderBy([(s) => OrderingTerm.asc(s.name)])).watch();

  Future<List<NetworkShare>> getAllShares() =>
      (select(networkShares)..orderBy([(s) => OrderingTerm.asc(s.name)])).get();

  Future<NetworkShare?> getShareById(int id) =>
      (select(networkShares)
            ..where((s) => s.id.equals(id))
            ..limit(1))
          .getSingleOrNull();

  Future<int> insertShare(NetworkSharesCompanion share) =>
      into(networkShares).insert(share, mode: InsertMode.replace);

  Future<void> deleteShareById(int id) =>
      (delete(networkShares)..where((s) => s.id.equals(id))).go();

  // ── compose stack registry ─────────────────────────────────────────────────

  Future<List<StackRegistryRow>> getStacksForServer(int serverId) =>
      (select(stackRegistry)
            ..where((s) => s.serverId.equals(serverId))
            ..orderBy([(s) => OrderingTerm.asc(s.project)]))
          .get();

  /// Upsert on the (serverId, runtime, project) unique index, so re-seeing a stack refreshes its
  /// recorded working dir rather than duplicating it.
  Future<void> upsertStacks(List<StackRegistryCompanion> stacks) => batch((b) {
    for (final stack in stacks) {
      b.insert(stackRegistry, stack, mode: InsertMode.replace);
    }
  });

  Future<void> deleteStack(int serverId, String runtime, String project) =>
      (delete(stackRegistry)..where(
            (s) =>
                s.serverId.equals(serverId) & s.runtime.equals(runtime) & s.project.equals(project),
          ))
          .go();

  Future<void> deleteStacksForServer(int serverId) =>
      (delete(stackRegistry)..where((s) => s.serverId.equals(serverId))).go();

  // ── settings ───────────────────────────────────────────────────────────────

  Future<AppSetting?> getSetting(String key) =>
      (select(appSettings)
            ..where((s) => s.key.equals(key))
            ..limit(1))
          .getSingleOrNull();

  Stream<List<AppSetting>> watchAllSettings() => select(appSettings).watch();

  Future<List<AppSetting>> getAllSettings() => select(appSettings).get();

  Future<int> insertSetting(AppSettingsCompanion setting) =>
      into(appSettings).insert(setting, mode: InsertMode.replace);

  Future<void> deleteSetting(String key) =>
      (delete(appSettings)..where((s) => s.key.equals(key))).go();

  /// SFTP bookmarks are stored as one settings row per endpoint; a restore that keeps a subset of
  /// hosts must drop the orphans without touching any other setting.
  Future<void> deleteSftpBookmarksExcept(List<String> keepKeys) => (delete(
    appSettings,
  )..where((s) => s.key.like('sftp_bookmarks_%') & s.key.isNotIn(keepKeys))).go();

  // ── persistent (tmux) sessions ─────────────────────────────────────────────

  Future<List<PersistentSession>> getAllPersistentSessions() =>
      (select(persistentSessions)..orderBy([(s) => OrderingTerm.asc(s.createdAt)])).get();

  Future<int> upsertPersistentSession(PersistentSessionsCompanion session) =>
      into(persistentSessions).insert(session, mode: InsertMode.replace);

  Future<void> deletePersistentSession(String tmuxName) =>
      (delete(persistentSessions)..where((s) => s.tmuxName.equals(tmuxName))).go();

  Future<void> deletePersistentSessionsForServer(int serverId) =>
      (delete(persistentSessions)..where((s) => s.serverId.equals(serverId))).go();

  Future<void> deletePersistentSessionsExceptServers(List<int> keepServerIds) =>
      (delete(persistentSessions)..where((s) => s.serverId.isNotIn(keepServerIds))).go();
}
