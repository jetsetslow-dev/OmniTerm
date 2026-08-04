/// Drift ports of the Room `@Entity` classes in `data/Entities.kt`.
///
/// **These table definitions are a binary compatibility surface.** The Flutter app opens the same
/// `omniterm_database` file the shipped Android app created, so every table name, column name,
/// column order, SQL type, nullability and index must match Room's exported v22 schema
/// (`app/schemas/com.jetsetslow.omniterm.data.AppDatabase/22.json`) exactly. `build.yaml` sets
/// `case_from_dart_to_sql: preserve` so Drift does not snake_case these camelCase column names.
///
/// Note that Room's Kotlin default values are *not* SQL `DEFAULT` clauses — the exported DDL has
/// none. Defaults are therefore expressed as [clientDefault] (applied Dart-side on insert) rather
/// than [withDefault] (which would emit a `DEFAULT` and change the schema).
library;

import 'package:drift/drift.dart';

/// `servers` — a saved SSH host.
@DataClassName('Server')
class Servers extends Table {
  @override
  String get tableName => 'servers';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get host => text()();
  IntColumn get port => integer().clientDefault(() => 22)();
  TextColumn get username => text()();
  TextColumn get groupName => text().nullable().clientDefault(() => 'Default')();

  /// "Default", or one of the six named accents; resolved by `OmniColors.serverAccent`.
  TextColumn get serverColor => text().clientDefault(() => 'Default')();

  /// "password", "key", or "profile".
  TextColumn get authType => text().clientDefault(() => 'password')();
  TextColumn get authKeyAlias => text().nullable()();
  TextColumn get authPassword => text().nullable()();

  /// Optional sudo password for privileged actions; encrypted at the repository boundary.
  /// When set, it is fed to `sudo -S` via stdin so password-protected sudo works.
  TextColumn get sudoPassword => text().clientDefault(() => '')();
  IntColumn get authProfileId => integer().nullable()();
  TextColumn get notes => text().clientDefault(() => '')();

  /// Seconds.
  IntColumn get keepAlive => integer().clientDefault(() => 30)();
  BoolColumn get sshCompression => boolean().clientDefault(() => false)();

  /// When true, interactive shells launch inside a persistent tmux session so a dropped connection
  /// can reconnect and re-attach the SAME session (long-running commands keep running server-side).
  BoolColumn get persistentSession => boolean().clientDefault(() => false)();
  TextColumn get proxyCommand => text().clientDefault(() => '')();

  /// "none", "http", "socks5", or "ssh" (jump host).
  TextColumn get proxyType => text().clientDefault(() => 'none')();
  TextColumn get proxyHost => text().clientDefault(() => '')();
  IntColumn get proxyPort => integer().clientDefault(() => 0)();
  TextColumn get proxyUser => text().clientDefault(() => '')();
  TextColumn get proxyPassword => text().clientDefault(() => '')();

  /// Saved SSH key alias for jump-host auth (proxyType == "ssh"); null = password only.
  TextColumn get proxyKeyAlias => text().nullable()();

  /// Forward the SSH auth agent to this host (ssh -A) so onward hops can use our key.
  BoolColumn get agentForwarding => boolean().clientDefault(() => false)();
  IntColumn get healthScore => integer().clientDefault(() => 100)();
  IntColumn get lastLatency => integer().clientDefault(() => 0)();

  /// "online", "offline", or "connecting".
  TextColumn get status => text().clientDefault(() => 'offline')();

  /// Auth state is tracked separately from TCP reachability: a host can be "online" (port
  /// reachable) yet "failed" auth (wrong key/password). Metrics are only shown when
  /// authStatus == "ok". One of "unknown", "ok", "failed".
  TextColumn get authStatus => text().clientDefault(() => 'unknown')();
  TextColumn get authError => text().nullable()();
}

