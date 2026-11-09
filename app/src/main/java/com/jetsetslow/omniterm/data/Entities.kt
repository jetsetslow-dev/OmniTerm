package com.jetsetslow.omniterm.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * A persistent (tmux-backed) terminal session that should be re-offered after an app restart.
 * One row per live tmux session the app created or attached to; the [tmuxName] is how a reconnect
 * re-attaches the exact session. Backups carry it with its host, so a restored phone offers the
 * same sessions to attach again; nothing connects until the user picks one.
 *
 * Keyed by host and name together: names the app generates are unique, but a session attached
 * from the host's own list is called whatever the user called it, and two hosts can each have a
 * "main" (or tmux's default "0").
 */
@Entity(tableName = "persistent_sessions", primaryKeys = ["serverId", "tmuxName"])
data class PersistentSessionEntity(
    val tmuxName: String,
    val serverId: Int,
    val serverName: String,
    val createdAt: Long = System.currentTimeMillis(),
    // When this session was most recently left running in the background. Unlike [createdAt] —
    // which dates the tmux session itself and survives resume/background cycles — this restarts
    // every time the user backgrounds the session again, so "backgrounded since" answers "how long
    // has it been sitting there since I last used it?".
    val backgroundedAt: Long = System.currentTimeMillis(),
    /**
     * The session was already running on the host and the user attached to it. OmniTerm leaves
     * its tmux options alone (its own sessions get mouse off and a history limit), because the
     * user's other tmux clients share them.
     */
    val adopted: Boolean = false,
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
    val serverColor: String = "Default", // "Default" or a name in OmniColors.namedColors; older rows' names are read through OmniColors.hostColorName
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
    val healthScore: Int = HEALTH_SCORE_UNKNOWN,
    val lastLatency: Int = 0,
    val status: String = "offline", // "online", "offline", "connecting"
    // Auth state is tracked separately from TCP reachability: a host can be "online"
    // (port reachable) yet "failed" auth (wrong key/password). Metrics are only shown
    // when authStatus == "ok".
    val authStatus: String = "unknown", // "unknown", "ok", "failed"
    val authError: String? = null,
    // The tunnel (tunnels.id) every connection to this host goes through, never falling back to a
    // direct connection; null connects directly. Switching it off and on uses one host both ways.
    val tunnelId: Int? = null,
    // The host's address through the tunnel when it differs from [host] (a Tailscale 100.x or
    // MagicDNS name), so [host] can stay the address for direct use; blank means the same address.
    val tunnelHost: String = "",
)

// Indexed on (serverId, timestamp) because every read path groups or filters by exactly that pair:
// getLatestMetricsForAllServers() groups by serverId to find MAX(timestamp), then re-probes the
// table per matched row to break ties. Unindexed those become repeated full scans, and the cost
// grows with retained history (7 days by default) rather than with fleet size. Measured on an
// emulator at 150k rows: 469s before the index, 0.008s after.
@Entity(
    tableName = "metric_history",
    indices = [Index(value = ["serverId", "timestamp"])],
)
data class MetricHistoryEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val serverId: Int,
    val timestamp: Long,
    val cpuUsage: Float,
    val ramUsage: Float,
    val diskUsage: Float,
    val latency: Int,
    val networkIn: Float, // KB/s
    val networkOut: Float, // KB/s
    // Null when the host exposes no readable thermal sensor.
    val cpuTemperatureC: Float? = null,
)

@Entity(tableName = "ssh_keys")
data class SshKeyEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val alias: String,
    val keyType: String, // "RSA", "ED25519", "ECDSA", "ED25519-SK", "ECDSA-SK"
    // A key on a security key keeps its key file here: the handle the security key finds it by.
    val privateKey: String,
    val publicKey: String,
    val fingerprint: String,
    // The key's OpenSSH certificate (the -cert.pub line), "" without one.
    val certificate: String = "",
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
    // "CPU Usage", "Memory Usage", "Disk Usage", "Network In", "Network Out", "Latency",
    // "Temperature" (only evaluates on hosts that expose a thermal sensor), and the checks the
    // phone runs itself, "TLS Expiry", "URL Check", "Ping", "TCP Port" and "DNS" (see EndpointChecks),
    // and the host checks (see HostChecks)
    val metricName: String,
    val mountPoint: String = "/",
    val thresholdValue: Float,
    val severity: String, // "WARNING", "CRITICAL"
    val triggerWindow: String = "5m", // "2m", "5m", "10m", "15m"
    val enabled: Boolean = true,
    // Free-text note documenting why this rule exists / what it watches for.
    val notes: String = "",
    // Stable identity of the built-in preset this rule was seeded from (e.g. "alert.cpu"), or null
    // for user-created rules. Survives threshold/severity edits, so the default-rules toggle can
    // delete exactly what it seeded instead of matching on mutable content.
    val presetKey: String? = null,
    // What a TLS or URL check connects to: a URL, or host[:port] for TLS. Blank on a TLS rule
    // means each host's own address on port 443. A Script Check holds its script's id here.
    // Unused by the other metrics.
    val target: String = "",
    // The saved script this rule's notification and incident offer to run, after the usual
    // confirmation, or null for none. Cleared when that script is deleted.
    val runbookScriptId: Int? = null,
)

@Entity(
    tableName = "active_alerts",
    indices = [Index(value = ["ruleId", "serverId"], unique = true)],
)
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
    val notes: String = "",
    // Stable identity of the built-in preset this row was seeded from (e.g. "fleet.cpu"), or null
    // for user-created scripts. Survives edits to the name/command, so the preset toggles can
    // delete exactly what they seeded instead of matching on mutable content.
    val presetKey: String? = null
)

