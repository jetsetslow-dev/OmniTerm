package com.jetsetslow.omniterm.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * A persistent (tmux-backed) terminal session that should be re-offered after an app restart.
 * One row per live tmux session the app created; the [tmuxName] is how a reconnect re-attaches the
 * exact session. Pure runtime/device state — deliberately NOT included in backup/restore.
 */
@Entity(tableName = "persistent_sessions")
data class PersistentSessionEntity(
    @PrimaryKey val tmuxName: String,
    val serverId: Int,
    val serverName: String,
    val createdAt: Long = System.currentTimeMillis(),
)

/**
 * App-side registry of compose stacks OmniTerm has seen on a host. `compose down` removes a
 * stack's containers AND networks, leaving the container daemon with no record the project ever
 * existed (`docker compose ls` is container-derived too — Compose keeps no server-side project
 * registry). Rows are upserted every time a stack is visible in `ps -a`, so a downed stack can
 * still be listed and brought back UP from its recorded working dir + config files. Rows leave
 * only via the user's explicit Forget. A stack downed before OmniTerm ever saw it up cannot be
 * listed — there was nothing to record.
 */
@Entity(
    tableName = "stack_registry",
    indices = [Index(value = ["serverId", "runtime", "project"], unique = true)],
)
data class StackRegistryEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val serverId: Int,
    val runtime: String,     // "docker" | "podman" — a stack is owned by exactly one runtime
    val project: String,     // compose project name (the -p flag)
    val workingDir: String,  // com.docker.compose.project.working_dir (or first config file's parent)
    val configFiles: String, // com.docker.compose.project.config_files, comma-separated
    val lastSeenAt: Long = System.currentTimeMillis(),
)

@Entity(tableName = "servers")
data class ServerEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val host: String,
    val port: Int = 22,
    val username: String,
    val groupName: String? = "Default",
    val serverColor: String = "Default", // Can be "Default", "Blue", "Red", "Green", "Purple", "Orange"
    val authType: String = "password", // "password", "key", "profile"
    val authKeyAlias: String? = null,
    val authPassword: String? = null,
    // Optional sudo password for privileged actions; encrypted at the repository boundary.
    // When set, it is fed to `sudo -S` via stdin so password-protected sudo works.
    val sudoPassword: String = "",
    val authProfileId: Int? = null,
    val notes: String = "",
    val keepAlive: Int = 30, // seconds
    val sshCompression: Boolean = false,
    // When true, interactive shells launch inside a persistent tmux session so a dropped connection
    // can reconnect and re-attach the SAME session (long-running commands keep running server-side).
    val persistentSession: Boolean = false,
    val proxyCommand: String = "",
    // Proxy used to reach the host. proxyType: "none", "http", "socks5", "ssh" (jump host).
    val proxyType: String = "none",
    val proxyHost: String = "",
    val proxyPort: Int = 0,
    val proxyUser: String = "",
    val proxyPassword: String = "",
    // Saved SSH key alias for jump-host auth (proxyType == "ssh"); null = password only.
    val proxyKeyAlias: String? = null,
    // Forward the SSH auth agent to this host (ssh -A) so onward hops can use our key.
    val agentForwarding: Boolean = false,
    val healthScore: Int = 100,
    val lastLatency: Int = 0,
    val status: String = "offline", // "online", "offline", "connecting"
    // Auth state is tracked separately from TCP reachability: a host can be "online"
    // (port reachable) yet "failed" auth (wrong key/password). Metrics are only shown
    // when authStatus == "ok".
    val authStatus: String = "unknown", // "unknown", "ok", "failed"
    val authError: String? = null
)

@Entity(tableName = "metric_history")
data class MetricHistoryEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val serverId: Int,
    val timestamp: Long,
    val cpuUsage: Float,
    val ramUsage: Float,
    val diskUsage: Float,
    val latency: Int,
    val networkIn: Float, // KB/s
    val networkOut: Float // KB/s
)

@Entity(tableName = "ssh_keys")
data class SshKeyEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val alias: String,
    val keyType: String, // "RSA", "Ed25519", "ECDSA"
    val privateKey: String,
    val publicKey: String,
    val fingerprint: String
)

