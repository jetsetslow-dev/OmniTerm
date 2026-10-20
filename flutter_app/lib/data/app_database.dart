import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'dao/alerts_dao.dart';
import 'dao/app_data_dao.dart';
import 'dao/server_dao.dart';
import 'legacy_presets.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// The Room database file name. Must not change: on Android the Flutter app opens the *same file*
/// the shipped Kotlin app created, so a user updating from the native build keeps every host, key,
/// script and alert.
const kDatabaseFileName = 'omniterm_database';

/// The schema version the shipped Android app reached (`AppDatabase.kt`, `version = 22`).
///
/// This number is load-bearing for data continuity. Android's `SQLiteOpenHelper` — which Room is
/// built on — records the schema version in `PRAGMA user_version`, and that is the same pragma
/// Drift reads. So a database already migrated to Room v22 is seen by Drift as "already at version
/// 22" and no migration runs: the existing rows simply open.
///
/// (The README's mention of "schema v18" is stale; the exported schemas in
/// `app/schemas/com.jetsetslow.omniterm.data.AppDatabase/` run to 22.json.)
const kRoomSchemaVersion = 22;

@DriftDatabase(
  tables: [
    Servers,
    MetricHistory,
    SshKeys,
    CredentialProfiles,
    AlertRules,
    ActiveAlerts,
    AlertHistory,
    QuickScripts,
    WolTargets,
    NetworkShares,
    AppSettings,
    PersistentSessions,
    PortForwards,
    StackRegistry,
  ],
  daos: [ServerDao, AlertsDao, AppDataDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  /// In-memory instance for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => kRoomSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // Room's own chain, ported step for step. It normally never runs: a device coming from
      // the native app is already at 22, and a fresh install starts there. It matters only for
      // a user who installs the Flutter build directly over an older native build without
      // taking the intermediate Android update.
      //
      // Versions <= 7 predate schema export (several v5 builds shipped with differing
      // schemas), so Room fell back to a destructive wipe for those and so do we. From v8 on
      // every step is non-destructive.
      if (from <= 7) {
        await _recreateEverything(m);
        return;
      }
      await _runRoomMigrations(m, from);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _recreateEverything(Migrator m) async {
    for (final table in allTables) {
      await m.deleteTable(table.actualTableName);
    }
    await m.createAll();
  }

  /// Replays `AppDatabase.ALL_MIGRATIONS` from `data/AppDatabase.kt`.
  Future<void> _runRoomMigrations(Migrator m, int from) async {
    Future<void> step(int target, Future<void> Function() body) async {
      if (from < target) await body();
    }

    await step(9, () async {
      await customStatement('ALTER TABLE servers ADD COLUMN proxyKeyAlias TEXT');
    });

    // The backup-jobs feature was removed before it ever shipped a UI; drop its table.
    await step(10, () async {
      await customStatement('DROP TABLE IF EXISTS backup_jobs');
    });

    // Persistent (tmux-backed) sessions: per-server opt-in flag.
    await step(11, () async {
      await customStatement(
        'ALTER TABLE servers ADD COLUMN persistentSession INTEGER NOT NULL DEFAULT 0',
      );
    });

    // Track live tmux sessions so they can be re-offered after an app restart.
    await step(12, () async {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS persistent_sessions ('
        'tmuxName TEXT NOT NULL PRIMARY KEY, '
        'serverId INTEGER NOT NULL, '
        'serverName TEXT NOT NULL, '
        'createdAt INTEGER NOT NULL)',
      );
    });

    // WoL targets gain an optional host IP, used to ping for live online status.
    await step(13, () async {
      await customStatement(
        "ALTER TABLE wol_targets ADD COLUMN ipAddress TEXT NOT NULL DEFAULT ''",
      );
    });

    // Scripts and alert rules gain a free-text notes/comment field for documentation.
    await step(14, () async {
      await customStatement("ALTER TABLE quick_scripts ADD COLUMN notes TEXT NOT NULL DEFAULT ''");
      await customStatement("ALTER TABLE alert_rules ADD COLUMN notes TEXT NOT NULL DEFAULT ''");
    });

    // Saved LAN/network share profiles for SMB/FTP/SFTP/NFS/WebDAV discovery and access metadata.
    await step(15, () async {
      await customStatement(
        "ALTER TABLE credential_profiles ADD COLUMN groupName TEXT NOT NULL DEFAULT 'General'",
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS network_shares ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
        'name TEXT NOT NULL, '
        'protocol TEXT NOT NULL, '
        'address TEXT NOT NULL, '
        'port INTEGER NOT NULL, '
        'sharePath TEXT NOT NULL, '
        'workgroup TEXT NOT NULL, '
        'username TEXT NOT NULL, '
        'password TEXT NOT NULL, '
        'authProfileId INTEGER, '
        'anonymous INTEGER NOT NULL, '
        'notes TEXT NOT NULL, '
        'lastChecked INTEGER NOT NULL, '
        'lastStatus TEXT NOT NULL)',
      );
    });

    // WebDAV shares gain an explicit TLS flag; backfill from the old port heuristic (443/8443 were
    // treated as https) so existing shares keep connecting exactly as before.
    await step(16, () async {
      await customStatement(
        'ALTER TABLE network_shares ADD COLUMN useHttps INTEGER NOT NULL DEFAULT 0',
      );
      await customStatement(
        "UPDATE network_shares SET useHttps = 1 "
        "WHERE UPPER(protocol) = 'WEBDAV' AND port IN (443, 8443)",
      );
    });

    // Per-server SSH agent forwarding (ssh -A) opt-in + saved port-forward tunnels.
    await step(17, () async {
      await customStatement(
        'ALTER TABLE servers ADD COLUMN agentForwarding INTEGER NOT NULL DEFAULT 0',
      );
      await customStatement(
        'CREATE TABLE IF NOT EXISTS port_forwards ('
        'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
        'serverId INTEGER NOT NULL, '
        'name TEXT NOT NULL, '
        "kind TEXT NOT NULL DEFAULT 'local', "
        "bindHost TEXT NOT NULL DEFAULT '127.0.0.1', "
        'bindPort INTEGER NOT NULL, '
        "destHost TEXT NOT NULL DEFAULT '', "
        'destPort INTEGER NOT NULL DEFAULT 0, '
        'autoStart INTEGER NOT NULL DEFAULT 0)',
      );
    });

    // App-side registry of compose stacks, so a stack downed via `compose down` (containers and
    // networks removed — the daemon keeps no record) can still be listed and brought up.
    await step(18, () async {
      await customStatement(
        'CREATE TABLE IF NOT EXISTS stack_registry ('
        'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
        'serverId INTEGER NOT NULL, '
        'runtime TEXT NOT NULL, '
        'project TEXT NOT NULL, '
        'workingDir TEXT NOT NULL, '
        'configFiles TEXT NOT NULL, '
        'lastSeenAt INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS index_stack_registry_serverId_runtime_project '
        'ON stack_registry (serverId, runtime, project)',
      );
    });

    // One rule can have one live incident per concrete host. Keep the newest legacy row before
    // enforcing that identity; older builds could race manual and periodic telemetry probes.
    await step(19, () async {
      await customStatement(
        'DELETE FROM active_alerts WHERE id NOT IN ('
        'SELECT MAX(id) FROM active_alerts GROUP BY ruleId, serverId)',
      );
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS index_active_alerts_ruleId_serverId '
        'ON active_alerts (ruleId, serverId)',
      );
    });

    await step(20, _migrate19To20);

    // Temperature is optional because many VMs, containers, and remote OSes expose no sensor.
    await step(21, () async {
      await customStatement('ALTER TABLE metric_history ADD COLUMN cpuTemperatureC REAL');
    });

    // metric_history was never indexed, so every widget/monitoring read grouped and re-probed it
    // with full scans whose cost tracks retained history (7 days by default), not fleet size. Past
    // the widget's 8s load budget that turned into a stuck "Saving…" during widget configuration.
    // Measured at 150k rows: 469s -> 0.008s.
    await step(22, () async {
      await customStatement(
        'CREATE INDEX IF NOT EXISTS index_metric_history_serverId_timestamp '
        'ON metric_history (serverId, timestamp)',
      );
    });
  }

  /// Preset rows get a stable presetKey so the "default presets" toggles can remove exactly what
  /// they seeded even after the user edits one.
  ///
  /// Back-stamping is deliberately gated by the corresponding setting: a matching name/category or
  /// fleet-wide metric is not proof that a row belongs to OmniTerm when that preset family was
  /// disabled.
  Future<void> _migrate19To20() async {
    await customStatement('ALTER TABLE quick_scripts ADD COLUMN presetKey TEXT');
    await customStatement('ALTER TABLE alert_rules ADD COLUMN presetKey TEXT');

    // "Backgrounded since" for saved tmux sessions. Existing rows have never been observed being
    // backgrounded, so seed them from createdAt rather than "now", which would falsely show every
    // restored session as just-backgrounded.
    await customStatement(
      'ALTER TABLE persistent_sessions ADD COLUMN backgroundedAt INTEGER NOT NULL DEFAULT 0',
    );
    await customStatement(
      'UPDATE persistent_sessions SET backgroundedAt = createdAt WHERE backgroundedAt = 0',
    );

    // Fleet presets used to be on by default without persisting a setting. Preserve that state only
    // when a recognisable legacy fleet row exists. A stored false value wins because INSERT OR
    // IGNORE never overwrites the user's choice.
    final fleetNames = kLegacyScriptPresets
        .where((preset) => preset.familySetting == 'fleet_presets')
        .map((preset) => "'${preset.name.replaceAll("'", "''")}'")
        .join(',');
    await customStatement(
      'INSERT OR IGNORE INTO app_settings (`key`, value) '
      "SELECT 'fleet_presets', 'true' WHERE EXISTS ("
      "SELECT 1 FROM quick_scripts WHERE category = 'Fleet' AND name IN ($fleetNames))",
    );

    for (final preset in kLegacyScriptPresets) {
      await customStatement(
        'UPDATE quick_scripts SET presetKey = ? '
        'WHERE presetKey IS NULL AND name = ? AND category = ? '
        "AND EXISTS (SELECT 1 FROM app_settings WHERE `key` = ? AND value = 'true')",
        [preset.key, preset.name, preset.category, preset.familySetting],
      );
    }

    for (final preset in kLegacyRulePresets) {
      await customStatement(
        'UPDATE alert_rules SET presetKey = ? '
        'WHERE presetKey IS NULL AND serverId = 0 AND metricName = ? '
        "AND mountPoint = '/' AND thresholdValue = ? AND severity = ? "
        "AND triggerWindow = '5m' AND enabled = 1 AND notes = '' "
        'AND EXISTS (SELECT 1 FROM app_settings '
        "WHERE `key` = 'alert_presets' AND value = 'true')",
        [preset.key, preset.metric, preset.threshold, preset.severity],
      );
    }
  }
}

/// Opens the database at the location the native Android app used, so an updating user's data is
/// found rather than silently replaced by an empty database.
///
/// Room resolves its file through `Context.getDatabasePath(name)`, i.e. `<app data>/databases/`.
/// `path_provider` has no API for that directory, but it does expose the application *support*
/// directory (`<app data>/files` on Android), whose parent is the app data root — so the Room
/// directory is derivable from it. On iOS there is no legacy database to inherit; the same layout
/// is used purely for consistency.
QueryExecutor _open() {
  return LazyDatabase(() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(p.dirname(support.path), 'databases'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    if (Platform.isAndroid) {
      // Android's default temp location is not writable from the sqlite3 native library, so point
      // it at the app's own cache directory before any statement that spills to disk.
      //
      // The old `applyWorkaroundToOpenSqlite3OnOldAndroidVersions()` call is deliberately absent:
      // `sqlite3_flutter_libs` is a no-op stub as of 0.6.0+eol and is obsolete once `sqlite3` 3.x
      // bundles the library itself, so the obsolete compatibility package has been dropped.
      sqlite3.tempDirectory = (await getTemporaryDirectory()).path;
    }

    return NativeDatabase.createInBackground(File(p.join(dir.path, kDatabaseFileName)));
  });
}