/** When metrics were last recorded for a host; a query result, not a table. */
data class ServerLastSample(val serverId: Int, val lastAt: Long)

/** The first and last time a host's metrics were recorded, null with none; a query result. */
data class MetricHistorySpan(val firstAt: Long?, val lastAt: Long?)

/** A saved Telnet connection: network gear and other hosts reached by Telnet rather than SSH. */
@Entity(tableName = "telnet_hosts")
data class TelnetHostEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val host: String,
    val port: Int = 23,
)

/**
 * A Kubernetes cluster reached from the phone itself, saved from one context of an imported
 * kubeconfig. [clientKeyPem] and [token] are encrypted at the repository boundary.
 */
@Entity(tableName = "kube_clusters")
data class KubeClusterEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val server: String,
    val caPem: String = "",
    val clientCertPem: String = "",
    val clientKeyPem: String = "",
    val token: String = "",
    val namespace: String = "",
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

/**
 * One Fleet run, kept in its run history: the newest [FleetRunHistory.KEEP_RUNS] are kept, and
 * backups carry them (the Fleet history section). Each host's result is a [FleetRunHostEntity].
 */
@Entity(tableName = "fleet_runs", indices = [Index(value = ["runKey"], unique = true)])
data class FleetRunEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    // The run's own id, so a host that finishes after the run (a tmux run followed again, a
    // reconnect) updates this row instead of adding another.
    val runKey: String,
    val startedAt: Long,
    val finishedAt: Long,
    // The command as written, `{{placeholders}}` unfilled: the values typed for them are not kept.
    val command: String,
    // The saved script the command came from, if it still matched one.
    val scriptName: String? = null,
    // FleetRunHistory.SOURCE_*: a run from Broadcast, a retry of failed hosts, or an alert's runbook.
    val source: String = FleetRunHistory.SOURCE_FLEET,
)

/** One host's result in a [FleetRunEntity]. */
@Entity(tableName = "fleet_run_hosts", primaryKeys = ["runId", "serverId"])
data class FleetRunHostEntity(
    val runId: Int,
    val serverId: Int,
    // As named when it ran, so the history still reads after the host is renamed or deleted.
    val serverName: String,
    // A BroadcastStatus name.
    val status: String,
    val note: String? = null,
    // The end of the host's output, at most FleetRunHistory.OUTPUT_CHARS.
    val output: String = "",
    val truncated: Boolean = false,
)

/** A [FleetRunEntity] with how many of its hosts succeeded, for the history list. */
data class FleetRunSummary(
    @androidx.room.Embedded val run: FleetRunEntity,
    val hosts: Int,
    val succeeded: Int,
)

object FleetRunHistory {
    const val KEEP_RUNS = 50
    const val OUTPUT_CHARS = 16_000
    const val SOURCE_FLEET = "fleet"
    const val SOURCE_RETRY = "retry"
    const val SOURCE_RUNBOOK = "runbook"
    const val SOURCE_AUTOMATION = "automation"
    const val SOURCE_MCP = "mcp"

    /** [output]'s end, at most [OUTPUT_CHARS], as one host's row; [runId] is set when the run is saved. */
    fun host(serverId: Int, serverName: String, status: String, note: String?, output: String, truncated: Boolean) =
        FleetRunHostEntity(
            runId = 0,
            serverId = serverId,
            serverName = serverName,
            status = status,
            note = note,
            output = output.takeLast(OUTPUT_CHARS),
            truncated = truncated || output.length > OUTPUT_CHARS,
        )
}

/**
 * Lets other apps (Tasker and similar) run one saved script on chosen hosts, when they present the
 * matching token. The token is shown once when the grant is made and never stored: only its
 * SHA-256 is. Deleting the grant revokes it. Not in backups.
 */
@Entity(tableName = "automation_grants", indices = [Index(value = ["tokenHash"], unique = true)])
data class AutomationGrantEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val scriptId: Int,
    // The hosts it may run on, as comma-separated server ids.
    val serverIds: String,
    // Lower-case hex SHA-256 of the token.
    val tokenHash: String,
    // Where it is used: "Tasker", or the name the user gave it.
    val label: String,
    val createdAt: Long,
    val lastUsedAt: Long? = null,
)

/**
 * One call an AI assistant made to the MCP server, so the user can see what was asked and what
 * came of it: the newest [com.jetsetslow.omniterm.data.mcp.McpSettings.KEEP_CALLS] are kept, and
 * backups carry them (the AI assistant log section). [outcome] is one of [McpCallOutcome]'s
 * values; [detail] is the first line of the answer, short.
 */
@Entity(tableName = "mcp_calls")
data class McpCallEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val at: Long,
    val client: String,
    val tool: String,
    val outcome: String,
    val detail: String,
)

object McpCallOutcome {
    const val OK = "ok"
    const val FAILED = "failed"
    /** A request turned away for its token, host name or origin. */
    const val REFUSED = "refused"
}

/**
 * A tunnel the user set up once and picks per host. [config] is the tunnel's own configuration
 * (for WireGuard, the wg-quick file with its private key), encrypted at the repository boundary.
 */
@Entity(tableName = "tunnels")
data class TunnelEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val kind: String = TunnelKinds.WIREGUARD,
    val config: String,
    val createdAt: Long = System.currentTimeMillis(),
)

object TunnelKinds {
    const val WIREGUARD = "wireguard"
}
