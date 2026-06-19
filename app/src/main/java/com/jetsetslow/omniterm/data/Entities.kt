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
    val keyAlias: String? = null
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
    val enabled: Boolean = true
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
    val targetSystem: String = "Any"
)

@Entity(tableName = "wol_targets")
data class WolTargetEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val macAddress: String,
    val broadcastIp: String = "192.168.1.255",
    val port: Int = 9,
    val notes: String = "",
    val lastWokenTime: Long = 0L
)

@Entity(tableName = "app_settings")
data class AppSettingEntity(
    @PrimaryKey val key: String,
    val value: String
)