/// `metric_history` — retained per-host telemetry samples.
///
/// Indexed on (serverId, timestamp) because every read path groups or filters by exactly that
/// pair. Unindexed those become repeated full scans whose cost grows with retained history
/// (7 days by default) rather than with fleet size. Measured on an emulator at 150k rows:
/// 469s before the index, 0.008s after.
@DataClassName('MetricHistoryRow')
@TableIndex(name: 'index_metric_history_serverId_timestamp', columns: {#serverId, #timestamp})
class MetricHistory extends Table {
  @override
  String get tableName => 'metric_history';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  IntColumn get timestamp => integer()();
  RealColumn get cpuUsage => real()();
  RealColumn get ramUsage => real()();
  RealColumn get diskUsage => real()();
  IntColumn get latency => integer()();

  /// KB/s.
  RealColumn get networkIn => real()();

  /// KB/s.
  RealColumn get networkOut => real()();

  /// Null when the host exposes no readable thermal sensor.
  RealColumn get cpuTemperatureC => real().nullable()();
}

/// `ssh_keys` — imported private/public key pairs.
@DataClassName('SshKey')
class SshKeys extends Table {
  @override
  String get tableName => 'ssh_keys';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get alias => text()();

  /// "RSA", "Ed25519", or "ECDSA".
  TextColumn get keyType => text()();
  TextColumn get privateKey => text()();
  TextColumn get publicKey => text()();
  TextColumn get fingerprint => text()();
}

/// `credential_profiles` — reusable auth identities shared across hosts and shares.
@DataClassName('CredentialProfile')
class CredentialProfiles extends Table {
  @override
  String get tableName => 'credential_profiles';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get profileName => text()();
  TextColumn get username => text()();

  /// "password" or "key".
  TextColumn get authType => text()();
  TextColumn get password => text().nullable()();
  TextColumn get keyAlias => text().nullable()();
  TextColumn get groupName => text().clientDefault(() => 'General')();
}

/// `alert_rules` — user-defined thresholds evaluated against telemetry.
@DataClassName('AlertRule')
class AlertRules extends Table {
  @override
  String get tableName => 'alert_rules';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();

  /// "CPU Usage", "Memory Usage", "Disk Usage", "Network In", "Network Out", "Latency", or
  /// "Temperature" (which only evaluates on hosts that expose a thermal sensor).
  TextColumn get metricName => text()();
  TextColumn get mountPoint => text().clientDefault(() => '/')();
  RealColumn get thresholdValue => real()();

  /// "WARNING" or "CRITICAL".
  TextColumn get severity => text()();

  /// "2m", "5m", "10m", or "15m".
  TextColumn get triggerWindow => text().clientDefault(() => '5m')();
  BoolColumn get enabled => boolean().clientDefault(() => true)();

  /// Free-text note documenting why this rule exists / what it watches for.
  TextColumn get notes => text().clientDefault(() => '')();

  /// Stable identity of the built-in preset this rule was seeded from (e.g. "alert.cpu"), or null
  /// for user-created rules. Survives threshold/severity edits, so the default-rules toggle can
  /// delete exactly what it seeded instead of matching on mutable content.
  TextColumn get presetKey => text().nullable()();
}

/// `active_alerts` — currently firing incidents.
///
/// One rule can have one live incident per concrete host, enforced by a unique index; older builds
/// could race manual and periodic telemetry probes and produce duplicates.
@DataClassName('ActiveAlert')
@TableIndex(
  name: 'index_active_alerts_ruleId_serverId',
  columns: {#ruleId, #serverId},
  unique: true,
)
class ActiveAlerts extends Table {
  @override
  String get tableName => 'active_alerts';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get ruleId => integer()();
  IntColumn get serverId => integer()();
  TextColumn get metricName => text()();
  RealColumn get currentValue => real()();
  RealColumn get thresholdValue => real()();
  TextColumn get severity => text()();
  IntColumn get triggeredTime => integer()();
  BoolColumn get acknowledged => boolean().clientDefault(() => false)();

  /// Timestamp; 0 if not muted.
  IntColumn get mutedUntil => integer().clientDefault(() => 0)();
}

/// `alert_history` — resolved/acknowledged incident archive.
@DataClassName('AlertHistoryRow')
@TableIndex(name: 'index_alert_history_activeAlertId', columns: {#activeAlertId}, unique: true)
class AlertHistory extends Table {
  @override
  String get tableName => 'alert_history';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get activeAlertId => integer()();
  IntColumn get serverId => integer()();
  TextColumn get serverName => text()();
  TextColumn get metricName => text()();
  RealColumn get currentValue => real()();
  RealColumn get thresholdValue => real()();
  TextColumn get severity => text()();
  IntColumn get triggeredTime => integer()();
  IntColumn get historyTime => integer()();
  TextColumn get status => text()();
}

/// `quick_scripts` — saved commands for the Quick Scripts and Fleet Broadcast surfaces.
@DataClassName('QuickScript')
class QuickScripts extends Table {
  @override
  String get tableName => 'quick_scripts';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get emoji => text()();
  TextColumn get name => text()();
  TextColumn get command => text()();

  /// e.g. "cyan", "green", "amber", "red", "purple", "orange".
  TextColumn get color => text()();
  BoolColumn get longRunning => boolean().clientDefault(() => false)();
  TextColumn get category => text().clientDefault(() => 'General')();
  IntColumn get sortOrder => integer().clientDefault(() => 0)();
  BoolColumn get availableForQuick => boolean().clientDefault(() => true)();
  BoolColumn get availableForFleet => boolean().clientDefault(() => false)();
  TextColumn get targetOs => text().clientDefault(() => 'Any')();
  TextColumn get targetSystem => text().clientDefault(() => 'Any')();

  /// Free-text note documenting what this script does / caveats.
  TextColumn get notes => text().clientDefault(() => '')();

  /// Stable identity of the built-in preset this row was seeded from (e.g. "fleet.cpu"), or null
  /// for user-created scripts. Survives edits to the name/command, so the preset toggles can
  /// delete exactly what they seeded instead of matching on mutable content.
  TextColumn get presetKey => text().nullable()();
}

/// `wol_targets` — Wake-on-LAN destinations.
@DataClassName('WolTarget')
class WolTargets extends Table {
  @override
  String get tableName => 'wol_targets';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get macAddress => text()();
  TextColumn get broadcastIp => text().clientDefault(() => '192.168.1.255')();

  /// The host's own IP, used to ping it for live online status on the WoL screen. Optional: empty
  /// means "no status check" (older targets created before this field existed).
  TextColumn get ipAddress => text().clientDefault(() => '')();
  IntColumn get port => integer().clientDefault(() => 9)();
  TextColumn get notes => text().clientDefault(() => '')();
  IntColumn get lastWokenTime => integer().clientDefault(() => 0)();
}

/// `network_shares` — saved SMB/FTP/SFTP/NFS/WebDAV endpoints.
@DataClassName('NetworkShare')
class NetworkShares extends Table {
  @override
  String get tableName => 'network_shares';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// "SMB", "FTP", "SFTP", "NFS", "WEBDAV", or "CUSTOM".
  TextColumn get protocol => text().clientDefault(() => 'SMB')();
  TextColumn get address => text()();
  IntColumn get port => integer().clientDefault(() => 445)();
  TextColumn get sharePath => text().clientDefault(() => '')();
  TextColumn get workgroup => text().clientDefault(() => '')();
  TextColumn get username => text().clientDefault(() => '')();
  TextColumn get password => text().clientDefault(() => '')();
  IntColumn get authProfileId => integer().nullable()();
  BoolColumn get anonymous => boolean().clientDefault(() => true)();

  /// WebDAV only: send requests over TLS. Explicit, not inferred from the port — Basic auth over
  /// plain http on a nonstandard TLS port (e.g. Synology 5006) would leak credentials.
  BoolColumn get useHttps => boolean().clientDefault(() => false)();
  TextColumn get notes => text().clientDefault(() => '')();
  IntColumn get lastChecked => integer().clientDefault(() => 0)();
  TextColumn get lastStatus => text().clientDefault(() => 'unknown')();
}

/// `app_settings` — the key/value store backing every user preference.
@DataClassName('AppSetting')
class AppSettings extends Table {
  @override
  String get tableName => 'app_settings';

  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// `persistent_sessions` — live tmux sessions to re-offer after an app restart.
///
/// One row per live tmux session the app created; the [tmuxName] is how a reconnect re-attaches the
/// exact session. Pure runtime/device state — deliberately NOT included in backup/restore.
@DataClassName('PersistentSession')
class PersistentSessions extends Table {
  @override
  String get tableName => 'persistent_sessions';

  TextColumn get tmuxName => text()();
  IntColumn get serverId => integer()();
  TextColumn get serverName => text()();
  IntColumn get createdAt => integer()();

  /// When this session was most recently left running in the background. Unlike [createdAt] —
  /// which dates the tmux session itself and survives resume/background cycles — this restarts
  /// every time the user backgrounds the session again, so "backgrounded since" answers "how long
  /// has it been sitting there since I last used it?".
  IntColumn get backgroundedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {tmuxName};
}

/// `port_forwards` — saved SSH tunnels.
///
/// [kind] is "local" (-L), "remote" (-R), or "dynamic" (-D SOCKS). For local/remote, [bindPort] is
/// the listening port and [destHost]:[destPort] the far endpoint. For dynamic, only [bindPort] (the
/// local SOCKS port) is used. [serverId] is the SSH host the tunnel runs over. Tunnels are
/// started/stopped at runtime; this row just persists the definition.
@DataClassName('PortForward')
class PortForwards extends Table {
  @override
  String get tableName => 'port_forwards';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  TextColumn get name => text()();
  TextColumn get kind => text().clientDefault(() => 'local')();
  TextColumn get bindHost => text().clientDefault(() => '127.0.0.1')();
  IntColumn get bindPort => integer()();
  TextColumn get destHost => text().clientDefault(() => '')();
  IntColumn get destPort => integer().clientDefault(() => 0)();
  BoolColumn get autoStart => boolean().clientDefault(() => false)();
}

/// `stack_registry` — app-side registry of compose stacks OmniTerm has seen on a host.
///
/// `compose down` removes a stack's containers AND networks, leaving the container daemon with no
/// record the project ever existed (`docker compose ls` is container-derived too — Compose keeps no
/// server-side project registry). Rows are upserted every time a stack is visible in `ps -a`, so a
/// downed stack can still be listed and brought back UP from its recorded working dir + config
/// files. Rows leave only via the user's explicit Forget. A stack downed before OmniTerm ever saw
/// it up cannot be listed — there was nothing to record.
@DataClassName('StackRegistryRow')
@TableIndex(
  name: 'index_stack_registry_serverId_runtime_project',
  columns: {#serverId, #runtime, #project},
  unique: true,
)
class StackRegistry extends Table {
  @override
  String get tableName => 'stack_registry';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();

  /// "docker" | "podman" — a stack is owned by exactly one runtime.
  TextColumn get runtime => text()();

  /// Compose project name (the `-p` flag).
  TextColumn get project => text()();

  /// `com.docker.compose.project.working_dir` (or the first config file's parent).
  TextColumn get workingDir => text()();

  /// `com.docker.compose.project.config_files`, comma-separated.
  TextColumn get configFiles => text()();
  IntColumn get lastSeenAt => integer()();
}