@Entity(tableName = "credential_profiles")
data class CredentialProfileEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val profileName: String,
    val username: String,
    val authType: String, // "password", "key"
    val password: String? = null,
    val keyAlias: String? = null,
    val groupName: String = "General"
)

@Entity(tableName = "alert_rules")
data class AlertRuleEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val serverId: Int,
    val metricName: String, // "CPU Usage", "Memory Usage", "Disk Usage", "Network In", "Network Out", "Latency"
    val mountPoint: String = "/",
    val thresholdValue: Float,
    val severity: String, // "WARNING", "CRITICAL"
    val triggerWindow: String = "5m", // "2m", "5m", "10m", "15m"
    val enabled: Boolean = true,
    // Free-text note documenting why this rule exists / what it watches for.
    val notes: String = ""
)

@Entity(tableName = "active_alerts")
data class ActiveAlertEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val ruleId: Int,
    val serverId: Int,
    val metricName: String,
    val currentValue: Float,
    val thresholdValue: Float,
    val severity: String,
    val triggeredTime: Long,
    val acknowledged: Boolean = false,
    val mutedUntil: Long = 0L // timestamp, 0 if not muted
)

@Entity(
    tableName = "alert_history",
    indices = [Index(value = ["activeAlertId"], unique = true)]
)
data class AlertHistoryEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val activeAlertId: Int,
    val serverId: Int,
    val serverName: String,
    val metricName: String,
    val currentValue: Float,
    val thresholdValue: Float,
    val severity: String,
    val triggeredTime: Long,
    val historyTime: Long,
    val status: String
)

@Entity(tableName = "quick_scripts")
data class QuickScriptEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val emoji: String,
    val name: String,
    val command: String,
    val color: String, // e.g. "cyan", "green", "amber", "red", "purple", "orange"
    val longRunning: Boolean = false,
    val category: String = "General",
    val sortOrder: Int = 0,
    val availableForQuick: Boolean = true,
    val availableForFleet: Boolean = false,
    val targetOs: String = "Any",
    val targetSystem: String = "Any",
    // Free-text note documenting what this script does / caveats.
    val notes: String = ""
)

@Entity(tableName = "wol_targets")
data class WolTargetEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val macAddress: String,
    val broadcastIp: String = "192.168.1.255",
    // The host's own IP, used to ping it for live online status on the WoL screen. Optional: empty
    // means "no status check" (older targets created before this field existed).
    val ipAddress: String = "",
    val port: Int = 9,
    val notes: String = "",
    val lastWokenTime: Long = 0L
)

/**
 * A saved SSH port-forwarding tunnel. [kind] is "local" (-L), "remote" (-R), or "dynamic" (-D SOCKS).
 * For local/remote, [bindPort] is the listening port and [destHost]:[destPort] the far endpoint. For
 * dynamic, only [bindPort] (the local SOCKS port) is used. [serverId] is the SSH host the tunnel
 * runs over. Tunnels are started/stopped at runtime; this row just persists the definition.
 */
@Entity(tableName = "port_forwards")
data class PortForwardEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val serverId: Int,
    val name: String,
    val kind: String = "local",       // "local" | "remote" | "dynamic"
    val bindHost: String = "127.0.0.1",
    val bindPort: Int,
    val destHost: String = "",
    val destPort: Int = 0,
    val autoStart: Boolean = false,
)

@Entity(tableName = "network_shares")
data class NetworkShareEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    // "SMB", "FTP", "SFTP", "NFS", "WEBDAV", "CUSTOM"
    val protocol: String = "SMB",
    val address: String,
    val port: Int = 445,
    val sharePath: String = "",
    val workgroup: String = "",
    val username: String = "",
    val password: String = "",
    val authProfileId: Int? = null,
    val anonymous: Boolean = true,
    // WebDAV only: send requests over TLS. Explicit, not inferred from the port — Basic auth over
    // plain http on a nonstandard TLS port (e.g. Synology 5006) would leak credentials.
    val useHttps: Boolean = false,
    val notes: String = "",
    val lastChecked: Long = 0L,
    val lastStatus: String = "unknown"
)

@Entity(tableName = "app_settings")
data class AppSettingEntity(
    @PrimaryKey val key: String,
    val value: String
)
