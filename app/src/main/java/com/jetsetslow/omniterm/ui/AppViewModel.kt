package com.jetsetslow.omniterm.ui

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jetsetslow.omniterm.data.*
import com.jetsetslow.omniterm.data.shares.RemoteFsClient
import com.jetsetslow.omniterm.data.shares.ShareClients
import com.jetsetslow.omniterm.data.ssh.JschSftp
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import com.jetsetslow.omniterm.data.term.TmuxControlCommands
import com.jetsetslow.omniterm.data.term.TmuxControlEvent
import com.jetsetslow.omniterm.data.term.TmuxControlParser
import androidx.compose.runtime.mutableStateMapOf
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import java.util.Locale
import java.util.UUID

/** Notification channel for fired monitoring alerts (distinct from the session-service channel). */
private const val ALERT_CHANNEL_ID = "monitoring_alerts"

/** Notification channel for the low-battery saver engaging. */
private const val BATTERY_SAVER_CHANNEL_ID = "battery_saver"

/** Cap on the live action panel text: long-running streams keep only the most recent output. */
private const val ACTION_STREAM_MAX_CHARS = 200_000

/** Cap per host for Fleet Broadcast output; long-running commands keep the latest tail only. */
private const val BROADCAST_OUTPUT_MAX_CHARS = 120_000

/** Default hard stop for one Fleet Broadcast run. */
private const val BROADCAST_TIMEOUT_MS = 10 * 60 * 1000L

private const val TERMINAL_INPUT_CHUNK_BYTES = 4096
private const val TERMINAL_INPUT_QUEUE_MAX_BYTES = 4 * 1024 * 1024
private const val CONTROL_PENDING_INPUT_MAX_BYTES = 1024 * 1024

/** Trusted Android system executables; never resolve process commands through an inherited PATH. */
internal const val ANDROID_PING_BINARY = "/system/bin/ping"
internal val ANDROID_TRACEROUTE_BINARIES = listOf(
    "/system/bin/traceroute",
    "/system/xbin/traceroute",
)

private const val BACKUP_SCHEMA_VERSION = 5
private const val BACKUP_MAX_INPUT_CHARS = 20 * 1024 * 1024
private const val BACKUP_MAX_CIPHERTEXT_BYTES = 12 * 1024 * 1024
private const val BACKUP_MAX_PLAIN_BYTES = 32 * 1024 * 1024
private const val BACKUP_MAX_COLLECTION_ITEMS = 50_000
private const val BACKUP_MAX_JSON_DEPTH = 24
private const val BACKUP_MAX_FIELD_CHARS = 1024 * 1024
private const val BACKUP_MAX_KEY_CHARS = 256
private const val BACKUP_MIN_KDF_ITERATIONS = 100_000
private const val BACKUP_MAX_KDF_ITERATIONS = 1_000_000

internal fun validateBackupCryptoParameters(
    iterations: Int,
    saltSize: Int,
    ivSize: Int,
    ciphertextSize: Int,
    maxCiphertextBytes: Int = BACKUP_MAX_CIPHERTEXT_BYTES,
) {
    require(iterations in BACKUP_MIN_KDF_ITERATIONS..BACKUP_MAX_KDF_ITERATIONS) {
        "Backup KDF work factor is outside the supported safety range."
    }
    require(saltSize == 16) { "Invalid backup salt length." }
    require(ivSize == 12) { "Invalid backup IV length." }
    require(ciphertextSize in 16..maxCiphertextBytes) { "Invalid backup ciphertext length." }
}

internal fun gunzipBackupBounded(
    bytes: ByteArray,
    maxPlainBytes: Int = BACKUP_MAX_PLAIN_BYTES,
    maxCompressedBytes: Int = BACKUP_MAX_CIPHERTEXT_BYTES,
    maxExpansionRatio: Long = 200L,
): ByteArray {
    require(bytes.size <= maxCompressedBytes) { "Compressed backup is too large." }
    val ratioLimit = (bytes.size.toLong() * maxExpansionRatio)
        .coerceAtLeast(minOf(1024L * 1024L, maxPlainBytes.toLong()))
        .coerceAtMost(maxPlainBytes.toLong())
    val output = ByteArrayOutputStream(minOf(ratioLimit.toInt(), 64 * 1024))
    java.util.zip.GZIPInputStream(bytes.inputStream()).use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            require(total <= ratioLimit && total <= maxPlainBytes) {
                "Backup expands beyond the safe restore limit."
            }
            output.write(buffer, 0, count)
        }
    }
    return output.toByteArray()
}

internal fun validateBackupJsonNesting(text: String, maxDepth: Int = BACKUP_MAX_JSON_DEPTH) {
    var depth = 0
    var inString = false
    var escaped = false
    for (character in text) {
        if (inString) {
            when {
                escaped -> escaped = false
                character == '\\' -> escaped = true
                character == '"' -> inString = false
            }
        } else {
            when (character) {
                '"' -> inString = true
                '{', '[' -> {
                    depth++
                    require(depth <= maxDepth) { "Backup JSON is nested too deeply." }
                }
                '}', ']' -> depth--
            }
            require(depth >= 0) { "Backup JSON structure is malformed." }
        }
    }
    require(!inString && depth == 0) { "Backup JSON structure is incomplete." }
}

/** Cap on the SFTP transfer log; finished entries beyond this are dropped, in-flight ones never. */
private const val SFTP_TRANSFER_LOG_MAX = 50

/** Sentinel message for user-cancelled transfers; the Transfers tab renders it as its own state. */
const val TRANSFER_CANCELLED_MESSAGE = "Cancelled"

/** Cap on recursive SFTP search hits so a broad pattern can't flood the UI. */
private const val SFTP_SEARCH_MAX_HITS = 200

/** How often saved network-share availability is refreshed while the app is alive. */
private const val NETWORK_SHARE_PROBE_INTERVAL_MS = 60_000L

/** Default background time before the app lock re-engages on a warm reopen (user-configurable). */
private const val APP_RELOCK_GRACE_MS = 30_000L

// Auto-reconnect backoff for dropped interactive sessions: 1s, 2s, 4s… capped at 30s, up to N tries.
// Slow Wi-Fi -> mobile handoffs can take well over a minute before the OS has a usable route again.
private const val RECONNECT_BASE_DELAY_MS = 1_000L
private const val RECONNECT_MAX_DELAY_MS = 30_000L
private const val RECONNECT_MAX_ATTEMPTS = 12

/**
 * Decide whether a closed shell session was a CLEAN exit (the remote shell ran `exit`, so the
 * session should be torn down) versus an unexpected transport loss (network change/drop, so the
 * session should auto-reconnect instead).
 *
 * Any real, non-negative exit status counts as clean: the remote shell exited deliberately, whether
 * with `0` (`exit`) or non-zero (`exit 1`, a failed last command, etc.). A network drop leaves the
 * status as `-1` or `null` (the transport died before any `exit-status` message arrived), and must
 * NOT be mistaken for a clean exit — otherwise a momentary network change would silently kill the
 * terminal (and its tmux session) instead of reconnecting. Pulled out as a pure function so this
 * exact rule is unit-tested and can't regress.
 */
internal fun isCleanShellExit(exitStatus: Int?): Boolean = exitStatus != null && exitStatus >= 0

enum class Screen {
    Servers,
    Fleet,
    Monitor,
    Shell,
    SFTP,
    Infra,
    Tools,
    Alerts,
    QuickScripts,
    Network,
    AuthKeys,
    Backup,
    HealthScoring,
    Settings,
    About
}

/** Non-printable keys the terminal key-bar / hardware keyboard can send. */
enum class TermKey {
    ENTER, BACKSPACE, TAB, ESC,
    UP, DOWN, LEFT, RIGHT,
    HOME, END, INSERT, DELETE, PAGE_UP, PAGE_DOWN,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12
}

enum class SftpTransferStatus { InProgress, Success, Failure }

enum class SftpSortOption(val label: String) {
    NameAsc("Name A-Z"),
    NameDesc("Name Z-A"),
    ModifiedAsc("Modified oldest"),
    ModifiedDesc("Modified newest"),
    SizeAsc("Size smallest"),
    SizeDesc("Size largest"),
    TypeFoldersFirst("Folders first"),
    TypeFilesFirst("Files first"),
}

data class SftpTransferItem(
    val id: String = UUID.randomUUID().toString(),
    val serverId: Int,
    val serverName: String,
    val direction: String,
    val name: String,
    val remotePath: String,
    val status: SftpTransferStatus = SftpTransferStatus.InProgress,
    val bytesTransferred: Long = 0L,
    val totalBytes: Long = 0L,
    val message: String = "",
    val startedAtMs: Long = System.currentTimeMillis(),
    val speedKbps: Float = 0f,
    val etaSeconds: Int = -1,
    val retryable: Boolean = false,
    val sourceUri: String? = null,
)

data class NetworkShareScanHit(
    val address: String,
    val protocol: String,
    val port: Int,
    val label: String = "$protocol on $address:$port",
    val sharePath: String = "",
)

/**
 * Windows-style rollup of the transfers currently in flight: how many files, how many bytes done
 * of the known total, and the combined throughput. [totalBytes] counts only rows whose size is
 * known, so a WebDAV upload with no Content-Length doesn't zero out the aggregate bar.
 */
data class TransferAggregate(
    val activeFiles: Int,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val speedKbps: Float,
) {
    val hasKnownTotal: Boolean get() = totalBytes > 0
    val fraction: Float get() = if (totalBytes > 0) (bytesTransferred.toFloat() / totalBytes).coerceIn(0f, 1f) else 0f
    val etaSeconds: Int
        get() {
            val remaining = totalBytes - bytesTransferred
            return if (speedKbps > 0f && remaining > 0) (remaining / (speedKbps * 1024f)).toInt() else -1
        }
}

/**
 * One file staged on the cross-endpoint clipboard. Exactly one of [serverId] (an SSH host from
 * the SFTP tab) or [shareId] (a saved network share) identifies where the file lives, so a paste
 * can re-open the right connection even after the user navigates elsewhere.
 */
data class RemoteFileRef(
    val serverId: Int? = null,
    val shareId: Int? = null,
    val sourceLabel: String,
    val dir: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long = 0L,
)

enum class BroadcastStatus { Running, Success, Failure }

enum class FleetTargetMode { Servers, Groups }

data class BroadcastResultItem(
    val serverId: Int,
    val serverName: String,
    val output: String = "",
    val status: BroadcastStatus = BroadcastStatus.Running,
    val truncated: Boolean = false,
)

data class BackupSelection(
    val servers: Boolean = true,
    val sshKeys: Boolean = true,
    val credentialProfiles: Boolean = true,
    val scripts: Boolean = true,
    val alertRules: Boolean = true,
    val activeAlerts: Boolean = true,
    val alertHistory: Boolean = true,
    val wolTargets: Boolean = true,
    val networkShares: Boolean = true,
    val portForwards: Boolean = true,
    val settings: Boolean = true,
    // Opt-in (off by default): crash logs are device/build-specific diagnostics that can contain
    // sensitive details (hostnames, paths, command fragments), so they're never included unless the
    // user explicitly selects them — and when selected, [hasSensitiveData] forces encryption.
    val crashLogs: Boolean = false,
)

/**
 * Add the section-level dependencies required to restore referentially valid rows.
 *
 * Tunnels point at a saved server. Active alerts point at both a server and an alert rule. Keep
 * this normalization outside the UI as well: persisted selections and programmatic export callers
 * must not be able to create a backup whose selected child rows can never be restored.
 */
internal fun BackupSelection.withReferentialClosure(): BackupSelection = copy(
    servers = servers || portForwards || alertRules || activeAlerts || alertHistory,
    alertRules = alertRules || activeAlerts,
)

internal fun BackupSelection.withServersSelected(enabled: Boolean): BackupSelection =
    if (enabled) copy(servers = true)
    else copy(
        servers = false,
        alertRules = false,
        activeAlerts = false,
        alertHistory = false,
        portForwards = false,
    )

internal fun BackupSelection.withAlertRulesSelected(enabled: Boolean): BackupSelection =
    if (enabled) copy(alertRules = true).withReferentialClosure()
    else copy(alertRules = false, activeAlerts = false)

internal fun BackupSelection.withActiveAlertsSelected(enabled: Boolean): BackupSelection =
    copy(activeAlerts = enabled).withReferentialClosure()

internal fun BackupSelection.withPortForwardsSelected(enabled: Boolean): BackupSelection =
    copy(portForwards = enabled).withReferentialClosure()

internal fun BackupSelection.withAlertHistorySelected(enabled: Boolean): BackupSelection =
    copy(alertHistory = enabled).withReferentialClosure()

/** Preserve the global server id while requiring a concrete mapping for server-scoped records. */
internal fun remapBackupServerId(oldServerId: Int, serverIdMap: Map<Int, Int>): Int? =
    if (oldServerId == 0) 0 else serverIdMap[oldServerId]

/** Rule ids that must be serialized for the selected alert rows to remain resolvable on restore. */
internal fun backupRuleIdsForSelection(
    customRuleIds: Set<Int>,
    activeAlertRuleIds: Set<Int>,
    selection: BackupSelection,
): Set<Int> {
    val closed = selection.withReferentialClosure()
    if (!closed.alertRules) return emptySet()
    return if (closed.activeAlerts) customRuleIds + activeAlertRuleIds else customRuleIds
}

data class BackupContents(
    val servers: Int = 0,
    val sshKeys: Int = 0,
    val credentialProfiles: Int = 0,
    val scripts: Int = 0,
    val alertRules: Int = 0,
    val activeAlerts: Int = 0,
    val alertHistory: Int = 0,
    val wolTargets: Int = 0,
    val networkShares: Int = 0,
    val portForwards: Int = 0,
    val settings: Int = 0,
    val crashLogs: Int = 0,
)

data class BackupHostOption(
    val oldId: Int,
    val name: String,
    val host: String,
    val port: Int,
)

fun BackupSelection.hasSensitiveData(): Boolean =
    servers || sshKeys || credentialProfiles || scripts || alertRules || activeAlerts ||
        // Crash traces can carry hostnames, file paths, and command fragments — treat as sensitive
        // so a backup containing them is gated behind passphrase encryption like any other secret.
        alertHistory || wolTargets || networkShares || portForwards || settings || crashLogs

private const val BACKUP_SELECTION_V2_PREFIX = "v2:"

fun BackupSelection.encode(): String {
    val closed = withReferentialClosure()
    return BACKUP_SELECTION_V2_PREFIX + listOf(
        "servers" to closed.servers,
        "sshKeys" to closed.sshKeys,
        "credentialProfiles" to closed.credentialProfiles,
        "scripts" to closed.scripts,
        "alertRules" to closed.alertRules,
        "activeAlerts" to closed.activeAlerts,
        "alertHistory" to closed.alertHistory,
        "wolTargets" to closed.wolTargets,
        "networkShares" to closed.networkShares,
        "portForwards" to closed.portForwards,
        "settings" to closed.settings,
        "crashLogs" to closed.crashLogs,
    ).filter { it.second }.joinToString(",") { it.first }
}

fun decodeBackupSelection(value: String?): BackupSelection {
    if (value.isNullOrBlank()) return BackupSelection()
    val isV2 = value.startsWith(BACKUP_SELECTION_V2_PREFIX)
    val encodedKeys = if (isV2) value.removePrefix(BACKUP_SELECTION_V2_PREFIX) else value
    val keys = encodedKeys.split(",").map { it.trim() }.filter { it.isNotBlank() }.toSet()
    return BackupSelection(
        servers = "servers" in keys,
        sshKeys = "sshKeys" in keys,
        credentialProfiles = "credentialProfiles" in keys,
        scripts = "scripts" in keys,
        alertRules = "alertRules" in keys,
        activeAlerts = "activeAlerts" in keys,
        alertHistory = "alertHistory" in keys,
        wolTargets = "wolTargets" in keys,
        networkShares = "networkShares" in keys,
        // v1 predates tunnel backup. Inherit the new child section only when its Servers parent was
        // selected; a legacy settings-only selection must not suddenly start exporting host data.
        portForwards = if (isV2) "portForwards" in keys else "servers" in keys,
        settings = "settings" in keys,
        crashLogs = "crashLogs" in keys,
    ).withReferentialClosure()
}

private const val PIN_HASH_V1_PREFIX = "pin:v1:"
private const val PIN_HASH_V2_PREFIX = "pin:v2:"
private const val PIN_PBKDF2_ITERATIONS = 210_000

// Throttle policy for failed PIN attempts (internal so the policy itself is unit-testable).
internal const val PIN_MAX_ATTEMPTS = 5
internal const val PIN_LOCKOUT_MS = 30_000L

/** True while PIN entry is throttled after too many failures. */
internal fun isPinThrottled(lockedUntilMs: Long, nowMs: Long): Boolean = nowMs < lockedUntilMs

/** Lockout deadline after a failed attempt: locks for [PIN_LOCKOUT_MS] at [PIN_MAX_ATTEMPTS]. */
internal fun pinLockoutAfterFailure(failedAttempts: Int, nowMs: Long): Long =
    if (failedAttempts >= PIN_MAX_ATTEMPTS) nowMs + PIN_LOCKOUT_MS else 0L

internal fun hashPinForStorage(pin: String): String {
    val salt = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
    val spec = javax.crypto.spec.PBEKeySpec(pin.toCharArray(), salt, PIN_PBKDF2_ITERATIONS, 256)
    val hash = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        .generateSecret(spec).encoded
    spec.clearPassword()
    val b64 = android.util.Base64.NO_WRAP
    return listOf(
        PIN_HASH_V2_PREFIX.removeSuffix(":"),
        PIN_PBKDF2_ITERATIONS.toString(),
        android.util.Base64.encodeToString(salt, b64),
        android.util.Base64.encodeToString(hash, b64),
        pin.length.toString(),
    ).joinToString(":")
}

internal fun storedPinLength(stored: String?): Int? =
    stored?.takeIf { it.startsWith(PIN_HASH_V1_PREFIX) || it.startsWith(PIN_HASH_V2_PREFIX) }
        ?.substringAfterLast(':')?.toIntOrNull()

internal fun verifyStoredPin(stored: String?, pin: String): Boolean {
    if (stored.isNullOrBlank() || pin.isBlank()) return false
    if (!stored.startsWith("pin:")) return stored == pin
    val parts = stored.split(":")
    return runCatching {
        val b64 = android.util.Base64.NO_WRAP
        val (salt, expected, actual) = when {
            stored.startsWith(PIN_HASH_V2_PREFIX) && parts.size == 6 -> {
                val iterations = parts[2].toIntOrNull() ?: return false
                if (iterations !in 100_000..1_000_000) return false
                val salt = android.util.Base64.decode(parts[3], b64)
                val expected = android.util.Base64.decode(parts[4], b64)
                if (salt.size != 16 || expected.size != 32) return false
                val spec = javax.crypto.spec.PBEKeySpec(pin.toCharArray(), salt, iterations, 256)
                val actual = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                    .generateSecret(spec).encoded
                spec.clearPassword()
                Triple(salt, expected, actual)
            }
            stored.startsWith(PIN_HASH_V1_PREFIX) && parts.size == 5 -> {
                val salt = android.util.Base64.decode(parts[2], b64)
                val expected = android.util.Base64.decode(parts[3], b64)
                val actual = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(salt + pin.toByteArray(Charsets.UTF_8))
                Triple(salt, expected, actual)
            }
            else -> return false
        }
        java.security.MessageDigest.isEqual(expected, actual)
    }.getOrDefault(false)
}

private val builtInFleetPresets: List<QuickScriptEntity> = listOf(
    QuickScriptEntity(0, "CPU", "CPU/RAM", "uptime 2>/dev/null || powershell -NoProfile -Command \"(Get-CimInstance Win32_OperatingSystem).LastBootUpTime\"; free -h 2>/dev/null || vm_stat 2>/dev/null || powershell -NoProfile -Command \"Get-CimInstance Win32_OperatingSystem | ForEach-Object { 'TotalMB=' + [int](\$_.TotalVisibleMemorySize/1024) + ' FreeMB=' + [int](\$_.FreePhysicalMemory/1024) }\"", "cyan", false, "Fleet", 0, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "DSK", "Disk", "df -h 2>/dev/null | head -6 || powershell -NoProfile -Command \"Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID,Size,FreeSpace\"", "cyan", false, "Fleet", 1, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "PRC", "Processes", "ps aux 2>/dev/null | sort -k3 -nr | head -8 || ps -axo pid,user,pcpu,pmem,comm 2>/dev/null | sort -k3 -nr | head -8 || powershell -NoProfile -Command \"Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 Id,ProcessName,CPU,WorkingSet\"", "cyan", false, "Fleet", 2, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "SVC", "Failed services", "systemctl --failed 2>/dev/null || rc-status -c 2>/dev/null || powershell -NoProfile -Command \"Get-Service | Where-Object Status -eq Stopped | Select-Object -First 12 Name,Status\"", "cyan", false, "Fleet", 3, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "LOG", "Syslog errors", "journalctl -p err -n 8 2>/dev/null || logread 2>/dev/null | grep -iE 'error|fail|critical' | tail -8 || grep -iE 'error|fail|critical' /var/log/syslog /var/log/messages 2>/dev/null | tail -8 || powershell -NoProfile -Command \"Get-WinEvent -FilterHashtable @{LogName='System'; Level=2} -MaxEvents 8 | Select-Object TimeCreated,ProviderName,Message\"", "cyan", false, "Fleet", 4, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "CTR", "Containers", "docker ps --format \"table {{.Names}}\t{{.Status}}\" 2>/dev/null || podman ps --format \"table {{.Names}}\t{{.Status}}\"", "cyan", false, "Fleet", 5, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "NET", "Listening ports", "ss -tlnp 2>/dev/null | grep LISTEN || netstat -tlnp 2>/dev/null | grep LISTEN || netstat -an 2>/dev/null | grep LISTEN || powershell -NoProfile -Command \"Get-NetTCPConnection -State Listen | Select-Object -First 25 LocalAddress,LocalPort,OwningProcess\"", "cyan", false, "Fleet", 6, availableForQuick = false, availableForFleet = true),
    QuickScriptEntity(0, "KRN", "Kernel", "uname -sr 2>/dev/null || powershell -NoProfile -Command \"[Environment]::OSVersion.VersionString\"", "cyan", false, "Fleet", 7, availableForQuick = false, availableForFleet = true),
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val db = AppDatabase.getDatabase(application)
    private val repository = AppRepository(db)
    private val freePlayStoreLimit = 1

    // NAVIGATION SYSTEM with full backstack history
    val screenHistory = mutableStateListOf<Screen>(Screen.Servers)
    var currentScreen by mutableStateOf(Screen.Servers)
        private set

    // NAVIGATION CONFIRMATION DIALOG (Tapping away from Terminal while active)
    var showDisconnectTerminalDialog by mutableStateOf(false)
    var showKeepScreenOnBatteryWarning by mutableStateOf(false)
    var pendingDisconnectSessionId by mutableStateOf<String?>(null)
    var pendingDisconnectAllSessions by mutableStateOf(false)
    var pendingNavigationScreen by mutableStateOf<Screen?>(null)

    // SECURITY PIN & APP LOCK STATE
    var savedPin by mutableStateOf<String?>(null)
    private var failedPinAttempts by mutableStateOf(0)
    private var pinLockedUntilMs by mutableStateOf(0L)
    var isAppLockEnabled by mutableStateOf(false)
    var useBiometrics by mutableStateOf(false); private set
    var isFirstRun by mutableStateOf(false); private set
    var isAppLocked by mutableStateOf(false)
    var currentPinInput by mutableStateOf("")
    var lockScreenError by mutableStateOf<String?>(null)
    var dotsFlashRed by mutableStateOf(false)
    /** Blocks screenshots and the task-switcher preview (FLAG_SECURE). Defaults on for sensitive ops. */
    var isFlagSecureEnabled by mutableStateOf(true)
        private set

    // App lock always engages on cold start: every process relaunch demands the PIN/biometric when
    // lock is enabled (shouldLockOnColdStart below). On top of that, warm reopens re-lock once the
    // app has sat in background past the user's grace window. The timer is in-memory only — unlike
    // the pre-64cf6ff SharedPreferences mirror, process death can never carry a stale "recently
    // backgrounded" stamp into a fresh launch and bypass the lock.
    var appLockGraceMs by mutableStateOf(APP_RELOCK_GRACE_MS)
        private set
    private var backgroundedAtMs = 0L

    fun saveAppLockGrace(graceMs: Long) {
        appLockGraceMs = graceMs.coerceAtLeast(0L)
        viewModelScope.launch { repository.insertSetting("app_lock_grace_ms", appLockGraceMs.toString()) }
    }

    /** Called from MainActivity.onStop — remember when the app left the foreground. */
    fun noteAppBackgrounded() {
        backgroundedAtMs = System.currentTimeMillis()
    }

    /** Called from MainActivity.onStart — re-engage the lock if backgrounded past the grace. */
    fun relockIfNeeded() {
        val since = backgroundedAtMs
        backgroundedAtMs = 0L
        // since == 0L means this onStart isn't paired with an in-process onStop: either the very
        // first launch (the cold-start path already decided the lock) or a config change. No-op.
        if (since == 0L) return
        if (!isAppLockEnabled || savedPin.isNullOrBlank()) return
        if (System.currentTimeMillis() - since >= appLockGraceMs) {
            currentPinInput = ""
            lockScreenError = null
            isAppLocked = true
        }
    }

    private fun shouldLockOnColdStart(): Boolean =
        !savedPin.isNullOrBlank() && isAppLockEnabled

    var defaultKeepScreenOn by mutableStateOf(false)
    private var initialKeepScreenOnLoaded = false
    var isKeepScreenOnEnabled by mutableStateOf(false)
    var isBackgroundKeepAlive by mutableStateOf(false)
    var isDarkModeEnabled by mutableStateOf<Boolean?>(null)
    // AMOLED dark variant: pure-black surfaces. Only takes effect while dark mode is active.
    var isAmoledEnabled by mutableStateOf(false)
    // Max chars to syntax-highlight in the code editor before falling back to plain text. User can
    // lower it (slow devices / huge files) but never above the safe cap (clamped on load + save).
    var editorHighlightLimit by mutableStateOf(HIGHLIGHT_MAX_CHARS_DEFAULT)
        private set

    // BACK END DATA PLUMBING
    val servers = repository.serversFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val keys = repository.keysFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val profiles = repository.profilesFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    var knownHosts by mutableStateOf<List<KnownHost>>(emptyList())
    fun refreshKnownHosts() { knownHosts = SshHostKeyTrust.listKnownHosts() }
    fun removeKnownHost(host: String) {
        val port = if (host.contains(":")) host.substringAfterLast(":").toIntOrNull() ?: 22 else 22
        val h = if (host.contains(":")) host.substringBeforeLast(":") else host
        SshHostKeyTrust.removeHost(h, port)
        refreshKnownHosts()
    }
    val alertRules = repository.rulesFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val activeAlerts = repository.activeAlertsFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val alertHistory = repository.alertHistoryFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val quickScripts = repository.scriptsFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val wolTargets = repository.wolTargetsFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val portForwards = repository.portForwardsFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val networkShares = repository.networkSharesFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val allSettings = repository.settingsFlow.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    private var playStoreLicenseEnabled by mutableStateOf(false)
    private var playStoreUnlocked by mutableStateOf(true)
    var hostLimitReconciliationRequired by mutableStateOf(false)
        private set
    var hostLimitReconciliationReason by mutableStateOf("")
        private set

    val hostLimit: Int
        get() = if (playStoreLicenseEnabled && !playStoreUnlocked) freePlayStoreLimit else Int.MAX_VALUE
    val credentialProfileLimit: Int
        get() = if (playStoreLicenseEnabled && !playStoreUnlocked) freePlayStoreLimit else Int.MAX_VALUE
    val hasHostLimit: Boolean
        get() = hostLimit != Int.MAX_VALUE
    val hasCredentialProfileLimit: Boolean
        get() = credentialProfileLimit != Int.MAX_VALUE

    fun updateLicenseEntitlement(enabled: Boolean, unlocked: Boolean) {
        val wasUnlimited = !playStoreLicenseEnabled || playStoreUnlocked
        playStoreLicenseEnabled = enabled
        playStoreUnlocked = unlocked
        if (enabled && !unlocked && wasUnlimited) {
            reconcileHostLimit("Your full unlock is no longer active. Choose the one saved host to keep in the free Play Store build.")
        } else if (enabled && !unlocked) {
            reconcileHostLimit("The free Play Store build supports one saved host.")
        } else {
            hostLimitReconciliationRequired = false
            hostLimitReconciliationReason = ""
        }
    }

    private fun hostLimitMessage(): String =
        "The free Play Store build supports $freePlayStoreLimit saved ${if (freePlayStoreLimit == 1) "host" else "hosts"}. Unlock OmniTerm to add unlimited hosts."

    fun credentialProfileLimitMessage(): String =
        "The free Play Store build supports $freePlayStoreLimit authentication ${if (freePlayStoreLimit == 1) "method" else "methods"}. Unlock OmniTerm to save unlimited credentials."

    fun reconcileHostLimit(reason: String = hostLimitMessage()) {
        if (!hasHostLimit) return
        viewModelScope.launch {
            val all = repository.getAllServers()
            if (all.size > hostLimit) {
                hostLimitReconciliationReason = reason
                hostLimitReconciliationRequired = true
            } else {
                hostLimitReconciliationRequired = false
                hostLimitReconciliationReason = ""
            }
        }
    }

    fun keepOnlyHostAfterLimitChange(serverId: Int) {
        viewModelScope.launch {
            val all = repository.getAllServers()
            val keep = all.find { it.id == serverId } ?: all.firstOrNull() ?: return@launch
            val remove = all.filter { it.id != keep.id }
            remove.forEach { removed ->
                val removedSessions = activeSessions.filter { it.serverId == removed.id }.toList()
                removedSessions.forEach { session ->
                    session.userClosed = true
                    session.reconnectJob?.cancel()
                }
                val creds = runCatching { buildCredentials(removed) }.getOrNull()
                if (creds != null) {
                    removedSessions.filter { it.persistent }.forEach { session ->
                        sshTransport.exec(creds, RemoteCommands.tmuxKillCommand(session.tmuxName))
                    }
                    sshTransport.forgetCredentials(creds)
                    JschSftp.forgetCredentials(creds)
                }
                repository.getAllPortForwards().filter { it.serverId == removed.id }.forEach { stopTunnel(it.id) }
                SshHostKeyTrust.removeHost(removed.host, removed.port)
                removedSessions.forEach { cleanupSession(it) }
            }
            repository.keepOnlyServers(setOf(keep.id))
            restorablePersistentSessions = restorablePersistentSessions.filter { it.serverId == keep.id }

            // Clean out SSH keys of the unused hosts when they are not tied to the kept host
            val usedKeys = mutableSetOf<String>()
            keep.authKeyAlias?.let { usedKeys.add(it) }
            keep.proxyKeyAlias?.let { usedKeys.add(it) }
            if (keep.authProfileId != null) {
                val profile = repository.getAllProfiles().find { it.id == keep.authProfileId }
                profile?.keyAlias?.let { usedKeys.add(it) }
            }
            repository.getAllKeys().forEach { key ->
                if (key.alias !in usedKeys) {
                    repository.deleteKey(key)
                }
            }

            selectedServerId = keep.id
            currentScreen = Screen.Servers
            hostLimitReconciliationRequired = false
            hostLimitReconciliationReason = ""
            refreshKnownHosts()
        }
    }

    // CURRENT SELECTS / CONTEXTS
    private var _selectedServerId by mutableStateOf<Int?>(null)
    var selectedServerId: Int?
        get() = _selectedServerId
        set(value) {
            if (value != _selectedServerId) activeComposeDraft = null
            _selectedServerId = value
        }
    val selectedServer: ServerEntity?
        get() = servers.value.find { it.id == selectedServerId } ?: servers.value.firstOrNull()

    // RETENTION & CRON STUFF
    var metricsRetentionDays by mutableStateOf(7)
    /** Settings toggle state for built-in command/rule presets. */
    var homelabPresetsEnabled by mutableStateOf(false); private set
    var alertsEnabled by mutableStateOf(true); private set
    var alertPresetsEnabled by mutableStateOf(false); private set
    var fleetPresetsEnabled by mutableStateOf(true); private set
    var backupExportSelection by mutableStateOf(BackupSelection()); private set
    var lastBackupExportTime by mutableStateOf(0L); private set
    var isLanScanning by mutableStateOf(false)
    var sftpLargeBatchFileThreshold by mutableStateOf(50); private set
    var sftpLargeBatchBytesThreshold by mutableStateOf(1_000_000_000L); private set
    // Battery saver state (feature logic lives in the "Battery saver" section further down).
    // These MUST be declared above the init block: loadSecuritySettings() collects the allSettings
    // StateFlow, whose first (initial-value) emission runs synchronously inside the constructor on
    // Main.immediate — writing a mutableStateOf property declared below init NPEs on the null
    // delegate and crashes the app at startup.
    var batterySaverEnabled by mutableStateOf(false); private set
    var batterySaverThresholdPct by mutableStateOf(20); private set
    var batterySaverActive by mutableStateOf(false); private set
    var showBatterySaverDialog by mutableStateOf(false)
    var batterySaverEngagedAtPct by mutableStateOf(0); private set

    // MULTI-SELECT SERVER MODE
    var isMultiSelectMode by mutableStateOf(false)
    val selectedServerIdsForBulk = mutableStateListOf<Int>()
    var serverSearchText by mutableStateOf("")
    var selectedGroupChip by mutableStateOf<String?>("All")

    // MONITOR SCREEN METRIC HISTORY & EXPANSION STATE
    var activeMonitorTab by mutableStateOf(0) // 0: Overview, 1: Process, 2: Services, 3: Logs
    var processSortByCpu by mutableStateOf(true) // true: CPU, false: MEM
    var expandedProcessPid by mutableStateOf<Int?>(null)
    var logFilterType by mutableStateOf("ALL")
    var isLogsLive by mutableStateOf(true)

    // FLEET SCREEN MODE
    var fleetTabIndex by mutableStateOf(0) // 0: Dashboard, 1: Broadcast, 2: Fleet Logs
    val broadcastTargetServerIds = mutableStateListOf<Int>()
    val broadcastTargetGroups = mutableStateListOf<String>()
    var broadcastTargetMode by mutableStateOf(FleetTargetMode.Servers)
    var broadcastCommandText by mutableStateOf("")
    var isBroadcastExecuting by mutableStateOf(false)
    val broadcastResults = mutableStateListOf<BroadcastResultItem>()
    private var broadcastJob: Job? = null

    // FLEET LOGS
    val fleetLogSelectedServerIds = mutableStateListOf<Int>()
    var fleetLogs by mutableStateOf<List<FleetLogEntry>>(emptyList()); private set
    var isFleetLogsLoading by mutableStateOf(false)
    private val fleetLogSemaphore = kotlinx.coroutines.sync.Semaphore(4)

    fun toggleFleetLogServer(serverId: Int) {
        if (serverId in fleetLogSelectedServerIds) fleetLogSelectedServerIds.remove(serverId)
        else fleetLogSelectedServerIds.add(serverId)
    }

    fun loadFleetLogs() {
        if (isFleetLogsLoading) return
        val targets = fleetLogSelectedServerIds.toList()
        if (targets.isEmpty()) { fleetLogs = emptyList(); return }
        isFleetLogsLoading = true
        viewModelScope.launch(Dispatchers.IO) {
            val allEntries = java.util.concurrent.CopyOnWriteArrayList<FleetLogEntry>()
            val jobs = targets.map { srvId ->
                launch {
                    fleetLogSemaphore.withPermit {
                        val srv = repository.getServerById(srvId) ?: return@launch
                        if (srv.status != "online") return@launch
                        val out = executeSshCommand(srv, RemoteCommands.journal(200))
                        val entries = RemoteParsers.parseFleetJournal(out, srv.name, srv.id)
                        allEntries.addAll(entries)
                    }
                }
            }
            jobs.forEach { it.join() }
            val sorted = allEntries.sortedBy { it.timestamp }
            withContext(Dispatchers.Main) {
                fleetLogs = sorted
                isFleetLogsLoading = false
            }
        }
    }

    // SFTP SCREEN FILE BROWSER
    var activeSftpTab by mutableStateOf(0) // 0: SFTP files, 1: Shares, 2: Bookmarks, 3: Transfers
    val sftpTransfers = mutableStateListOf<SftpTransferItem>()

    // ── Transfer cancellation ──
    // Cancel requests are flag-based, checked from inside every transfer's progress callback (the
    // callbacks run on the transfer's own IO thread at least every 64 KiB / 150 ms). That gives
    // per-file semantics — cancelling one row of a batch upload lets the remaining files continue —
    // and works identically across SFTP/SMB/FTP/WebDAV without needing to interrupt blocking IO.
    private val cancelledTransferIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** Thrown from a progress callback to abort the surrounding stream copy. */
    private class TransferCancelledException : RuntimeException("Transfer cancelled")

    fun cancelSftpTransfer(id: String) {
        if (sftpTransfers.any { it.id == id && it.status == SftpTransferStatus.InProgress }) {
            cancelledTransferIds.add(id)
        }
    }

    fun cancelAllRunningTransfers() {
        sftpTransfers.filter { it.status == SftpTransferStatus.InProgress }
            .forEach { cancelledTransferIds.add(it.id) }
    }

    /** Progress callback for [transferId] that also aborts the copy once a cancel is requested. */
    private fun transferProgress(transferId: String): (Long, Long) -> Unit = { done, total ->
        if (transferId in cancelledTransferIds) throw TransferCancelledException()
        updateSftpTransferProgress(transferId, done, total)
    }
    var edittingSftpFile by mutableStateOf<SftpFile?>(null)
    var edittingSftpFilePath by mutableStateOf("")
    var networkShareScanRunning by mutableStateOf(false); private set
    var networkShareScanStatus by mutableStateOf<String?>(null); private set
    var networkShareScanCidr by mutableStateOf("")
    val networkShareScanHits = mutableStateListOf<NetworkShareScanHit>()

    /**
     * Protocols the LAN share scanner probes — a noise filter for networks where, say, every
     * printer answers on 80/443 as "WebDAV". Persisted; defaults to everything. At least one
     * protocol always stays enabled (a scan for nothing is a no-op that just looks broken).
     */
    val networkShareScanProtocols = mutableStateListOf("SMB", "FTP", "SFTP", "NFS", "WEBDAV")

    fun toggleShareScanProtocol(protocol: String) {
        if (protocol in networkShareScanProtocols) {
            if (networkShareScanProtocols.size <= 1) return
            networkShareScanProtocols.remove(protocol)
        } else {
            networkShareScanProtocols.add(protocol)
        }
        viewModelScope.launch {
            repository.insertSetting("share_scan_protocols", networkShareScanProtocols.joinToString(","))
        }
    }

    // ── Network share browsing (file browser over SMB/FTP/SFTP/WebDAV) ──
    var browsingShare by mutableStateOf<NetworkShareEntity?>(null); private set
    var sharePath by mutableStateOf(""); private set
    var shareEntries by mutableStateOf<List<SftpFile>>(emptyList()); private set
    var shareLoading by mutableStateOf(false); private set
    var shareError by mutableStateOf<String?>(null); private set
    /** Transient success/info banner for share browser actions. */
    var shareStatus by mutableStateOf<String?>(null)
    /** True while a share mutation (mkdir/rename/delete) runs, to gate those buttons. */
    var shareOpRunning by mutableStateOf(false); private set
    /** True while share SAF uploads/downloads run, so the browser can show an inline indicator. */
    var shareTransferRunning by mutableStateOf(false); private set
    /** Connection for the active browsing session; owned here, closed on exit/switch/clear. */
    private var shareClient: RemoteFsClient? = null
    private var shareClientShareId: Int? = null
    private val shareClientDialLock = Mutex()
    /** Snapshot/transaction/compensation must be single-flight across restore requests. */
    private val backupRestoreMutex = Mutex()
    private var shareJob: Job? = null
    private var networkShareAvailabilityJob: Job? = null
    private var networkShareAvailabilityRunning = false

    // ── Cross-endpoint clipboard: copy/paste between shares and SFTP hosts, both directions ──
    var crossClipboard by mutableStateOf<List<RemoteFileRef>>(emptyList()); private set
    var crossClipboardIsMove by mutableStateOf(false); private set
    var crossPasteRunning by mutableStateOf(false); private set
    /**
     * Opt-in: recurse into folders when pasting across endpoints. Off by default because a deep tree
     * is many round-trips over two connections and can move a lot of data; the user turns it on per
     * paste from the clipboard bar. Persisted so the choice sticks across sessions.
     */
    var crossPasteRecurseFolders by mutableStateOf(false)
        private set
    fun toggleCrossPasteRecurseFolders(enabled: Boolean) {
        crossPasteRecurseFolders = enabled
        viewModelScope.launch { repository.insertSetting("cross_paste_recurse", enabled.toString()) }
    }
    /** Live progress for a running recursive paste: files done + current path (null when idle). */
    var crossPasteProgress by mutableStateOf<String?>(null); private set

    // ── Batch transfer position: "file X of N" for any sequential multi-file operation ──
    // Batches (multi-upload, multi-download, cross-endpoint paste) run one file at a time, so the
    // aggregate banner would otherwise always read "1 file" with no sense of overall position.
    // Keyed per batch so overlapping batches (e.g. an SFTP upload while a share download runs)
    // aggregate cleanly instead of clobbering each other's counters.
    private val transferBatches = androidx.compose.runtime.mutableStateMapOf<Long, Pair<Int, Int>>()
    private val transferBatchIdGen = java.util.concurrent.atomic.AtomicLong(0)
    val transferBatchTotal: Int get() = transferBatches.values.sumOf { it.first }
    val transferBatchDone: Int get() = transferBatches.values.sumOf { it.second }
    private fun beginTransferBatch(total: Int): Long {
        val id = transferBatchIdGen.incrementAndGet()
        transferBatches[id] = total to 0
        return id
    }
    private fun advanceTransferBatch(id: Long) {
        val (total, done) = transferBatches[id] ?: return
        transferBatches[id] = total to (done + 1).coerceAtMost(total)
    }
    private fun endTransferBatch(id: Long) { transferBatches.remove(id) }

    // ── LIVE REMOTE DATA (real SSH; replaces the old in-memory simulator) ──
    var dockerContainers by mutableStateOf<List<SimContainer>>(emptyList()); private set
    var dockerImages by mutableStateOf<List<SimDockerImage>>(emptyList()); private set
    var dockerVolumes by mutableStateOf<List<SimDockerVolume>>(emptyList()); private set
    var dockerNetworks by mutableStateOf<List<SimDockerNetwork>>(emptyList()); private set
    var dockerLoading by mutableStateOf(false); private set
    var dockerError by mutableStateOf<String?>(null); private set
    // Usable container runtimes on the selected host ("docker"/"podman"); refreshed by loadDocker.
    // When both are present the compose builder offers a runtime picker for new stacks.
    var availableContainerRuntimes by mutableStateOf<Set<String>>(emptySet()); private set
    // Registry-known compose stacks on the selected host with NO containers in `ps -a` — i.e.
    // taken down via `compose down`, which erases the daemon's every trace of the project.
    // Sourced from the app-side stack registry (see StackRegistryEntity); refreshed by loadDocker.
    var downedStacks by mutableStateOf<List<StackRegistryEntity>>(emptyList()); private set

    var activeInfraTab by mutableStateOf(0)
    // Network Tools subtab (0: Host Scan, 1: Wake-on-LAN, 2: Ping, 3: Traceroute, 4: Port Scan). Held
    // in the VM (not local screen state) so the global horizontal swipe gesture can page between them.
    var activeNetworkTab by mutableStateOf(0)
    // Alerts (0: Active, 1: Rules, 2: History) and Scripts (0: Quick scripts, 1: Fleet commands)
    // subtabs, VM-held for the same swipe-paging reason as activeNetworkTab.
    var activeAlertsTab by mutableStateOf(0)
    var activeScriptsTab by mutableStateOf(0)
    // Bumped to force every WoL target's status dot to re-ping immediately (pull-to-refresh on the WoL
    // tab), so the user can check whether a woken host has come back online without waiting for the dot's
    // own 10s poll. The dots key their LaunchedEffect on this value.
    var wolStatusRefreshTick by mutableStateOf(0)
        private set
    var activeComposeDraft by mutableStateOf<com.jetsetslow.omniterm.ui.ComposeStackDraft?>(null)

    // ── Shared live-action output panel ──
    // Every button-triggered remote action (service start/stop/restart, Docker container and stack
    // actions, container logs, process kill, quick scripts) streams its combined output here, shown
    // in one global panel (see ActionStreamDialog).
    var actionStreamOutput by mutableStateOf("")
    var actionStreamTitle by mutableStateOf("")
    /** True while an action command is actively streaming output. */
    var actionStreamRunning by mutableStateOf(false)
    // Tracks the in-flight action coroutine plus a monotonically-increasing token. Closing the
    // panel (or starting a new action) bumps the epoch so late chunks from a cancelled stream
    // can't reopen the panel or bleed into the next action's output.
    private var actionStreamJob: Job? = null
    // Read from the execStream onChunk callback (IO dispatcher) and written from Main, so it must
    // be volatile for the late-chunk guard to observe the latest epoch across threads.
    @Volatile private var actionStreamEpoch = 0

    var processes by mutableStateOf<List<SimProcess>>(emptyList()); private set
    var processesLoading by mutableStateOf(false); private set

    var services by mutableStateOf<List<SimService>>(emptyList()); private set
    var servicesLoading by mutableStateOf(false); private set
    var serviceActionFeedback by mutableStateOf<String?>(null)

    // A privileged action (reboot / service control) waiting on biometric/PIN confirmation before
    // its stored sudo password is used. Non-null while the SudoAuthDialog is shown; cleared on
    // confirm or cancel. The UI renders the auth prompt and calls confirm/cancel back.
    var pendingSudoAction by mutableStateOf<(() -> Unit)?>(null); private set

    var logs by mutableStateOf<List<SimLog>>(emptyList()); private set
    var logsLoading by mutableStateOf(false); private set

    var hostMetrics by mutableStateOf(HostMetrics.EMPTY); private set
    var metricsLoading by mutableStateOf(false); private set
    var metricsHistory by mutableStateOf<List<MetricHistoryEntity>>(emptyList()); private set

    /** User-tunable health-scoring thresholds/weights (Settings). Drives the score and breakdown. */
    var healthConfig by mutableStateOf(HealthScoringConfig.DEFAULT); private set
    /** In-memory per-host live metrics map; populated for every reachable host by telemetry polling. */
    val hostMetricsById = mutableStateMapOf<Int, HostMetrics>()

    /**
     * Instantly seed [hostMetrics] from [hostMetricsById] for [serverId] if data is already
     * available (e.g. from a recent telemetry poll). This avoids showing stale zeros for the
     * previous host while a new SSH fetch is in flight. No-op if no cached data exists yet.
     */
    fun seedHostMetricsFromCache(serverId: Int) {
        hostMetricsById[serverId]?.let { hostMetrics = it }
    }

    fun loadMetricsHistory(serverId: Int) {
        viewModelScope.launch(Dispatchers.IO) {
            val since = System.currentTimeMillis() - 7 * 24 * 60 * 60 * 1000L
            val rows = repository.getMetricsSince(serverId, since)
            withContext(Dispatchers.Main) { metricsHistory = rows }
        }
    }

    var sftpPath by mutableStateOf(""); private set
    var sftpEntries by mutableStateOf<List<SftpFile>>(emptyList()); private set
    var sftpSortOption by mutableStateOf(SftpSortOption.NameAsc); private set
    private var sftpLoadedServerId: Int? = null

    val sftpBookmarks = mutableStateListOf<String>()
    var sftpLoading by mutableStateOf(false); private set
    var sftpError by mutableStateOf<String?>(null); private set
    /** Transient success/info banner for SFTP actions (save confirmed, copied, moved…). Auto-clears. */
    var sftpStatus by mutableStateOf<String?>(null)
    /** True while an edited file is being written + verified, so the editor can show a spinner. */
    var sftpSaving by mutableStateOf(false); private set

    /** When true, directory listings also compute the total size of each subfolder (via `du`). */
    var showSftpFolderSizes by mutableStateOf(false)
    fun toggleSftpFolderSizes() {
        showSftpFolderSizes = !showSftpFolderSizes
        loadSftp(sftpPath, clearError = false)
    }

    fun chooseSftpSortOption(option: SftpSortOption) {
        sftpSortOption = option
        sftpEntries = sortSftpEntries(sftpEntries)
        viewModelScope.launch { repository.insertSetting("sftp_sort", option.name) }
    }

    // ── Multi-select + clipboard (copy / cut / move) ──
    /** Names (within [sftpPath]) currently selected for a bulk action; non-empty ⇒ selection mode. */
    val sftpSelected = mutableStateListOf<String>()
    val sftpSelectionMode: Boolean get() = sftpSelected.isNotEmpty()
    /** Absolute source paths staged for paste, with a flag for whether they're a move (cut) or copy. */
    var sftpClipboard by mutableStateOf<List<String>>(emptyList()); private set
    var sftpClipboardIsMove by mutableStateOf(false); private set
    /** Host the [sftpClipboard] paths live on — a paste on any other host must stream, not `cp`. */
    private var sftpClipboardServerId: Int? = null
    /** True while a paste (server-side cp/mv) is running, to gate the paste button. */
    var sftpPasteRunning by mutableStateOf(false); private set

    /**
     * When true, SFTP mutations (save/copy/move/delete/mkdir/rename) and reading a file for editing
     * run as root via `sudo` over an exec channel, so protected paths (e.g. /etc) work. Uses the
     * server's stored sudo password (falling back to `sudo -n` for NOPASSWD hosts). Plain SFTP has
     * no concept of sudo, hence the exec route.
     */
    var sftpSudo by mutableStateOf(false)
    var sftpSudoConfirmDismissed by mutableStateOf(false)
    fun toggleSftpSudo() { sftpSudo = !sftpSudo }

    // ── In-directory search ──
    /** True while the search bar is shown in the Files tab. */
    var sftpSearchActive by mutableStateOf(false)
    var sftpSearchQuery by mutableStateOf("")
    /** Recursive = run `find` under the current directory host-side (results are full paths). */
    var sftpSearchRecursive by mutableStateOf(false); private set
    /** Wildcards = treat the query as a glob (`*`/`?`) instead of a plain substring. */
    var sftpSearchWildcard by mutableStateOf(false)
    /** Recursive search hits, or null when no recursive search has run. */
    var sftpSearchResults by mutableStateOf<List<SftpSearchHit>?>(null); private set
    var sftpSearchRunning by mutableStateOf(false); private set
    /** True when the recursive search stopped at [SFTP_SEARCH_MAX_HITS]. */
    var sftpSearchTruncated by mutableStateOf(false); private set

    // PORT SCANNER MODULE
    var portScannerTarget by mutableStateOf("")
    var portScannerRange by mutableStateOf("22,80,443,3000,5432,6379,8080,9000")
    var isPortScannerScanning by mutableStateOf(false)
    val portScannerResults = mutableStateListOf<Pair<Int, String>>()

    // DNS LOOKUP MODULE
    var dnsLookupTarget by mutableStateOf("")
    var dnsLookupType by mutableStateOf("A")
    var isDnsLookupRunning by mutableStateOf(false)
    val dnsLookupResults = mutableStateListOf<DnsRecord>()
    var dnsLookupError by mutableStateOf<String?>(null)

    // WHOIS MODULE
    var whoisTarget by mutableStateOf("")
    var isWhoisRunning by mutableStateOf(false)
    var whoisResult by mutableStateOf("")
    var whoisError by mutableStateOf<String?>(null)

    // SPEED TEST MODULE — HTTP download throughput against a chosen URL. Self-contained (no SSH
    // host needed); complements the SSH-driven iperf option below.
    // Named endpoints for the speed-test server dropdown. HTTPS only — targetSdk 36 blocks
    // cleartext HTTP. The URL field stays editable, so any custom endpoint still works.
    val speedTestServers: List<Pair<String, String>> = listOf(
        "Cloudflare — global anycast (50 MB)" to "https://speed.cloudflare.com/__down?bytes=52428800",
        "Cloudflare — global anycast (200 MB)" to "https://speed.cloudflare.com/__down?bytes=209715200",
        "Hetzner — Falkenstein, Germany (100 MB)" to "https://fsn1-speed.hetzner.com/100MB.bin",
        "Hetzner — Helsinki, Finland (100 MB)" to "https://hel1-speed.hetzner.com/100MB.bin",
        "Hetzner — Ashburn, US East (100 MB)" to "https://ash-speed.hetzner.com/100MB.bin",
        "OVH — Gravelines, France (100 MB)" to "https://proof.ovh.net/files/100Mb.dat",
        "Linode — Newark, US East (100 MB)" to "https://speedtest.newark.linode.com/100MB-newark.bin",
        "Linode — Fremont, US West (100 MB)" to "https://speedtest.fremont.linode.com/100MB-fremont.bin",
        "Linode — London, UK (100 MB)" to "https://speedtest.london.linode.com/100MB-london.bin",
        "Linode — Singapore (100 MB)" to "https://speedtest.singapore.linode.com/100MB-singapore.bin",
        "Linode — Mumbai, India (100 MB)" to "https://speedtest.mumbai1.linode.com/100MB-mumbai1.bin",
    )
    var speedTestUrl by mutableStateOf("https://speed.cloudflare.com/__down?bytes=52428800")
    var isSpeedTestRunning by mutableStateOf(false)
    var speedTestError by mutableStateOf<String?>(null)
    /** Live/last measured download rate, in megabits per second. */
    var speedTestMbps by mutableStateOf<Double?>(null)
    var speedTestBytes by mutableStateOf(0L)
    var speedTestLatencyMs by mutableStateOf<Long?>(null)
    private var speedTestJob: Job? = null

    // Single session-cached LAN sweep, shared by EVERYTHING that scans the local network: the Host
    // Scan tab and every host picker (Ping / Traceroute / Port Scan / Wake-on-LAN). All surfaces read
    // the rich ScannedHost directly. Whichever screen scans first fills the cache for all the others,
    // so we never run the same /24 sweep twice. In-memory only (per app session); an explicit rescan
    // or a stale cache refreshes it.
    var hostScanResults by mutableStateOf<List<ScannedHost>>(emptyList())
        private set
    var isLanScanInProgress by mutableStateOf(false)
        private set

    // When the shared cache was last filled. Pickers reuse cached results only while they're fresh;
    // past this window a "Scan LAN" tap re-sweeps so a tool never acts on a stale view of the network.
    var lastLanScanTime by mutableStateOf(0L)
        private set
    private val lanScanFreshnessMs = 5 * 60 * 1000L // 5 minutes

    /** True when the shared LAN cache holds results recent enough to reuse without re-scanning. */
    fun isLanScanFresh(): Boolean =
        hostScanResults.isNotEmpty() && System.currentTimeMillis() - lastLanScanTime < lanScanFreshnessMs

    /**
     * Run the shared LAN sweep and cache it for every screen, unless a usable cached sweep already
     * exists and [force] is false — in which case the cache is reused without re-scanning. Pass
     * [force] = true when the user explicitly taps Scan/Rescan. A scan already in flight is a no-op,
     * so concurrent callers from different tabs coalesce onto the one sweep.
     */
    suspend fun refreshLanScan(force: Boolean = false) {
        if (isLanScanInProgress) return
        // Reuse the cache only when it's still fresh. A non-forced call with stale results falls
        // through and re-sweeps, so pickers that reuse the cache never present an outdated network.
        if (!force && isLanScanFresh()) return
        isLanScanInProgress = true
        try {
            hostScanResults = scanHosts()
            lastLanScanTime = System.currentTimeMillis()
        } finally {
            isLanScanInProgress = false
        }
    }

    // TERMINAL EMULATOR SHELL STATE (interactive PTY shell)
    private val sshTransport: SshTransport = JschSshTransport()
    private var termCols = 80
    private var termRows = 24

    // Parallel multi-session management
    val activeSessions get() = TerminalSessionManager.activeSessions
    var restorablePersistentSessions by mutableStateOf<List<com.jetsetslow.omniterm.data.PersistentSessionEntity>>(emptyList()); private set
    var currentSessionId by mutableStateOf<String?>(null)
    val currentSession: ShellSession? get() = activeSessions.find { it.id == currentSessionId }

    // ── MultiSSH (split-screen) ──
    // activeSshTab: 0 = single-session terminal, 1 = split view with up to two panes.
    // Pane 1/2 track their own session ids; the focused pane receives keyboard + key-bar input.
    var activeSshTab by mutableStateOf(0)
    var multiSshSessionId1 by mutableStateOf<String?>(null)
    var multiSshSessionId2 by mutableStateOf<String?>(null)
    val multiSshSession1: ShellSession? get() = activeSessions.find { it.id == multiSshSessionId1 }
    val multiSshSession2: ShellSession? get() = activeSessions.find { it.id == multiSshSessionId2 }
    var multiSshLayout by mutableStateOf(com.jetsetslow.omniterm.ui.MultiSshLayout.SideBySide)
    var multiSshFocusedPane by mutableStateOf(1)
    private val pendingMultiSshConnections = ArrayDeque<Pair<Int, Int>>()

    val isMultiSsh: Boolean get() = activeSshTab == 1
    val focusedTerminalSession: ShellSession?
        get() = if (isMultiSsh) multiSshPaneSession(multiSshFocusedPane) else currentSession
    val terminalActionSession: ShellSession?
        get() = focusedTerminalSession ?: if (isMultiSsh) (multiSshSession1 ?: multiSshSession2) else null

    /** The session for [pane] (1 or 2), or null if that pane is empty. */
    fun multiSshPaneSession(pane: Int): ShellSession? = if (pane == 1) multiSshSession1 else multiSshSession2

    /**
     * Enter split view. Seeds pane 1 with the current single-session terminal (if any) and pane 2
     * with the next distinct active session, so a user who was already in a session lands in a
     * populated split rather than two empty panes. Focus starts on pane 1.
     */
    fun enterMultiSsh() {
        if (activeSshTab == 1) return
        val primary = currentSessionId
        multiSshSessionId1 = primary
        // Pane 2 defaults to another live session if one exists; otherwise it stays empty and shows
        // its own connect prompt.
        multiSshSessionId2 = activeSessions.firstOrNull { it.id != primary && it.isConnected }?.id
        multiSshFocusedPane = 1
        activeSshTab = 1
    }

    /** Leave split view. The focused pane's session becomes the single-session current session. */
    fun exitMultiSsh() {
        if (activeSshTab == 0) return
        pendingMultiSshConnections.clear()
        val keep = multiSshPaneSession(multiSshFocusedPane)?.id
            ?: multiSshSessionId1 ?: multiSshSessionId2
        activeSshTab = 0
        if (keep != null) currentSessionId = keep
        multiSshFocusedPane = 1
    }

    fun setMultiSshFocus(pane: Int) {
        if (pane != 1 && pane != 2) return
        multiSshFocusedPane = pane
        // Keep selectedServer in step with the focused pane so the header/connect prompt and any
        // "NEW SESSION → <server>" affordance target the pane the user is actually looking at.
        multiSshPaneSession(pane)?.let { selectedServerId = it.serverId }
    }

    fun swapMultiSshPanes() {
        val a = multiSshSessionId1
        multiSshSessionId1 = multiSshSessionId2
        multiSshSessionId2 = a
    }

    /** Assign an existing active session into a pane (used by the split-view session picker). */
    fun assignMultiSshPane(pane: Int, sessionId: String?) {
        if (pane != 1 && pane != 2) return
        val otherSessionId = if (pane == 1) multiSshSessionId2 else multiSshSessionId1
        // One PTY cannot own two independently sized/rendered panes. Keep the invariant in the
        // model as well as the picker so stale UI events cannot duplicate a session.
        if (sessionId != null && sessionId == otherSessionId) return
        if (pane == 1) multiSshSessionId1 = sessionId else multiSshSessionId2 = sessionId
        if (sessionId != null) setMultiSshFocus(pane)
    }

    /**
     * Open two selected hosts directly in split view. Existing live sessions are reused; any
     * missing sessions are connected one at a time because the SSH setup flow (including host-key
     * and tmux prompts) intentionally has a single foreground owner.
     */
    fun openMultiSshForServers(serverIds: List<Int>) {
        val selected = serverIds.distinct().take(2)
        if (selected.size != 2 || isTerminalConnecting) return

        pendingMultiSshConnections.clear()
        activeSshTab = 1
        multiSshSessionId1 = null
        multiSshSessionId2 = null
        multiSshFocusedPane = 1

        val assignedSessionIds = mutableSetOf<String>()
        selected.forEachIndexed { index, serverId ->
            val pane = index + 1
            val existing = activeSessions.firstOrNull {
                it.serverId == serverId && it.isConnected && it.id !in assignedSessionIds
            }
            if (existing != null) {
                assignedSessionIds.add(existing.id)
                if (pane == 1) multiSshSessionId1 = existing.id else multiSshSessionId2 = existing.id
            } else if (servers.value.any { it.id == serverId }) {
                pendingMultiSshConnections.addLast(pane to serverId)
            }
        }
        startNextMultiSshConnection()
    }

    private fun startNextMultiSshConnection() {
        if (isTerminalConnecting || !isMultiSsh) return
        while (pendingMultiSshConnections.isNotEmpty()) {
            val (pane, serverId) = pendingMultiSshConnections.removeFirst()
            if (multiSshPaneSession(pane) != null) continue
            val server = servers.value.find { it.id == serverId } ?: continue
            multiSshFocusedPane = pane
            selectedServerId = serverId
            connectTerminal(server, forceDisablePersistence = false) { connected ->
                if (connected) startNextMultiSshConnection() else pendingMultiSshConnections.clear()
            }
            return
        }
        multiSshFocusedPane = if (multiSshSession1 != null) 1 else 2
    }

    /** Clear a pane's session id when its session is torn down, so a stale id doesn't linger. */
    private fun clearMultiSshRefsFor(sessionId: String) {
        if (multiSshSessionId1 == sessionId) multiSshSessionId1 = null
        if (multiSshSessionId2 == sessionId) multiSshSessionId2 = null
    }

    val isTerminalConnected: Boolean get() = terminalActionSession?.isConnected == true
    var isTerminalConnecting by mutableStateOf(false)
    // Error from an initial connect that never produced a session (bad creds, host down, …). Unlike
    // [terminalDisconnectError] this isn't tied to a session, so it can surface on the connect prompt.
    var terminalConnectError by mutableStateOf<String?>(null)
    val terminalDisconnectError: String? get() = terminalActionSession?.disconnectError ?: terminalConnectError
    var hostKeyChangedServer by mutableStateOf<com.jetsetslow.omniterm.data.ServerEntity?>(null)
    // Set when the user asks to connect to a host whose last probe found the SSH port unreachable.
    // The status can be stale, so we warn-and-confirm rather than hard-block; null = no prompt.
    var offlineConnectPromptServer by mutableStateOf<com.jetsetslow.omniterm.data.ServerEntity?>(null)
    var pendingHostKeyApproval by mutableStateOf<com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest?>(null)
    // Approvals beyond the one on screen wait here (first fleet probe can surface several at
    // once); approveHostKey() pops the next so every blocked JSch thread eventually gets an answer.
    private val hostKeyApprovalQueue = ArrayDeque<com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest>()
    private val hostKeyApprovalOwner = Any()
    @Volatile private var acceptsHostKeyApprovals = true
    var terminalConnectionPhase by mutableStateOf("Connecting…")
    private var terminalConnectJob: kotlinx.coroutines.Job? = null
    // Monotonic ownership token: a cancelled blocking JSch attempt may unwind after a newer attempt
    // has started, but it must never clear or overwrite the newer attempt's UI/session state.
    private var terminalConnectGeneration = 0L

    // In-app review nudge: set once when the user's 3rd SSH session connects, consumed by
    // MainActivity which hands it to the flavor-specific review flow (no-op on openSource).
    var reviewPromptDue by mutableStateOf(false)
        private set
    private var sshSuccessCount = 0
    private var reviewPromptShown = false

    // Gates the first-run notification/battery prompts: they are deferred until the user has
    // gotten value from the app (first successful connection) instead of interrupting onboarding.
    var hasConnectedOnce by mutableStateOf(false)
        private set

    private fun noteSuccessfulSshSession() {
        hasConnectedOnce = true
        val count = ++sshSuccessCount
        viewModelScope.launch { repository.insertSetting("ssh_success_count", count.toString()) }
        if (count >= 3 && !reviewPromptShown) {
            reviewPromptShown = true
            viewModelScope.launch { repository.insertSetting("review_prompt_shown", "true") }
            reviewPromptDue = true
        }
    }

    fun onReviewPromptLaunched() {
        reviewPromptDue = false
    }

    // Terminal font size (sp). Adjustable from the on-screen UI and the hardware volume keys.
    var terminalFontSize by mutableStateOf(10)
        private set
    var terminalTheme by mutableStateOf("system")
        private set
    var terminalScrollbackLimit by mutableStateOf(10_000)
        private set
    var alertHistoryLimit by mutableStateOf(100)
        private set
    // Smart-swipe input: keep the current swiped word in the IME's buffer so gesture keyboards can
    // self-correct it, flushing to the terminal on space/enter/punctuation. Off (default) ⇒ the strict
    // empty-buffer path that streams every commit straight to the remote (max terminal fidelity, no
    // autocorrect) — so Tab-completion and backspace act on the live shell line immediately. It's an
    // opt-in feature for users who want gesture-keyboard self-correction at the cost of word buffering.
    var smartSwipeInput by mutableStateOf(false)
        private set

    fun saveSmartSwipeInput(enabled: Boolean) {
        smartSwipeInput = enabled
        viewModelScope.launch { repository.insertSetting("terminal_smart_swipe", enabled.toString()) }
    }

    // Tap-to-open hyperlink detection in the terminal. Best-effort regex matching on rendered
    // rows (soft-wrapped lines are re-joined first), so it can misfire on unusual output — hence
    // user-toggleable. On by default; when off, taps never open URLs and only focus the pane.
    var terminalLinkDetection by mutableStateOf(true)
        private set

    fun saveTerminalLinkDetection(enabled: Boolean) {
        terminalLinkDetection = enabled
        viewModelScope.launch { repository.insertSetting("terminal_link_detection", enabled.toString()) }
    }

    // tmux CONTROL MODE for persistent sessions (experimental). Attaches with `tmux -C` so tmux
    // streams every pane byte as structured %output events instead of rendering a client UI —
    // scrollback is complete by construction (a regular attach collapses fast output into a
    // repaint, losing rows nobody viewed). Applies to sessions opened after toggling.
    var tmuxControlMode by mutableStateOf(false)
        private set

    fun saveTmuxControlMode(enabled: Boolean) {
        tmuxControlMode = enabled
        viewModelScope.launch { repository.insertSetting("tmux_control_mode", enabled.toString()) }
    }

    // How tapped links open: true = in-app Chrome Custom Tab (page slides over the terminal, back
    // returns straight to it); false = hand off to the external browser app. Custom Tabs fall back
    // to an external open automatically when no capable browser is installed.
    var linkOpenInApp by mutableStateOf(true)
        private set

    fun saveLinkOpenInApp(enabled: Boolean) {
        linkOpenInApp = enabled
        viewModelScope.launch { repository.insertSetting("link_open_in_app", enabled.toString()) }
    }

    /** Flip swipe/stream input for the current session only — runtime, NOT persisted to settings. */
    fun toggleSmartSwipeRuntime() { smartSwipeInput = !smartSwipeInput }

    // The active terminal holds the current swipe word locally in its IME field (smart-swipe mode); it
    // hasn't reached the remote yet. Any out-of-band key — the on-screen key bar's TAB/arrows/ESC, a
    // symbol cap, a Ctrl/Alt combo — must commit that held word to the remote *first*, otherwise the
    // key acts on a shell line that's still missing the word (e.g. TAB completes nothing). The terminal
    // composable registers a flush here; sendKey()/typeText() invoke it before emitting their bytes.
    var pendingSwipeFlush: (() -> Unit)? = null

    fun adjustTerminalFontSize(deltaSp: Int) {
        val next = (terminalFontSize + deltaSp).coerceIn(8, 28)
        if (next == terminalFontSize) return
        saveTerminalFontSize(next)
    }

    fun saveTerminalFontSize(sizeSp: Int) {
        val next = sizeSp.coerceIn(8, 28)
        terminalFontSize = next
        viewModelScope.launch { repository.insertSetting("terminal_font_size", next.toString()) }
    }

    fun saveTerminalTheme(theme: String) {
        val next = if (theme in setOf("system", "omni_dark", "solarized_dark", "matrix", "light")) theme else "system"
        terminalTheme = next
        viewModelScope.launch { repository.insertSetting("terminal_theme", next) }
    }

    fun saveTerminalScrollbackLimit(limit: Int) {
        val next = limit.coerceIn(1_000, 50_000)
        terminalScrollbackLimit = next
        // Snapshot the list first: a background reconnect can add/remove sessions concurrently, and
        // iterating the live SnapshotStateList while it mutates would throw ConcurrentModification.
        activeSessions.toList().forEach { session ->
            synchronized(session.emulator) {
                session.emulator.setScrollbackLimit(next)
            }
            TerminalSessionManager.publishTerminalSnapshot(session)
        }
        viewModelScope.launch { repository.insertSetting("terminal_scrollback_limit", next.toString()) }
    }

    // App-wide text scale ("small" | "normal" | "large"), applied via the typography.
    var textScale by mutableStateOf("normal")
        private set

    fun saveTextScale(scale: String) {
        textScale = scale
        viewModelScope.launch { repository.insertSetting("text_scale", scale) }
    }

    var isAccessibilityEnabled by mutableStateOf(false)
        private set

    fun saveAccessibilityToggle(enabled: Boolean) {
        isAccessibilityEnabled = enabled
        viewModelScope.launch { repository.insertSetting("accessibility", enabled.toString()) }
    }

    /** Render snapshot the ShellScreen observes; replaced wholesale on each output batch. */
    val terminalScreen: TerminalSnapshot get() = currentSession?.terminalScreen ?: TerminalSnapshot.EMPTY

    // Sticky modifier keys driven by the on-screen key bar
    var isCtrlPressed by mutableStateOf(false)
    var isAltPressed by mutableStateOf(false)
    var isShiftPressed by mutableStateOf(false)
    var isFunctionSetVisible by mutableStateOf(false)

    // BACKGROUND KEEPALIVE BACKGROUND STATE SIMULATION
    val activeKeepaliveSessionsCount get() = TerminalSessionManager.activeKeepaliveSessionsCount

    // POLLE & RETRYS TASK LIFECYCLE
    private var pollingJob: Job? = null
    private val telemetryProbeLimiter = kotlinx.coroutines.sync.Semaphore(16)

    /** Telemetry refresh cadence (user-customisable), and the wall-clock start of the most recent
     *  cycle, so the UI can show a "next refresh in N" countdown that stays in sync with the poller.
     *  The running loop reads this each iteration, so changes take effect from the next cycle. */
    var telemetryIntervalMs by mutableStateOf(15_000L); private set
    var lastTelemetryStartMs by mutableStateOf(System.currentTimeMillis()); private set

    var settingsDirty by mutableStateOf(false)
    var showSettingsDiscardDialog by mutableStateOf(false)
    var isRefreshing by mutableStateOf(false)
    var isTestingConnection by mutableStateOf(false)
    var cronText by mutableStateOf(""); private set
    var cronStatus by mutableStateOf(""); private set
    var cronLoading by mutableStateOf(false); private set

    // Per-loader jobs so switching hosts cancels the previous (now-stale) fetch before starting a
    // new one — otherwise a slow old-host response can land last and overwrite the new host's data.
    private var dockerJob: Job? = null
    private var servicesJob: Job? = null
    private var logsJob: Job? = null
    private var hostMetricsJob: Job? = null
    private var processesJob: Job? = null
    private var cronJob: Job? = null
    private var sftpJob: Job? = null
    private var sftpSearchJob: Job? = null

    private val activeProbes = java.util.concurrent.ConcurrentHashMap<Int, kotlinx.coroutines.Job>()

    init {
        TerminalSessionManager.init(application)
        SshHostKeyTrust.init(application)
        SshHostKeyTrust.registerApprovalHandler(hostKeyApprovalOwner) { req ->
            if (!acceptsHostKeyApprovals) {
                req.deferred.complete(false)
                return@registerApprovalHandler
            }
            // A timed-out request must disappear from the dialog/queue even if nobody taps it.
            req.deferred.invokeOnCompletion {
                viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                    removeCompletedHostKeyApproval(req)
                }
            }
            viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                if (!acceptsHostKeyApprovals || req.deferred.isCompleted) {
                    req.deferred.complete(false)
                } else if (pendingHostKeyApproval == null) {
                    pendingHostKeyApproval = req
                } else {
                    hostKeyApprovalQueue.addLast(req)
                }
            }
        }
        // Reset all servers to offline on startup to avoid stale 'online' status.
        // Doing this once in init (at process/viewmodel start) avoids periodic performance hits.
        viewModelScope.launch(Dispatchers.IO) {
            repository.resetAllConnectionStates()
        }
        // Load settings, security configs, generate examples
        loadSecuritySettings()
        startTelemetryPolling()
        startNetworkShareAvailabilityProbe()

        viewModelScope.launch {
            restorablePersistentSessions = withContext(Dispatchers.IO) {
                repository.getPersistentSessions()
            }
        }

        // Auto-start is deliberately app-lifetime scoped: definitions start only after an explicit
        // opt-in, never during backup restore, and onCleared() tears every tunnel down.
        viewModelScope.launch {
            repository.getAllPortForwards().filter { it.autoStart }.forEach(::startTunnel)
        }

        // Bind a concrete selected host as soon as servers load. Without this, selectedServerId
        // stays null on cold start while selectedServer falls back to the first host — so per-tab
        // loaders whose "host changed mid-fetch" guard compares srv.id != selectedServerId bail out
        // and leave their spinner stuck (e.g. the Docker tab) until a host is picked manually.
        viewModelScope.launch {
            servers.collect { list ->
                if (selectedServerId == null && list.isNotEmpty()) {
                    selectedServerId = list.first().id
                }
            }
        }
    }

    override fun onCleared() {
        // Stop accepting first, then clear only this instance's registration. A handler already
        // copied by a racing JSch thread observes the flag and rejects instead of retaining this VM.
        acceptsHostKeyApprovals = false
        SshHostKeyTrust.clearApprovalHandler(hostKeyApprovalOwner)
        pendingHostKeyApproval?.deferred?.complete(false)
        pendingHostKeyApproval = null
        while (hostKeyApprovalQueue.isNotEmpty()) {
            hostKeyApprovalQueue.removeFirst().deferred.complete(false)
        }
        super.onCleared()
        runCatching { getApplication<Application>().unregisterReceiver(batteryReceiver) }
        stopPing()
        stopTraceroute()
        // Release pooled SSH sessions held by the transport when the ViewModel goes away.
        sshTransport.shutdown()
        // Release the warm SFTP sessions too (separate pool from the exec/stream transport).
        JschSftp.shutdownPool()
        // And the network-share browsing connection, if a browser was open.
        closeShareBrowserClient()
        // Tear down any live port-forward tunnels so their sockets don't leak.
        com.jetsetslow.omniterm.data.ssh.SshTunnelManager.stopAll()
    }

    // Ensures the cold-start lock is evaluated once, not on every settings write.
    private var coldStartLockEvaluated = false
    private fun loadSecuritySettings() {
        viewModelScope.launch {
            isFirstRun = repository.getSetting("first_run_complete") != "true"
        }
        viewModelScope.launch {
            // NOTE: allSettings is a StateFlow, so this collect body runs its first iteration
            // synchronously inside the ViewModel constructor (Main.immediate launches undispatched).
            // Every property assigned in here must be declared ABOVE the init block, or its
            // mutableStateOf delegate is still null and the app crashes on startup.
            allSettings.collect { list ->
                val pinVal = list.find { it.key == "app_pin" }?.value
                failedPinAttempts = list.find { it.key == "pin_failed_attempts" }
                    ?.value?.toIntOrNull()?.coerceIn(0, PIN_MAX_ATTEMPTS) ?: failedPinAttempts
                pinLockedUntilMs = list.find { it.key == "pin_locked_until" }
                    ?.value?.toLongOrNull()?.coerceAtLeast(0L) ?: pinLockedUntilMs
                val lockEnabled = list.find { it.key == "app_lock_enabled" }?.value == "true"
                val bioEnabled = list.find { it.key == "biometrics_enabled" }?.value == "true"
                val retentionVal = list.find { it.key == "metrics_retention" }?.value?.toIntOrNull() ?: 7
                val keepScreenOn = list.find { it.key == "keep_screen_on" }?.value == "true"
                val backgroundKeepAlive = list.find { it.key == "background_keep_alive" }?.value == "true"
                val darkModePref = list.find { it.key == "dark_mode" }?.value
                sftpLargeBatchFileThreshold = list.find { it.key == "sftp_large_batch_file_threshold" }
                    ?.value?.toIntOrNull()?.coerceIn(1, 10_000) ?: 50
                sftpLargeBatchBytesThreshold = list.find { it.key == "sftp_large_batch_bytes_threshold" }
                    ?.value?.toLongOrNull()?.coerceAtLeast(1_000_000_000L) ?: 1_000_000_000L
                if (list.isNotEmpty()) {
                    isFirstRun = list.find { it.key == "first_run_complete" }?.value != "true"
                }
                list.find { it.key == "terminal_font_size" }?.value?.toIntOrNull()?.let { terminalFontSize = it.coerceIn(8, 28) }
                terminalTheme = list.find { it.key == "terminal_theme" }?.value
                    ?.takeIf { it in setOf("system", "omni_dark", "solarized_dark", "matrix", "light") }
                    ?: "system"
                list.find { it.key == "terminal_scrollback_limit" }?.value?.toIntOrNull()?.let {
                    terminalScrollbackLimit = it.coerceIn(1_000, 50_000)
                }
                list.find { it.key == "terminal_smart_swipe" }?.value?.let {
                    smartSwipeInput = it == "true"
                }
                list.find { it.key == "terminal_link_detection" }?.value?.let {
                    terminalLinkDetection = it == "true"
                }
                list.find { it.key == "link_open_in_app" }?.value?.let {
                    linkOpenInApp = it == "true"
                }
                list.find { it.key == "tmux_control_mode" }?.value?.let {
                    tmuxControlMode = it == "true"
                }
                alertHistoryLimit = list.find { it.key == "alert_history_limit" }?.value
                    ?.toIntOrNull()?.coerceIn(10, 100) ?: 100
                batterySaverEnabled = list.find { it.key == "battery_saver_enabled" }?.value == "true"
                batterySaverThresholdPct = list.find { it.key == "battery_saver_threshold" }?.value
                    ?.toIntOrNull()?.coerceIn(5, 50) ?: 20
                list.find { it.key == "text_scale" }?.value?.let { textScale = it }
                list.find { it.key == "accessibility" }?.value?.let { isAccessibilityEnabled = it == "true" }
                list.find { it.key == "amoled" }?.value?.let { isAmoledEnabled = it == "true" }
                list.find { it.key == "sftp_sort" }?.value?.let { v ->
                    SftpSortOption.entries.firstOrNull { it.name == v }?.let { sftpSortOption = it }
                }
                list.find { it.key == "share_sort" }?.value?.let { v ->
                    SftpSortOption.entries.firstOrNull { it.name == v }?.let { shareSortOption = it }
                }
                list.find { it.key == "cross_paste_recurse" }?.value?.let { crossPasteRecurseFolders = it == "true" }
                list.find { it.key == "share_scan_protocols" }?.value?.let { v ->
                    val chosen = v.split(',').filter { it.isNotBlank() }
                    if (chosen.isNotEmpty()) {
                        networkShareScanProtocols.clear()
                        networkShareScanProtocols.addAll(chosen)
                    }
                }
                list.find { it.key == "editor_highlight_limit" }?.value?.toIntOrNull()
                    ?.let { editorHighlightLimit = clampHighlightLimit(it) }
                healthConfig = HealthScoringConfig.decode(list.find { it.key == "health_scoring" }?.value)
                list.find { it.key == "telemetry_interval" }?.value?.toIntOrNull()?.let {
                    telemetryIntervalMs = it.coerceIn(5, 300) * 1000L
                }
                sshSuccessCount = list.find { it.key == "ssh_success_count" }?.value?.toIntOrNull() ?: sshSuccessCount
                if (sshSuccessCount > 0) hasConnectedOnce = true
                reviewPromptShown = reviewPromptShown || list.find { it.key == "review_prompt_shown" }?.value == "true"
                homelabPresetsEnabled = list.find { it.key == "homelab_presets" }?.value == "true"
                alertsEnabled = list.find { it.key == "alerts_enabled" }?.value != "false"
                alertPresetsEnabled = list.find { it.key == "alert_presets" }?.value == "true"
                fleetPresetsEnabled = list.find { it.key == "fleet_presets" }?.value != "false"
                backupExportSelection = decodeBackupSelection(list.find { it.key == "backup_export_selection" }?.value)
                lastBackupExportTime = list.find { it.key == "backup_last_export_time" }?.value?.toLongOrNull() ?: 0L

                val hasPinLock = !pinVal.isNullOrBlank() && lockEnabled
                savedPin = pinVal
                isAppLockEnabled = hasPinLock
                appLockGraceMs = list.find { it.key == "app_lock_grace_ms" }?.value
                    ?.toLongOrNull()?.coerceAtLeast(0L) ?: APP_RELOCK_GRACE_MS
                useBiometrics = hasPinLock && bioEnabled
                // Screenshot blocking defaults on until explicitly set; terminal and credential
                // screens are sensitive even when the user has not configured an app lock.
                isFlagSecureEnabled = list.find { it.key == "flag_secure" }?.value
                    ?.toBooleanStrictOrNull() ?: true
                metricsRetentionDays = retentionVal
                if (!initialKeepScreenOnLoaded || defaultKeepScreenOn != keepScreenOn) {
                    defaultKeepScreenOn = keepScreenOn
                    isKeepScreenOnEnabled = keepScreenOn
                    initialKeepScreenOnLoaded = true
                }
                isBackgroundKeepAlive = backgroundKeepAlive
                TerminalSessionManager.isBackgroundKeepAlive = backgroundKeepAlive
                isDarkModeEnabled = darkModePref?.toBooleanStrictOrNull()

                // Lock the screen on the first REAL settings emission (cold start). The settings
                // flow starts with an empty initial value, so we must wait for actual rows to load
                // before deciding — otherwise we'd evaluate against an empty list and never lock.
                // Locking only once also prevents re-locking (and re-prompting biometrics) on every
                // later settings write.
                if (!coldStartLockEvaluated && list.isNotEmpty()) {
                    coldStartLockEvaluated = true
                    // Cold start: if app lock is enabled, demand the PIN/biometric on this relaunch.
                    if (shouldLockOnColdStart()) {
                        isAppLocked = true
                    }
                }

                if (backgroundKeepAlive && activeKeepaliveSessionsCount > 0) {
                    startKeepAliveService()
                }
            }
        }
    }


    // TELEMETRY POLLING: runs continuously every 10 seconds
    /** Recent CPU% samples per server id, for the Monitor/Fleet sparklines. */
    private val sparklineCache = mutableStateMapOf<Int, List<Float>>()

    // Per-host caches touched by the concurrent telemetry probes (distinct keys per host, but
    // concurrent resizes still demand thread-safe maps).
    private val osByServer = java.util.concurrent.ConcurrentHashMap<Int, String>()
    // Previous-poll raw counters per host, used to derive per-core CPU%, network, and disk-I/O rates.
    private val prevStatByServer = java.util.concurrent.ConcurrentHashMap<Int, Map<String, Pair<Long, Long>>>()
    private val prevNetByServer = java.util.concurrent.ConcurrentHashMap<Int, Pair<Long, Map<String, Pair<Long, Long>>>>()
    private val prevDiskByServer = java.util.concurrent.ConcurrentHashMap<Int, Pair<Long, Map<String, DiskIo>>>()

    /** TCP reachability probe; returns round-trip ms, or -1 if the host:port is unreachable. */
    private fun tcpReachable(host: String, port: Int, timeoutMs: Int = 4000): Int {
        return try {
            val t0 = System.currentTimeMillis()
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
            (System.currentTimeMillis() - t0).toInt()
        } catch (e: Exception) {
            -1
        }
    }

    /** Trim JSch/exec noise into a short, user-facing auth error. */
    /**
     * Turn a raw SSH/socket exception message into something a user can act on. Low-level transport
     * failures (a still-booting host, an unreachable network, a bad DNS name) otherwise surface as
     * cryptic Java exception text — or, when the message is blank, as nothing at all — which reads as
     * "it just failed silently." We classify the common cases explicitly and only fall back to the
     * trimmed raw text for genuinely unrecognized failures.
     */
    private fun cleanSshError(raw: String): String {
        val msg = raw.removePrefix("SSH Error:").trim()
        fun has(vararg needles: String) = needles.any { msg.contains(it, ignoreCase = true) }
        return when {
            has("Auth fail", "auth cancel", "USERAUTH fail") ->
                "Authentication failed (bad key or password)"
            has("Connection refused") ->
                "Connection refused — the server isn't accepting SSH yet (it may still be booting). Try again in a moment."
            has("timed out", "timeout", "socket is not established", "connection timed") ->
                "Connection timed out — the host didn't respond. Check it's powered on and reachable."
            has("UnknownHost", "Name or service not known", "nodename nor servname", "No address associated") ->
                "Host not found — check the hostname or IP address."
            has("Network is unreachable", "No route to host") ->
                "Network unreachable — the host can't be reached from this network."
            has("Connection reset", "Broken pipe", "connection closed by") ->
                "Connection dropped during handshake — the server may not be ready yet. Try again in a moment."
            has("reject HostKey", "HostKey has been changed") ->
                "Host key verification failed."
            msg.isBlank() -> "Connection failed — the host didn't respond as expected."
            else -> msg
        }
    }

    private fun healthFromMetrics(cpu: Float, ram: Float, disk: Float, rtt: Int): Int =
        healthConfig.score(cpu, ram, disk, rtt)

    /**
     * Per-host breakdown of the current health score (which metrics deducted points and why),
     * computed from the latest cached metrics + latency. Used by the score-ring click dialog.
     */
    fun healthBreakdown(server: ServerEntity): HealthBreakdown {
        val online = server.status == "online"
        val m = hostMetricsById[server.id] ?: HostMetrics.EMPTY
        return healthConfig.breakdown(
            cpu = m.cpuPercent, ram = m.memPercent, disk = m.diskPercent,
            rtt = server.lastLatency, online = online,
        )
    }

    /** Persist and apply edited health-scoring thresholds/weights. */
    fun saveHealthConfig(config: HealthScoringConfig) {
        healthConfig = config
        viewModelScope.launch { repository.insertSetting("health_scoring", config.encode()) }
    }

    fun resetHealthConfig() = saveHealthConfig(HealthScoringConfig.DEFAULT)

    fun updateBackupExportSelection(selection: BackupSelection) {
        val closed = selection.withReferentialClosure()
        backupExportSelection = closed
        viewModelScope.launch { repository.insertSetting("backup_export_selection", closed.encode()) }
    }

    // Real telemetry: TCP reachability + SSH metrics for every reachable host, concurrently.
    private fun startTelemetryPolling() {
        pollingJob?.cancel()
        activeProbes.values.forEach { it.cancel() }
        activeProbes.clear()

        pollingJob = viewModelScope.launch(Dispatchers.IO) {
            while (isActive) {
                // No hosts configured → don't run the refresh cycle at all (no probes, no countdown,
                // no pruning). Suspend until the first host is added (the in-memory servers flow
                // emits a non-empty list), so the timer comes alive on its own without burning a
                // DB read on a tick. addServer() also explicitly restarts polling as a belt-and-braces.
                if (servers.value.isEmpty()) {
                    servers.first { it.isNotEmpty() }
                }

                val currentServers = repository.getAllServers()
                if (currentServers.isEmpty()) { delay(telemetryIntervalMs); continue }

                // Mark the cycle start so the UI countdown timers can sync to the real cadence.
                withContext(Dispatchers.Main) { lastTelemetryStartMs = System.currentTimeMillis() }

                // Probe all hosts concurrently so a slow/unreachable host doesn't block others.
                // We use independent jobs so a slow probe doesn't block the global interval tick.
                for (srv in currentServers) {
                    if (activeProbes[srv.id]?.isActive != true) {
                        activeProbes[srv.id] = launch {
                            probeServer(srv)
                        }
                    }
                }

                val cutoff = System.currentTimeMillis() - (metricsRetentionDays * 24L * 60 * 60 * 1000)
                repository.pruneMetrics(cutoff)

                delay(telemetryIntervalMs)
            }
        }
    }

    /**
     * Probe a single host: TCP reachability, then real metrics over SSH (which also proves auth),
     * updating its connection/auth state and the shared metrics caches. Shared by the telemetry
     * loop and the per-host RETRY button so retrying one host doesn't re-probe the whole fleet.
     */
    /** Hosts that have completed at least one probe since process start. Until a host appears
     *  here its DB status is just the startup "offline" reset, so the UI shows "Checking…"
     *  instead of a misleading Offline. */
    val probedServerIds = androidx.compose.runtime.mutableStateMapOf<Int, Boolean>()

    private suspend fun probeServer(srv: ServerEntity) {
        try {
            // Make the periodic retry visible: an offline host shows "connecting" while its probe
            // runs (TCP reachability first — up to 4s — then SSH only if the port answered), instead
            // of silently sitting at Offline through the whole attempt.
            if (srv.status == "offline") {
                repository.updateConnectionState(srv.id, "connecting", 0, 0)
            }
            val rtt = tcpReachable(srv.host, srv.port)
            if (rtt < 0) {
                repository.updateConnectionState(srv.id, "offline", 0, 0)
                return
            }
            telemetryProbeLimiter.withPermit {
                probeServerInner(srv, rtt)
            }
        } catch (e: Exception) {
            repository.updateConnectionState(srv.id, "offline", 0, 0)
        } finally {
            withContext(Dispatchers.Main) { probedServerIds[srv.id] = true }
        }
    }

    private suspend fun probeServerInner(srv: ServerEntity, rtt: Int) {
        // Capture the selected host once: the live `selectedServerId` can change on the main thread
        // while this IO poll is in flight, and we must not attribute this host's metrics to whatever
        // host happens to be selected when the (slow) probe finally completes.
        val activeServerId = selectedServerId
        // Detect the remote OS once per host (cached), then run the matching metrics probe.
            val os = osByServer[srv.id] ?: run {
                val probe = executeSshCommand(srv, RemoteCommands.OS_PROBE)
                val detected = RemoteCommands.normaliseOs(probe)
                if (!probe.startsWith("SSH Error")) osByServer[srv.id] = detected
                detected
            }
            val raw = executeSshCommand(srv, RemoteCommands.metricsFor(os))
            if (raw.startsWith("SSH Error")) {
                repository.updateAuthState(srv.id, "failed", cleanSshError(raw))
                val health = (100 - healthConfig.latency.penaltyFor(rtt.toFloat())).coerceIn(0, 100)
                repository.updateConnectionState(srv.id, "online", health, rtt)
            } else {
                repository.updateAuthState(srv.id, "ok", null)
                val parsed = RemoteParsers.parseMetrics(raw, srv.name)
                // Per-core CPU% and per-interface network rates are derived from the delta between
                // this poll and the previous one for this host.
                val now = System.currentTimeMillis()
                val curStat = RemoteParsers.parseProcStat(raw)
                val prevStat = prevStatByServer[srv.id]
                val perCore = RemoteParsers.computePerCoreCpuDeltas(prevStat, curStat)
                val aggregateCpu = RemoteParsers.computeCpuUsageDelta(prevStat, curStat, "cpu")
                prevStatByServer[srv.id] = curStat
                val curNet = RemoteParsers.parseNetDev(raw)
                val prevNet = prevNetByServer[srv.id]
                // Linux gives per-interface counters (compute rates); BSD/macOS already supplied
                // netstat totals in `parsed.netInterfaces`, so keep those when /proc/net/dev is empty.
                val ifaces = if (curNet.isNotEmpty()) {
                    curNet.map { (name, cur) ->
                        val p = prevNet?.second?.get(name)
                        val dt = if (prevNet != null) (now - prevNet.first) / 1000.0 else 0.0
                        val rx = if (p != null && dt > 0) ((cur.first - p.first) / dt).toLong().coerceAtLeast(0) else 0L
                        val tx = if (p != null && dt > 0) ((cur.second - p.second) / dt).toLong().coerceAtLeast(0) else 0L
                        NetInterface(name, cur.first, cur.second, rx, tx)
                    }
                } else parsed.netInterfaces
                prevNetByServer[srv.id] = now to curNet
                // Disk I/O throughput (Linux /proc/diskstats) from the delta between polls.
                val curDisk = RemoteParsers.parseDiskIo(raw)
                val prevDisk = prevDiskByServer[srv.id]
                var dRead = 0L; var dWrite = 0L
                if (prevDisk != null) {
                    val dt = (now - prevDisk.first) / 1000.0
                    if (dt > 0) for ((dev, cur) in curDisk) {
                        val p = prevDisk.second[dev] ?: continue
                        dRead += ((cur.readBytes - p.readBytes) / dt).toLong().coerceAtLeast(0)
                        dWrite += ((cur.writeBytes - p.writeBytes) / dt).toLong().coerceAtLeast(0)
                    }
                }
                prevDiskByServer[srv.id] = now to curDisk
                val m = parsed.copy(
                    cpuPercent = aggregateCpu ?: parsed.cpuPercent,
                    perCoreCpu = perCore,
                    netInterfaces = ifaces,
                    diskReadPerSec = dRead, diskWritePerSec = dWrite,
                )
                val cpu = m.cpuPercent; val ram = m.memPercent; val disk = m.diskPercent
                // Store live metrics in the shared in-memory map so every screen (Servers tab,
                // Fleet, Monitor) can read without waiting for a separate SSH round-trip. Compose
                // snapshot state must be mutated on the main thread.
                withContext(Dispatchers.Main) { hostMetricsById[srv.id] = m }
                evaluateAlertRules(srv, cpu, ram, disk, rtt, m.disks)
                val health = healthFromMetrics(cpu, ram, disk, rtt)
                if (srv.id == activeServerId) {
                    // Drive the Monitor → Overview view directly from this poller so it doesn't
                    // run its own redundant SSH metrics loop.
                    withContext(Dispatchers.Main) { hostMetrics = m }
                    repository.insertMetric(
                        MetricHistoryEntity(
                            serverId = srv.id,
                            timestamp = System.currentTimeMillis(),
                            cpuUsage = cpu, ramUsage = ram, diskUsage = disk,
                            latency = rtt, networkIn = 0f, networkOut = 0f,
                        )
                    )
                }
                withContext(Dispatchers.Main) {
                    sparklineCache[srv.id] = (sparklineCache[srv.id].orEmpty() + cpu).takeLast(30)
                }
                repository.updateConnectionState(srv.id, "online", health, rtt)
            }
    }

    /**
     * Run a privileged action, optionally gated behind app-lock auth. When [srv] has a stored sudo
     * password AND an app lock (biometrics or PIN) is configured, we stage [block] in
     * [pendingSudoAction] so the UI can require confirmation before the password is used. With no
     * stored sudo password, or no app lock, we run immediately (the password, if any, is still used
     * by the command builders).
     */
    private fun withSudoAuth(srv: ServerEntity, block: () -> Unit) {
        val needsGate = srv.sudoPassword.isNotBlank() && (useBiometrics || savedPin != null)
        if (needsGate) pendingSudoAction = block else block()
    }

    /** Confirm the staged privileged action (called by the UI after successful biometric/PIN auth). */
    fun confirmPendingSudoAction() {
        val action = pendingSudoAction
        pendingSudoAction = null
        action?.invoke()
    }

    /** Abandon the staged privileged action (user cancelled the auth prompt). */
    fun cancelPendingSudoAction() {
        pendingSudoAction = null
    }

    /** Reboot the selected host (sudo). Streams output; the connection drops as it goes down. */
    fun rebootSelectedServer() {
        val srv = selectedServer ?: return
        withSudoAuth(srv) {
            runStreamingAction(
                "reboot · ${srv.name}",
                RemoteCommands.reboot(srv.sudoPassword),
                stdin = RemoteCommands.sudoStdin(srv.sudoPassword),
            )
        }
    }

    /** Retry a single host (used by the per-host RETRY button) without touching other hosts. */
    fun refreshServer(serverId: Int) {
        viewModelScope.launch(Dispatchers.IO) {
            repository.updateConnectionState(serverId, "connecting", 100, 0)
            val srv = repository.getAllServers().find { it.id == serverId } ?: return@launch
            probeServer(srv)
        }
    }

    // First time each (rule, host) pair was seen over threshold; cleared on recovery. The rule
    // only fires once the breach has lasted its triggerWindow, so single poll spikes don't alert.
    private val alertBreachSince = java.util.concurrent.ConcurrentHashMap<Pair<Int, Int>, Long>()

    private fun triggerWindowMs(window: String): Long =
        (window.trim().removeSuffix("m").toLongOrNull() ?: 0L) * 60_000L

    private suspend fun evaluateAlertRules(
        srv: ServerEntity, cpu: Float, ram: Float, disk: Float, latency: Int,
        mounts: List<DiskUsage> = emptyList(),
    ) {
        if (!alertsEnabled) return
        val rules = (repository.getRulesForServer(srv.id) + repository.getRulesForServer(0)).filter { it.enabled }
        val activeAlerts = repository.getActiveAlerts()
        val now = System.currentTimeMillis()
        for (r in rules) {
            // Disk rules check the rule's own mount point when we have per-mount data; the
            // aggregate figure is only a fallback for the root mount.
            val currentValue: Float? = when (r.metricName) {
                "CPU Usage" -> cpu
                "Memory Usage" -> ram
                "Disk Usage" -> mounts.find { it.mount == r.mountPoint }?.percent
                    ?: disk.takeIf { r.mountPoint.isBlank() || r.mountPoint == "/" }
                "Latency" -> latency.toFloat()
                else -> null
            }
            val breachKey = r.id to srv.id
            val overThreshold = currentValue != null && currentValue > r.thresholdValue
            val triggered = if (overThreshold) {
                val since = alertBreachSince.getOrPut(breachKey) { now }
                now - since >= triggerWindowMs(r.triggerWindow)
            } else {
                alertBreachSince.remove(breachKey)
                false
            }

            if (triggered) {
                // Check the incident for this rule on this concrete host. Global rules share the
                // same rule id across hosts, so serverId must be part of the match.
                val existing = activeAlerts.find { it.ruleId == r.id && it.serverId == srv.id }
                val currentlyActive = existing != null
                val isMuted = existing?.mutedUntil?.let { it > now } ?: false

                if (!currentlyActive && !isMuted) {
                    val alert = ActiveAlertEntity(
                        ruleId = r.id,
                        serverId = srv.id,
                        metricName = r.metricName,
                        currentValue = currentValue ?: 0f,
                        thresholdValue = r.thresholdValue,
                        severity = r.severity,
                        triggeredTime = now
                    )
                    repository.insertAlert(alert)
                    postAlertNotification(srv, r, currentValue ?: 0f)
                }
            } else if (!overThreshold) {
                // If it was firing but recovered, remove it
                val firingAlert = activeAlerts.find { it.ruleId == r.id && it.serverId == srv.id }
                if (firingAlert != null) {
                    recordAlertHistory(firingAlert, "resolved", srv.name)
                    repository.deleteAlert(firingAlert.id)
                    clearAlertNotification(r.id, srv.id)
                }
            }
        }
    }

    private fun alertNotificationId(ruleId: Int, serverId: Int) = "alert_${ruleId}_$serverId".hashCode()

    /** Surfaces a fired alert as a system notification so it's seen without the app open. */
    private fun postAlertNotification(srv: ServerEntity, rule: AlertRuleEntity, value: Float) {
        val app = getApplication<Application>()
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(app, android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        val nm = app.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL_ID, "Monitoring alerts", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        val openAppIntent = Intent(app, MainActivity::class.java)
        openAppIntent.setClass(app, MainActivity::class.java)
        openAppIntent.data = Uri.parse("omniterm://notification/alert/${rule.id}/${srv.id}")
        openAppIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val contentIntent = PendingIntent.getActivity(
            app, alertNotificationId(rule.id, srv.id), openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val mountSuffix = if (rule.metricName == "Disk Usage" && rule.mountPoint.isNotBlank()) " on ${rule.mountPoint}" else ""
        val unit = if (rule.metricName == "Latency") "ms" else "%"
        val n = NotificationCompat.Builder(app, ALERT_CHANNEL_ID)
            .setContentTitle("${rule.severity}: ${srv.name}")
            .setContentText("${rule.metricName}$mountSuffix at ${"%.0f".format(value)}$unit (threshold ${"%.0f".format(rule.thresholdValue)}$unit)")
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .build()
        nm.notify(alertNotificationId(rule.id, srv.id), n)
    }

    private fun clearAlertNotification(ruleId: Int, serverId: Int) {
        val app = getApplication<Application>()
        app.getSystemService(NotificationManager::class.java)?.cancel(alertNotificationId(ruleId, serverId))
    }

    // MULTI-SCREEN NAVIGATION ENGINE (custom, failsafe backstack)
    fun navigateTo(screen: Screen) {
        // Unsaved Settings changes must be saved or explicitly discarded before leaving.
        if (currentScreen == Screen.Settings && settingsDirty && screen != Screen.Settings) {
            pendingSettingsNavTarget = screen
            pendingSettingsBack = false
            showSettingsDiscardDialog = true
            return
        }
        // Tapping away from active connection SSH shell prompts verification first
        if (currentScreen == Screen.Shell && isTerminalConnected && screen != Screen.Shell) {
            pendingNavigationScreen = screen
            showDisconnectTerminalDialog = true
            return
        }

        if (screen == Screen.Servers) {
            screenHistory.clear()
            screenHistory.add(Screen.Servers)
        } else {
            if (screenHistory.contains(screen)) {
                val index = screenHistory.indexOf(screen)
                while (screenHistory.size > index + 1) {
                    screenHistory.removeAt(screenHistory.size - 1)
                }
            } else {
                screenHistory.add(screen)
            }
        }
        currentScreen = screen
    }

    // ── Swipe-to-switch tabs ──────────────────────────────────────────────────────
    // The bottom-nav order; swipe paging walks this list. Kept here so the gesture logic and the
    // bottom bar agree on adjacency (the bar's navItems list mirrors this order).
    val swipeNavOrder = listOf(
        Screen.Servers, Screen.Fleet, Screen.Monitor, Screen.Shell, Screen.SFTP, Screen.Infra, Screen.Tools,
    )

    /** Number of inner subtabs for a screen that supports horizontal subtab paging (0 = none). */
    private fun subtabCount(screen: Screen): Int = when (screen) {
        Screen.Monitor -> 6
        Screen.Infra -> 5
        Screen.Fleet -> 3
        Screen.SFTP -> 4
        Screen.Network -> 9
        Screen.Alerts -> 3
        Screen.QuickScripts -> 2
        else -> 0
    }

    private fun currentSubtab(screen: Screen): Int = when (screen) {
        Screen.Monitor -> activeMonitorTab
        Screen.Infra -> activeInfraTab
        Screen.Fleet -> fleetTabIndex
        Screen.SFTP -> activeSftpTab
        Screen.Network -> activeNetworkTab
        Screen.Alerts -> activeAlertsTab
        Screen.QuickScripts -> activeScriptsTab
        else -> 0
    }

    private fun setSubtab(screen: Screen, index: Int) {
        when (screen) {
            Screen.Monitor -> activeMonitorTab = index
            Screen.Infra -> activeInfraTab = index
            Screen.Fleet -> fleetTabIndex = index
            Screen.SFTP -> activeSftpTab = index
            Screen.Network -> activeNetworkTab = index
            Screen.Alerts -> activeAlertsTab = index
            Screen.QuickScripts -> activeScriptsTab = index
            else -> {}
        }
    }

    /**
     * Handle a horizontal swipe between tabs. A swipe first advances the inner subtab; when already
     * at the edge subtab it carries over to the adjacent top-level tab and lands on that tab's
     * entering-edge subtab (first subtab when swiping forward, last when swiping back). Screens
     * without subtabs just page top-level. [forward] = swipe from right to left (next).
     */
    fun swipeNavigate(forward: Boolean) {
        val screen = currentScreen
        val subCount = subtabCount(screen)
        if (subCount > 1) {
            val sub = currentSubtab(screen)
            val nextSub = if (forward) sub + 1 else sub - 1
            if (nextSub in 0 until subCount) {
                setSubtab(screen, nextSub)
                return
            }
        }
        // At a subtab edge (or no subtabs): move to the adjacent top-level tab.
        val idx = swipeNavOrder.indexOf(screen)
        if (idx == -1) return
        val nextIdx = if (forward) idx + 1 else idx - 1
        if (nextIdx !in swipeNavOrder.indices) return
        val target = swipeNavOrder[nextIdx]
        // Always land on the new tab's first subtab, regardless of swipe direction.
        if (subtabCount(target) > 1) setSubtab(target, 0)
        navigateTo(target)
    }

    // ── Settings staged-save / unsaved-changes guard ──
    private var pendingSettingsNavTarget: Screen? = null
    private var pendingSettingsBack = false

    /** Discard unsaved Settings changes and continue the navigation that was intercepted. */
    fun discardSettingsAndLeave() {
        settingsDirty = false
        showSettingsDiscardDialog = false
        val target = pendingSettingsNavTarget
        val back = pendingSettingsBack
        pendingSettingsNavTarget = null
        pendingSettingsBack = false
        if (back) navigateBack() else if (target != null) navigateTo(target)
    }

    fun cancelSettingsDiscard() {
        showSettingsDiscardDialog = false
        pendingSettingsNavTarget = null
        pendingSettingsBack = false
    }

    fun navigateBack(): Boolean {
        if (currentScreen == Screen.Settings && settingsDirty) {
            pendingSettingsBack = true
            pendingSettingsNavTarget = null
            showSettingsDiscardDialog = true
            return true
        }
        if (screenHistory.size > 1) {
            // Check terminal safety if on Shell currently
            if (currentScreen == Screen.Shell && isTerminalConnected) {
                pendingNavigationScreen = screenHistory[screenHistory.size - 2]
                showDisconnectTerminalDialog = true
                return true
            }

            screenHistory.removeAt(screenHistory.size - 1)
            currentScreen = screenHistory.last()
            return true
        }
        return false // Exits app or no custom route remaining
    }

    // PULL TO REFRESH INITIATION
    fun refreshAllServers() {
        // An explicit refresh while battery saver has polling paused is the user overriding the
        // saver — resume it fully rather than restarting polling behind the saver's back.
        if (batterySaverActive) resumeFromBatterySaver()
        viewModelScope.launch(Dispatchers.IO) {
            withContext(Dispatchers.Main) { isRefreshing = true }
            try {
                val list = repository.getAllServers()
                for (s in list) {
                    repository.updateConnectionState(s.id, "connecting", 100, 0)
                }
                delay(1200) // Small simulation lag for spinner fidelity
                startTelemetryPolling() // Restart polling immediately
            } finally {
                withContext(Dispatchers.Main) { isRefreshing = false }
            }
        }
    }

    fun refreshCurrentScreen() {
        when (currentScreen) {
            Screen.Servers, Screen.Fleet -> refreshAllServers()
            // Monitor refreshes what the active subtab is actually showing, not just host metrics.
            Screen.Monitor -> pullSpin {
                when (activeMonitorTab) {
                    1 -> loadProcesses()
                    2 -> loadServices()
                    3 -> loadLogs(logFilterType)
                    5 -> loadCron()
                    else -> selectedServer?.let { refreshServer(it.id) } // Overview / Scripts
                }
            }
            Screen.Infra -> pullSpin { loadDocker() }
            Screen.SFTP -> refreshSftpSubtab()
            // Alerts are evaluated on each metrics pass, so refreshing metrics refreshes alerts.
            Screen.Alerts -> refreshAllServers()
            // Pull-to-refresh is specific to the active Network subtab.
            Screen.Network -> refreshNetworkSubtab()
            // Remaining screens (Shell, Tools, Scripts, Keys, Backup, Settings…) show local/reactive
            // data with nothing remote to fetch; a spinner there would be theater.
            else -> {}
        }
    }

    /**
     * Wrap a fire-and-forget loader in the shared pull-to-refresh spinner. The loaders keep their
     * own fine-grained loading flags; this just acknowledges the pull gesture visibly (same
     * fixed-lag approach as refreshAllServers) so every tab responds consistently.
     */
    private fun pullSpin(work: () -> Unit) {
        viewModelScope.launch {
            isRefreshing = true
            try {
                work()
                delay(1200)
            } finally {
                isRefreshing = false
            }
        }
    }

    /**
     * Pull-to-refresh inside SFTP is scoped to the active subtab. The Shares tab either reloads the
     * open share folder or refreshes saved-share availability from the shares list.
     */
    private fun refreshSftpSubtab() {
        when (activeSftpTab) {
            0 -> pullSpin { loadSftp(clearError = true) }
            1 -> pullSpin {
                if (browsingShare != null) loadShareDir(sharePath, clearError = true)
                else refreshNetworkSharesAvailability()
            }
            else -> {}
        }
    }

    /**
     * Pull-to-refresh inside Network Tools, scoped to the active subtab:
     *  - Host Scan: re-sweep the LAN.
     *  - Wake-on-LAN: re-ping every target's status dot so the user can see if a woken host is back up.
     *  - Ping / Traceroute / Port Scan: re-run that action against the current target (no-op if it's
     *    blank or already running), so the pull repeats exactly the work that subtab does.
     */
    private fun refreshNetworkSubtab() {
        when (activeNetworkTab) {
            0 -> viewModelScope.launch {
                isRefreshing = true
                try { refreshLanScan(force = true) } finally { isRefreshing = false }
            }
            1 -> {
                // The dots do their own async ping; just nudge them and flash the spinner briefly so
                // the gesture feels acknowledged.
                wolStatusRefreshTick++
                viewModelScope.launch {
                    isRefreshing = true
                    delay(600)
                    isRefreshing = false
                }
            }
            2 -> if (!pingRunning && portScannerTarget.isNotBlank()) startPing(portScannerTarget, 4)
            3 -> if (!tracerouteRunning && portScannerTarget.isNotBlank()) startTraceroute(portScannerTarget)
            4 -> if (!isPortScannerScanning && portScannerTarget.isNotBlank()) runPortScanner()
            5 -> if (!isDnsLookupRunning && dnsLookupTarget.isNotBlank()) runDnsLookup()
            6 -> if (!isWhoisRunning && whoisTarget.isNotBlank()) runWhois()
            7 -> if (!isSpeedTestRunning) runSpeedTest()
        }
    }

    // PIN LOCK & SECURITY LOGIC
    private fun persistPinThrottle() {
        viewModelScope.launch {
            repository.insertSetting("pin_failed_attempts", failedPinAttempts.toString())
            repository.insertSetting("pin_locked_until", pinLockedUntilMs.toString())
        }
    }

    private fun resetPinThrottle() {
        failedPinAttempts = 0
        pinLockedUntilMs = 0L
        persistPinThrottle()
    }

    private fun migratePinHashAfterSuccess(pin: String) {
        if (savedPin?.startsWith(PIN_HASH_V2_PREFIX) == true) return
        val upgraded = hashPinForStorage(pin)
        savedPin = upgraded
        viewModelScope.launch { repository.insertSetting("app_pin", upgraded) }
    }

    fun handlePinTyping(digit: String) {
        if (isPinThrottled(pinLockedUntilMs, System.currentTimeMillis())) {
            lockScreenError = "Too many attempts — wait a moment"
            return
        }
        if (currentPinInput.length < 8) {
            currentPinInput += digit
        }

        // Automatic submission when digits entered match settings limits
        val targetLength = storedPinLength(savedPin) ?: savedPin?.length ?: 4
        if (currentPinInput.length >= targetLength) {
            submitPinCode()
        }
    }

    fun submitPinCode() {
        if (isPinThrottled(pinLockedUntilMs, System.currentTimeMillis())) {
            lockScreenError = "Too many attempts — wait a moment"
            return
        }
        if (verifyStoredPin(savedPin, currentPinInput)) {
            val verifiedPin = currentPinInput
            // Unlock app successfully
            isAppLocked = false
            currentPinInput = ""
            lockScreenError = null
            migratePinHashAfterSuccess(verifiedPin)
            resetPinThrottle()
        } else {
            failedPinAttempts += 1
            pinLockoutAfterFailure(failedPinAttempts, System.currentTimeMillis())
                .takeIf { it > 0L }?.let { pinLockedUntilMs = it }
            persistPinThrottle()
            // Trigger 600ms red flashing state
            lockScreenError = if (failedPinAttempts >= PIN_MAX_ATTEMPTS) "Too many attempts — wait 30 seconds" else "Incorrect PIN — try again"
            dotsFlashRed = true
            viewModelScope.launch {
                delay(600)
                dotsFlashRed = false
                currentPinInput = ""
            }
        }
    }

    fun verifyPin(pin: String): Boolean = verifyStoredPin(savedPin, pin)

    /**
     * PIN check for privileged in-app gates outside the lock screen (sudo mode, protected settings).
     * Shares the same throttling counter as app unlock so alternate PIN prompts cannot be brute-forced
     * independently.
     */
    fun verifyPinForSensitiveAction(pin: String): String? {
        val now = System.currentTimeMillis()
        if (isPinThrottled(pinLockedUntilMs, now)) return "Too many attempts — wait a moment"
        return if (verifyStoredPin(savedPin, pin)) {
            migratePinHashAfterSuccess(pin)
            resetPinThrottle()
            null
        } else {
            failedPinAttempts += 1
            pinLockoutAfterFailure(failedPinAttempts, now).takeIf { it > 0L }?.let { pinLockedUntilMs = it }
            persistPinThrottle()
            if (failedPinAttempts >= PIN_MAX_ATTEMPTS) "Too many attempts — wait 30 seconds" else "Incorrect PIN"
        }
    }

    fun completeFirstRun() {
        isFirstRun = false
        viewModelScope.launch {
            repository.insertSetting("first_run_complete", "true")
        }
    }

    fun removeDigit() {
        if (currentPinInput.isNotEmpty()) {
            currentPinInput = currentPinInput.substring(0, currentPinInput.length - 1)
        }
    }

    fun biometricSuccessUnlock() {
        isAppLocked = false
        currentPinInput = ""
        lockScreenError = null
    }

    // CRUDS FOR SERVERS
    fun addServer(name: String, host: String, port: Int, username: String, group: String?, authType: String, notes: String, keepAlive: Int, compression: Boolean, proxy: String, password: String? = null, keyAlias: String? = null, profileId: Int? = null, createProfile: Boolean = false, serverColor: String = "Default", sudoPassword: String = "", proxyType: String = "none", proxyHost: String = "", proxyPort: Int = 0, proxyUser: String = "", proxyPassword: String = "", proxyKeyAlias: String? = null, persistentSession: Boolean = false, agentForwarding: Boolean = false, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            // Username/password live on the credential profile when authType == "profile", so the
            // form leaves the username field greyed out and empty; only require it for the other
            // auth types where the user types credentials directly into this server.
            if (name.isBlank() || host.isBlank() || (authType != "profile" && username.isBlank())) {
                onResult("Please fill in all layout fields.")
                return@launch
            }
            if (authType == "profile" && profileId == null) {
                onResult("Select a credential profile.")
                return@launch
            }
            if (repository.getAllServers().size >= hostLimit) {
                onResult(hostLimitMessage())
                return@launch
            }
            val existing = repository.getServerByName(name)
            if (existing != null) {
                onResult("Server name must be unique.")
                return@launch
            }

            if (createProfile && authType == "password" && password != null && password.isNotBlank()) {
                // Mirror every other credential path: the free-tier limit counts profiles + keys combined.
                if (repository.getAllProfiles().size + repository.getAllKeys().size >= credentialProfileLimit) {
                    onResult(credentialProfileLimitMessage())
                    return@launch
                }
                val profileName = "$name profile"
                repository.insertProfile(CredentialProfileEntity(profileName = profileName, username = username, authType = "password", password = password))
            }

            val server = ServerEntity(
                name = name,
                host = host,
                port = port,
                username = username,
                groupName = group?.takeIf { it.isNotBlank() } ?: "Default",
                serverColor = serverColor,
                authType = authType,
                authPassword = password,
                sudoPassword = sudoPassword,
                authKeyAlias = keyAlias,
                authProfileId = profileId,
                notes = notes,
                keepAlive = keepAlive,
                sshCompression = compression,
                persistentSession = persistentSession,
                agentForwarding = agentForwarding,
                proxyCommand = proxy,
                proxyType = proxyType,
                proxyHost = proxyHost,
                proxyPort = proxyPort,
                proxyUser = proxyUser,
                proxyPassword = proxyPassword,
                proxyKeyAlias = proxyKeyAlias?.takeIf { it.isNotBlank() },
                status = "offline",
                authStatus = "unknown",
                authError = null,
            )
            val newId = repository.insertServer(server)
            onResult(null)
            // Start pessimistic: only promote reachability/auth after a real probe succeeds.
            withContext(Dispatchers.IO) {
                val rtt = tcpReachable(host, port)
                if (rtt < 0) {
                    repository.updateConnectionState(newId.toInt(), "offline", 0, 0)
                } else {
                    repository.updateConnectionState(newId.toInt(), "online", 100, rtt)
                    val saved = repository.getServerById(newId.toInt())
                    if (saved != null) {
                        val authErr = sshTransport.testConnection(buildCredentials(saved))
                        repository.updateAuthState(
                            newId.toInt(),
                            if (authErr == null) "ok" else "failed",
                            authErr?.let { cleanSshError(it) },
                        )
                    }
                }
            }
        }
    }

    fun updateServer(server: ServerEntity) {
        viewModelScope.launch {
            val previousCreds = repository.getServerById(server.id)?.let {
                runCatching { buildCredentials(it) }.getOrNull()
            }
            repository.updateServer(server)
            previousCreds?.let {
                sshTransport.forgetCredentials(it)
                JschSftp.forgetCredentials(it)
            }
        }
    }

    fun deleteServer(server: ServerEntity) {
        viewModelScope.launch {
            val creds = runCatching { buildCredentials(server) }.getOrNull()
            val sessions = activeSessions.filter { it.serverId == server.id }
            sessions.forEach {
                it.userClosed = true
                it.reconnectJob?.cancel()
            }
            var remoteTmuxKillFailed = false
            if (creds != null) {
                sessions.filter { it.persistent }.forEach { session ->
                    val kill = sshTransport.exec(creds, RemoteCommands.tmuxKillCommand(session.tmuxName))
                    if (kill.startsWith("SSH Error:") || remoteTmuxSessionExists(creds, session.tmuxName) != false) {
                        remoteTmuxKillFailed = true
                    }
                }
            }
            repository.getAllPortForwards().filter { it.serverId == server.id }.forEach { tunnel ->
                stopTunnel(tunnel.id)
            }
            sessions.forEach(::cleanupSession)
            creds?.let {
                sshTransport.forgetCredentials(it)
                JschSftp.forgetCredentials(it)
            }
            repository.deleteServerAndDependents(server.id)
            restorablePersistentSessions = restorablePersistentSessions.filter { it.serverId != server.id }
            SshHostKeyTrust.removeHost(server.host, server.port)
            if (selectedServerId == server.id) {
                selectedServerId = null
            }
            if (remoteTmuxKillFailed) {
                terminalConnectError =
                    "Host deleted locally, but at least one remote tmux session could not be confirmed stopped."
            }
        }
    }

    fun dismissHostKeyChangedDialog() { hostKeyChangedServer = null }

    fun approveHostKey(approved: Boolean) {
        val req = pendingHostKeyApproval ?: return
        pendingHostKeyApproval = nextPendingHostKeyApproval()
        req.deferred.complete(approved)
        if (!approved) {
            isTerminalConnecting = false
            terminalConnectError = "Host key rejected by user."
        }
    }

    private fun removeCompletedHostKeyApproval(req: com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest) {
        if (pendingHostKeyApproval === req) {
            pendingHostKeyApproval = nextPendingHostKeyApproval()
        } else {
            hostKeyApprovalQueue.remove(req)
        }
    }

    private fun nextPendingHostKeyApproval(): com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest? {
        while (true) {
            val next = hostKeyApprovalQueue.removeFirstOrNull() ?: return null
            if (!next.deferred.isCompleted) return next
        }
    }

    fun removeTrustedKeyAndRetry(server: com.jetsetslow.omniterm.data.ServerEntity) {
        SshHostKeyTrust.removeHost(server.host, server.port)
        hostKeyChangedServer = null
        connectTerminal()
    }

    // CRUDS FOR TOOLS SETUP
    fun generateSshKey(alias: String, type: String, onResult: (Boolean, String, String?, String?) -> Unit = { _, _, _, _ -> }) {
        viewModelScope.launch {
            var privKey: String? = null
            var pubKey: String? = null
            val result = withContext(Dispatchers.IO) {
                try {
                    if (alias.isBlank()) return@withContext Pair(false, "Key alias is required.")
                    if (repository.getAllKeys().any { it.alias == alias }) {
                        return@withContext Pair(false, "Key alias already exists.")
                    }
                    if (repository.getAllProfiles().size + repository.getAllKeys().size >= credentialProfileLimit) {
                        return@withContext Pair(false, credentialProfileLimitMessage())
                    }
                    val keyType = when (type.uppercase(Locale.US)) {
                        "RSA" -> KeyPair.RSA
                        else -> return@withContext Pair(false, "$type key generation is not supported by the bundled SSH library. Import an existing key instead.")
                    }
                    val keyPair = KeyPair.genKeyPair(JSch(), keyType, 4096)
                    val privateOut = ByteArrayOutputStream()
                    val publicOut = ByteArrayOutputStream()
                    try {
                        keyPair.writePrivateKey(privateOut)
                        keyPair.writePublicKey(publicOut, alias)
                    } finally {
                        keyPair.dispose()
                    }
                    val publicKey = publicOut.toString(Charsets.UTF_8.name()).trim()
                    val privateKey = privateOut.toString(Charsets.UTF_8.name())
                    val fingerprint = sshPublicKeyFingerprint(publicKey)
                    repository.insertKey(
                        SshKeyEntity(
                            alias = alias,
                            keyType = type,
                            privateKey = privateKey,
                            publicKey = publicKey,
                            fingerprint = fingerprint,
                        )
                    )
                    privKey = privateKey
                    pubKey = publicKey
                    Pair(true, "Generated $type key '$alias'.")
                } catch (e: Exception) {
                    Pair(false, "Key generation failed: ${e.message ?: "unknown error"}")
                }
            }
            onResult(result.first, result.second, privKey, pubKey)
        }
    }

    /**
     * Validate a pasted private key. Returns null if it parses (any type/format — RSA, OpenSSH,
     * ed25519, ECDSA, DSA, encrypted or not), or a human-readable reason it doesn't. Never leaks
     * JSch's raw "[B@…" byte-array dump.
     */
    private fun privateKeyParseError(privateStr: String): String? {
        val t = privateStr.trim()
        if (t.startsWith("ssh-rsa ") || t.startsWith("ssh-ed25519 ") ||
            t.startsWith("ecdsa-sha2-") || t.startsWith("ssh-dss ")
        ) {
            return "That's a public key. Paste the matching PRIVATE key (the file without the .pub extension)."
        }
        if (!t.contains("PRIVATE KEY")) {
            return "That doesn't look like a private key. Include the \"-----BEGIN ... PRIVATE KEY-----\" " +
                "and \"-----END ... PRIVATE KEY-----\" lines."
        }
        return try {
            // load() parses the key structure for every supported format and does NOT require the
            // passphrase (encrypted keys still load), so this accepts all key types.
            val kp = KeyPair.load(JSch(), (t + "\n").toByteArray(Charsets.UTF_8), null)
            kp.dispose()
            null
        } catch (e: Exception) {
            e.message?.takeUnless { it.contains("[B@") }?.let { "Invalid private key: $it" }
                ?: "Invalid private key — re-copy the full key text, including the BEGIN/END lines."
        }
    }

    /** Best-effort key-type label for display (the inner type of an OpenSSH container isn't in its header). */
    private fun detectKeyType(privateStr: String, publicStr: String): String = when {
        publicStr.startsWith("ssh-ed25519") -> "ED25519"
        publicStr.startsWith("ecdsa-") -> "ECDSA"
        publicStr.startsWith("ssh-rsa") -> "RSA"
        publicStr.startsWith("ssh-dss") -> "DSA"
        privateStr.contains("BEGIN RSA PRIVATE KEY") -> "RSA"
        privateStr.contains("BEGIN EC PRIVATE KEY") -> "ECDSA"
        privateStr.contains("BEGIN DSA PRIVATE KEY") -> "DSA"
        privateStr.contains("BEGIN OPENSSH PRIVATE KEY") -> "OpenSSH"
        else -> "SSH Key"
    }

    /**
     * Import a key. Only [privateStr] is required; [publicStr] is optional (derived when blank) and
     * [type] is auto-detected when blank. Any supported key format is accepted.
     */
    fun addSshKey(alias: String, type: String, privateStr: String, publicStr: String, onResult: (Boolean, String) -> Unit = { _, _ -> }) {
        viewModelScope.launch {
            if (repository.getAllProfiles().size + repository.getAllKeys().size >= credentialProfileLimit) {
                onResult(false, credentialProfileLimitMessage())
                return@launch
            }
            val result = withContext(Dispatchers.IO) {
                try {
                    if (alias.isBlank()) return@withContext Pair(false, "Key alias is required.")
                    val priv = privateStr.trim()
                    if (priv.isBlank()) return@withContext Pair(false, "Private key content is required.")
                    if (repository.getAllKeys().any { it.alias == alias }) {
                        return@withContext Pair(false, "Key alias already exists.")
                    }
                    // Reject unparseable keys up front with a clear reason (instead of a cryptic
                    // failure later at connect time).
                    privateKeyParseError(priv)?.let { return@withContext Pair(false, it) }

                    val pub = publicStr.trim()
                    val publicKey = pub.takeIf { it.startsWith("ssh-") || it.startsWith("ecdsa-") }
                        ?: publicKeyFromPrivate(priv)
                        ?: ""
                    val fingerprint = publicKey.takeIf { it.startsWith("ssh-") || it.startsWith("ecdsa-") }
                        ?.let { sshPublicKeyFingerprint(it) }
                        ?: keyMaterialFingerprint(priv)
                    val resolvedType = type.ifBlank { detectKeyType(priv, publicKey) }
                    repository.insertKey(
                        SshKeyEntity(
                            alias = alias,
                            keyType = resolvedType,
                            privateKey = priv,
                            publicKey = publicKey,
                            fingerprint = fingerprint,
                        )
                    )
                    Pair(true, "Imported $resolvedType key '$alias'.")
                } catch (e: Exception) {
                    val m = e.message?.takeUnless { it.contains("[B@") } ?: "unknown error"
                    Pair(false, "Key import failed: $m")
                }
            }
            onResult(result.first, result.second)
        }
    }

    private fun publicKeyFromPrivate(privateKey: String): String? = try {
        val keyPair = KeyPair.load(JSch(), (privateKey.trim() + "\n").toByteArray(Charsets.UTF_8), null)
        val out = ByteArrayOutputStream()
        try {
            keyPair.writePublicKey(out, "")
            out.toString(Charsets.UTF_8.name()).trim().takeIf { it.startsWith("ssh-") }
        } finally {
            keyPair.dispose()
        }
    } catch (_: Exception) {
        null
    }

    private fun sshPublicKeyFingerprint(publicKey: String): String {
        val blob = publicKey.trim().split(Regex("\\s+")).getOrNull(1)
            ?: return keyMaterialFingerprint(publicKey)
        val digest = MessageDigest.getInstance("SHA-256").digest(android.util.Base64.decode(blob, android.util.Base64.DEFAULT))
        return "SHA256:" + android.util.Base64.encodeToString(digest, android.util.Base64.NO_WRAP).trimEnd('=')
    }

    private fun keyMaterialFingerprint(keyMaterial: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(keyMaterial.toByteArray(Charsets.UTF_8))
        return "SHA256:" + android.util.Base64.encodeToString(digest, android.util.Base64.NO_WRAP).trimEnd('=')
    }

    fun addCredentialProfile(name: String, user: String, type: String, pass: String?, key: String?, onResult: (Boolean, String) -> Unit = { _, _ -> }) {
        viewModelScope.launch {
            if (repository.getAllProfiles().size + repository.getAllKeys().size >= credentialProfileLimit) {
                onResult(false, credentialProfileLimitMessage())
                return@launch
            }
            val profile = CredentialProfileEntity(
                profileName = name,
                username = user,
                authType = type,
                password = pass,
                keyAlias = key
            )
            repository.insertProfile(profile)
            onResult(true, "Saved profile '$name'.")
        }
    }

    /**
     * Update an existing SSH key. The alias may be renamed and the key material optionally
     * replaced ([newPrivate] blank = keep current material). Because servers and key-profiles
     * reference a key by its alias *string*, a rename cascades to those rows so existing hosts
     * don't silently lose their key.
     */
    fun updateSshKey(
        original: SshKeyEntity,
        newAlias: String,
        newPrivate: String,
        newPublic: String,
        onResult: (Boolean, String) -> Unit = { _, _ -> },
    ) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val alias = newAlias.trim()
                    if (alias.isBlank()) return@withContext Pair(false, "Key alias is required.")
                    if (repository.getAllKeys().any { it.alias == alias && it.id != original.id }) {
                        return@withContext Pair(false, "Key alias already exists.")
                    }
                    val priv = newPrivate.trim()
                    val updated = if (priv.isNotBlank()) {
                        // Re-validate and re-derive everything from the new material.
                        privateKeyParseError(priv)?.let { return@withContext Pair(false, it) }
                        val pub = newPublic.trim().takeIf { it.startsWith("ssh-") || it.startsWith("ecdsa-") }
                            ?: publicKeyFromPrivate(priv)
                            ?: ""
                        val fingerprint = pub.takeIf { it.startsWith("ssh-") || it.startsWith("ecdsa-") }
                            ?.let { sshPublicKeyFingerprint(it) }
                            ?: keyMaterialFingerprint(priv)
                        original.copy(
                            alias = alias,
                            keyType = detectKeyType(priv, pub),
                            privateKey = priv,
                            publicKey = pub,
                            fingerprint = fingerprint,
                        )
                    } else {
                        original.copy(alias = alias)
                    }
                    // insertKey uses REPLACE on the (preserved) primary key, so this is an update.
                    repository.insertKey(updated)
                    if (alias != original.alias) cascadeKeyAliasRename(original.alias, alias)
                    Pair(true, "Updated key '$alias'.")
                } catch (e: Exception) {
                    Pair(false, "Update failed: ${e.message?.takeUnless { it.contains("[B@") } ?: "unknown error"}")
                }
            }
            onResult(result.first, result.second)
        }
    }

    /** Repoint every server and key-profile that referenced [oldAlias] at [newAlias]. */
    private suspend fun cascadeKeyAliasRename(oldAlias: String, newAlias: String) {
        repository.getAllServers()
            .filter { it.authKeyAlias == oldAlias }
            .forEach { repository.updateServer(it.copy(authKeyAlias = newAlias)) }
        repository.getAllProfiles()
            .filter { it.keyAlias == oldAlias }
            .forEach { repository.insertProfile(it.copy(keyAlias = newAlias)) }
    }

    /**
     * Update a credential profile's name / username / password. Servers reference a profile by its
     * id (unchanged here), so no cascade is needed. A blank [newPass] keeps the existing password.
     */
    fun updateCredentialProfile(
        original: CredentialProfileEntity,
        newName: String,
        newUser: String,
        newPass: String,
        onResult: (Boolean, String) -> Unit = { _, _ -> },
    ) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                val name = newName.trim()
                val user = newUser.trim()
                if (name.isBlank()) return@withContext Pair(false, "Profile name is required.")
                if (user.isBlank()) return@withContext Pair(false, "Username is required.")
                if (repository.getAllProfiles().any { it.profileName == name && it.id != original.id }) {
                    return@withContext Pair(false, "Profile name already exists.")
                }
                val password = if (original.authType == "password") {
                    newPass.ifBlank { original.password }
                } else original.password
                repository.insertProfile(
                    original.copy(profileName = name, username = user, password = password)
                )
                Pair(true, "Updated profile '$name'.")
            }
            onResult(result.first, result.second)
        }
    }

    fun addAlertRule(serverId: Int, metricName: String, mountPoint: String, threshold: Float, severity: String, triggerWindow: String, notes: String = "") {
        viewModelScope.launch {
            val rule = AlertRuleEntity(
                serverId = serverId,
                metricName = metricName,
                mountPoint = mountPoint,
                thresholdValue = threshold,
                severity = severity,
                triggerWindow = triggerWindow,
                notes = notes,
            )
            repository.insertRule(rule)
        }
    }

    fun addQuickScript(
        emoji: String,
        name: String,
        command: String,
        color: String,
        longRunning: Boolean,
        category: String = "General",
        sortOrder: Int = 0,
        availableForQuick: Boolean = true,
        availableForFleet: Boolean = false,
        targetOs: String = "Any",
        targetSystem: String = "Any",
        notes: String = "",
    ) {
        viewModelScope.launch {
            val script = QuickScriptEntity(
                emoji = emoji,
                name = name,
                command = command,
                color = color,
                longRunning = longRunning,
                category = category,
                sortOrder = sortOrder,
                availableForQuick = availableForQuick,
                availableForFleet = availableForFleet,
                targetOs = targetOs,
                targetSystem = targetSystem,
                notes = notes,
            )
            repository.insertScript(script)
        }
    }

    // Editing reuses insert: OnConflictStrategy.REPLACE on the primary key updates the row in place.
    fun updateQuickScript(script: QuickScriptEntity) {
        viewModelScope.launch {
            repository.insertScript(script)
        }
    }

    fun deleteQuickScript(script: QuickScriptEntity) {
        viewModelScope.launch {
            repository.deleteScript(script)
        }
    }

    fun seedFleetPresetsIfMissing() {
        viewModelScope.launch {
            if (!fleetPresetsEnabled) return@launch
            if (repository.getSetting("fleet_presets_seeded") == "true") return@launch
            val existing = repository.getAllScripts()
                .filter { it.category == "Fleet" }
                .map { it.name.lowercase(Locale.ROOT) to it.command.trim() }
                .toSet()
            for (preset in builtInFleetPresets) {
                val key = preset.name.lowercase(Locale.ROOT) to preset.command.trim()
                if (key !in existing) repository.insertScript(preset)
            }
            repository.insertSetting("fleet_presets_seeded", "true")
        }
    }

    fun toggleFleetPresets(enabled: Boolean) {
        fleetPresetsEnabled = enabled
        viewModelScope.launch {
            repository.insertSetting("fleet_presets", enabled.toString())
            val presetKeys = builtInFleetPresets
                .map { it.name.lowercase(Locale.ROOT) to it.command.trim() }
                .toSet()
            if (enabled) {
                val existing = repository.getAllScripts()
                    .filter { it.category == "Fleet" }
                    .map { it.name.lowercase(Locale.ROOT) to it.command.trim() }
                    .toSet()
                for (preset in builtInFleetPresets) {
                    val key = preset.name.lowercase(Locale.ROOT) to preset.command.trim()
                    if (key !in existing) repository.insertScript(preset)
                }
                repository.insertSetting("fleet_presets_seeded", "true")
            } else {
                repository.getAllScripts()
                    .filter { it.category == "Fleet" && (it.name.lowercase(Locale.ROOT) to it.command.trim()) in presetKeys }
                    .forEach { repository.deleteScript(it) }
            }
        }
    }

    fun addFleetPreset(name: String, command: String) {
        addQuickScript("RUN", name.trim(), command.trim(), "cyan", false, "Fleet", sortOrder = 100, availableForQuick = false, availableForFleet = true)
    }

    fun updateFleetPreset(preset: QuickScriptEntity, name: String, command: String) {
        updateQuickScript(preset.copy(name = name.trim(), command = command.trim(), category = "Fleet", availableForFleet = true))
    }

    fun deleteFleetPreset(preset: QuickScriptEntity) {
        deleteQuickScript(preset)
    }

    /**
     * Curated read-mostly command snippets popular in the homelab community (Proxmox VE, CasaOS,
     * Home Assistant, Linux, plus general ops). Toggled on/off from Scripts.
     */
    private val homelabPresetScripts: List<QuickScriptEntity> = listOf(
        QuickScriptEntity(0, "PVE", "PVE: list VMs", "qm list", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "PCT", "PVE: list containers", "pct list", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "CLS", "PVE: cluster status", "pvecm status 2>/dev/null || echo 'standalone node'", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "STO", "PVE: storage status", "pvesm status", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "RUN", "PVE: start VM <id>", "qm start 100", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "STP", "PVE: stop VM <id>", "qm stop 100", "orange", false, "Proxmox"),
        QuickScriptEntity(0, "CAS", "CasaOS: status", "systemctl status 'casaos*' --no-pager 2>&1 | head -40", "green", false, "CasaOS"),
        QuickScriptEntity(0, "RST", "CasaOS: restart", "sudo systemctl restart 'casaos*'", "green", false, "CasaOS"),
        QuickScriptEntity(0, "VER", "CasaOS: version", "casaos -v 2>/dev/null || cat /etc/casaos/* 2>/dev/null | head", "green", false, "CasaOS"),
        QuickScriptEntity(0, "HA", "HA: info", "ha info 2>/dev/null || docker ps --filter name=homeassistant", "cyan", false, "Home Assistant"),
        QuickScriptEntity(0, "LOG", "HA: core logs", "ha core logs 2>/dev/null || docker logs --tail 100 homeassistant 2>&1", "cyan", false, "Home Assistant"),
        QuickScriptEntity(0, "RST", "HA: restart core", "ha core restart 2>/dev/null || docker restart homeassistant", "cyan", false, "Home Assistant"),
        QuickScriptEntity(0, "SUP", "HA: supervisor logs", "ha supervisor logs 2>/dev/null | tail -100", "cyan", false, "Home Assistant"),
        QuickScriptEntity(0, "TMP", "Temperature", "if [ \"\$(uname -s 2>/dev/null)\" = Linux ]; then max=\"\"; for f in /sys/class/thermal/thermal_zone*/temp; do [ -r \"\$f\" ] || continue; v=\$(cat \"\$f\" 2>/dev/null); case \"\$v\" in ''|*[!0-9]*) continue;; esac; [ -z \"\$max\" ] || [ \"\$v\" -gt \"\$max\" ] && max=\"\$v\"; done; if [ -n \"\$max\" ]; then awk -v t=\"\$max\" 'BEGIN { printf \"CPU %.1f°C\\n\", t / 1000 }'; elif command -v vcgencmd >/dev/null 2>&1; then vcgencmd measure_temp; else echo \"No thermal sensor exposed\"; fi; else echo \"Temperature preset supports Linux hosts\"; fi", "red", false, "Linux"),
        QuickScriptEntity(0, "UPD", "Updates available", "apt list --upgradable 2>/dev/null | tail -n +2 || (command -v dnf >/dev/null && dnf check-update)", "amber", false, "Homelab"),
        QuickScriptEntity(0, "RBT", "Reboot required?", "test -f /var/run/reboot-required && echo 'reboot required' || echo 'no reboot needed'", "amber", false, "Homelab"),
        QuickScriptEntity(0, "CPU", "Top 10 by CPU", "ps aux --sort=-%cpu | head -11", "purple", false, "Homelab"),
        QuickScriptEntity(0, "CTR", "Docker stats", "docker stats --no-stream 2>/dev/null || podman stats --no-stream", "purple", false, "Homelab"),
        QuickScriptEntity(0, "DSK", "Disk usage", "df -h | grep -vE 'tmpfs|udev'", "purple", false, "Homelab"),
    )

    /** Enable/disable the homelab preset scripts. Disabling removes the (default) presets. */
    fun toggleHomelabPresets(enabled: Boolean) {
        homelabPresetsEnabled = enabled
        viewModelScope.launch {
            repository.insertSetting("homelab_presets", enabled.toString())
            if (enabled) {
                val presetNames = homelabPresetScripts.map { it.name }.toSet()
                repository.getAllScripts().filter { it.name in presetNames }.forEach { repository.deleteScript(it) }
                for (p in homelabPresetScripts) repository.insertScript(p)
            } else {
                val names = homelabPresetScripts.map { it.name }.toSet()
                repository.getAllScripts().filter { it.name in names }.forEach { repository.deleteScript(it) }
            }
        }
    }

    /** Default alert-rule presets applied to every host: CPU/memory/disk/latency thresholds. */
    private val alertRulePresets = listOf(
        Triple("CPU Usage", 90f, "CRITICAL"),
        Triple("Memory Usage", 90f, "CRITICAL"),
        Triple("Disk Usage", 90f, "WARNING"),
        Triple("Latency", 250f, "WARNING"),
    )

    // ── Backup default-filtering ──────────────────────────────────────────────────────────────────
    // A backup should preserve what the user CREATED or CHANGED — not the app's own seeded presets,
    // which are re-seeded automatically on a fresh install. We identify a preset by its name; if the
    // stored row still matches the preset's original command/threshold it's pristine (skip it). If the
    // command/threshold differs, the user edited it, so it's effectively custom and we keep it.

    /** Original command for a built-in/homelab preset script keyed by name, or null if not a preset. */
    private val presetScriptOriginalCommands: Map<String, String> by lazy {
        (builtInFleetPresets + homelabPresetScripts)
            .associate { it.name.lowercase(Locale.ROOT) to it.command.trim() }
    }

    /**
     * True when [script] is an untouched copy of a seeded preset: same name + same command AND no
     * user note. Adding a note counts as customizing it, so a noted preset is kept in the backup.
     */
    private fun isPristineDefaultScript(script: QuickScriptEntity): Boolean =
        script.notes.isBlank() &&
            presetScriptOriginalCommands[script.name.lowercase(Locale.ROOT)] == script.command.trim()

    /** Keep only user-created or user-edited scripts; drop pristine seeded presets. */
    private fun customScriptsOnly(scripts: List<QuickScriptEntity>): List<QuickScriptEntity> =
        scripts.filterNot { isPristineDefaultScript(it) }

    /** True when [rule] is an untouched fleet-wide (serverId=0) default alert preset (no user note). */
    private fun isPristineDefaultRule(rule: AlertRuleEntity): Boolean =
        rule.serverId == 0 && rule.notes.isBlank() && alertRulePresets.any { (metric, threshold, severity) ->
            rule.metricName == metric && rule.thresholdValue == threshold &&
                rule.severity == severity && rule.mountPoint == "/"
        }

    /** Keep only user-created or user-edited alert rules; drop pristine default presets. */
    private fun customRulesOnly(rules: List<AlertRuleEntity>): List<AlertRuleEntity> =
        rules.filterNot { isPristineDefaultRule(it) }

    /** Enable/disable the default alert rules across all current hosts. */
    fun toggleAlertPresets(enabled: Boolean) {
        alertPresetsEnabled = enabled
        viewModelScope.launch {
            repository.insertSetting("alert_presets", enabled.toString())
            if (enabled) {
                val existing = repository.getRulesForServer(0)
                for ((metric, threshold, severity) in alertRulePresets) {
                    if (existing.none { it.metricName == metric && it.thresholdValue == threshold }) {
                        repository.insertRule(AlertRuleEntity(serverId = 0, metricName = metric, thresholdValue = threshold, severity = severity))
                    }
                }
            } else {
                val sigs = alertRulePresets.map { it.first to it.second }.toSet()
                repository.getAllRules().filter { it.serverId == 0 && (it.metricName to it.thresholdValue) in sigs }.forEach { repository.deleteRule(it) }
            }
        }
    }

    fun addWolTarget(name: String, mac: String, broadcast: String, ip: String, port: Int, notes: String) {
        viewModelScope.launch {
            if (name.isBlank() || !isValidMac(mac) || broadcast.isBlank() || port !in 1..65535) return@launch
            val tar = WolTargetEntity(
                name = name.trim(),
                macAddress = mac.trim(),
                broadcastIp = broadcast,
                ipAddress = ip.trim(),
                port = port,
                notes = notes
            )
            repository.insertWolTarget(tar)
        }
    }

    fun updateWolTarget(target: WolTargetEntity, name: String, mac: String, broadcast: String, ip: String, port: Int, notes: String) {
        viewModelScope.launch {
            if (name.isBlank() || !isValidMac(mac) || broadcast.isBlank() || port !in 1..65535) return@launch
            repository.insertWolTarget(
                target.copy(
                    name = name.trim(),
                    macAddress = mac.trim(),
                    broadcastIp = broadcast.trim(),
                    ipAddress = ip.trim(),
                    port = port,
                    notes = notes,
                )
            )
        }
    }

    /**
     * Best-effort liveness probe for a WoL target's host IP, mirroring the LAN scanner: try ICMP
     * reachability first, and if that's filtered (common on Android/Wi-Fi), fall back to the kernel
     * ARP cache (an entry there means the host answered an ARP and is up). Returns false for a blank
     * IP or any error. Runs on IO; safe to call from a polling loop.
     */
    suspend fun pingWolHost(ip: String): Boolean = withContext(Dispatchers.IO) {
        val target = ip.trim()
        if (target.isBlank()) return@withContext false
        try {
            if (java.net.InetAddress.getByName(target).isReachable(800)) return@withContext true
        } catch (_: Exception) {
            // fall through to ARP-cache check
        }
        try {
            java.io.File("/proc/net/arp").useLines { lines ->
                lines.drop(1).any { line ->
                    val cols = line.trim().split(Regex("\\s+"))
                    cols.isNotEmpty() && cols[0] == target &&
                        cols.size >= 4 && cols[3] != "00:00:00:00:00:00"
                }
            }
        } catch (_: Exception) {
            false
        }
    }

    fun deleteWolTarget(target: WolTargetEntity) {
        viewModelScope.launch {
            repository.deleteWolTarget(target)
        }
    }

    data class ScannedWolDevice(val name: String, val mac: String, val ip: String, val isOnline: Boolean)

    /**
     * A discovered host with as much best-effort detail as the OS exposes: reverse-DNS hostname,
     * MAC (from the kernel ARP cache) + a guessed vendor from the OUI prefix, and which of a short
     * list of common TCP ports answered. Everything beyond [ip]/[isOnline] may be blank/empty.
     */
    data class ScannedHost(
        val ip: String,
        val isOnline: Boolean,
        val hostname: String = "",
        val mac: String = "",
        val vendor: String = "",
        val openPorts: List<Int> = emptyList(),
    )

    /** Common ports probed during a host scan (kept short so a full /24 sweep stays fast). */
    private val hostScanPorts = listOf(22, 80, 443, 445, 3389, 5900, 8080)

    /**
     * Best-effort OUI (MAC prefix) → vendor map for the most common devices on a home/office LAN.
     * Not exhaustive — this is a hint, not authoritative. Keys are the first 3 MAC octets, uppercase.
     */
    private val ouiVendors: Map<String, String> = mapOf(
        "B8:27:EB" to "Raspberry Pi", "DC:A6:32" to "Raspberry Pi", "E4:5F:01" to "Raspberry Pi",
        "28:CD:C1" to "Raspberry Pi",
        "00:1A:11" to "Google", "F4:F5:E8" to "Google", "DA:A1:19" to "Google",
        "EC:FA:BC" to "Espressif", "24:0A:C4" to "Espressif", "A0:20:A6" to "Espressif",
        "FC:FB:FB" to "Apple", "AC:DE:48" to "Apple", "F0:18:98" to "Apple", "A4:83:E7" to "Apple",
        "00:1B:63" to "Apple", "3C:15:C2" to "Apple",
        "44:D9:E7" to "Ubiquiti", "FC:EC:DA" to "Ubiquiti", "78:8A:20" to "Ubiquiti",
        "00:50:56" to "VMware", "08:00:27" to "VirtualBox", "52:54:00" to "QEMU/KVM",
        "00:15:5D" to "Microsoft Hyper-V",
    )

    private fun vendorForMac(mac: String): String {
        if (mac.length < 8) return ""
        return ouiVendors[mac.substring(0, 8).uppercase(Locale.ROOT)] ?: ""
    }

    /**
     * Active subnet sweep returning richly-detailed [ScannedHost]s: ping every host on the local /24
     * concurrently, then best-effort enrich each reachable IP with a reverse-DNS hostname, a MAC from
     * the kernel ARP table (+ guessed vendor), and a quick probe of [hostScanPorts]. Modern Android
     * blocks `ip neigh` / `/proc/net/arp` reads in many cases, so MAC may be blank; the active probe
     * still surfaces live hosts regardless.
     */
    // Private so all callers go through refreshLanScan()'s shared cache — there's no second path that
    // could kick off a duplicate /24 sweep.
    private suspend fun scanHosts(): List<ScannedHost> = withContext(Dispatchers.IO) {
        val online = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val macs = java.util.concurrent.ConcurrentHashMap<String, String>()
        try {
            // Find this device's IPv4 + prefix to derive the /24 base (e.g. 192.168.11.x).
            val local = java.net.NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.interfaceAddresses }
                .firstOrNull { it.address is java.net.Inet4Address && !it.address.isLoopbackAddress }
                ?: return@withContext emptyList()
            val ip = local.address.hostAddress ?: return@withContext emptyList()
            val base = ip.substringBeforeLast('.')

            // Ping all 254 hosts with bounded concurrency (isReachable issues ICMP/echo where permitted).
            val limiter = Semaphore(64)
            (1..254).map { i ->
                async {
                    limiter.withPermit {
                        val target = "$base.$i"
                        try {
                            if (java.net.InetAddress.getByName(target).isReachable(400)) online.add(target)
                        } catch (_: Exception) {}
                    }
                }
            }.awaitAll()

            // Best-effort MAC enrichment from the ARP table (silently empty if unreadable).
            try {
                java.io.File("/proc/net/arp").takeIf { it.exists() }?.bufferedReader()?.useLines { lines ->
                    lines.drop(1).forEach { line ->
                        val parts = line.split("\\s+".toRegex())
                        if (parts.size >= 4) {
                            val pIp = parts[0]; val mac = parts[3]
                            if (mac.length == 17 && mac != "00:00:00:00:00:00") {
                                macs[pIp] = mac
                                online.add(pIp) // in the ARP cache ⇒ reachable, even if ping was filtered
                            }
                        }
                    }
                }
            } catch (_: Exception) {}

            // Enrich each live host with rDNS hostname + open common ports (bounded concurrency).
            online.map { host ->
                async {
                    limiter.withPermit {
                        val hostname = try {
                            java.net.InetAddress.getByName(host).canonicalHostName.takeIf { it != host } ?: ""
                        } catch (_: Exception) { "" }
                        val open = hostScanPorts.filter { port ->
                            try {
                                java.net.Socket().use { s ->
                                    s.connect(java.net.InetSocketAddress(host, port), 250); true
                                }
                            } catch (_: Exception) { false }
                        }
                        host to (hostname to open)
                    }
                }
            }.awaitAll().associate { it }.let { enriched ->
                return@withContext online.map { host ->
                    val (hostname, open) = enriched[host] ?: ("" to emptyList())
                    val mac = macs[host] ?: ""
                    ScannedHost(
                        ip = host, isOnline = true, hostname = hostname,
                        mac = mac, vendor = vendorForMac(mac), openPorts = open,
                    )
                }.sortedBy { it.ip.substringAfterLast('.').toIntOrNull() ?: 0 }
            }
        } catch (_: Exception) {}
        emptyList()
    }

    // [onResult] is invoked on the main thread with whether the magic packet actually went out, so the
    // caller can show honest user feedback (a Toast) — never claim "sent" when validation or the socket
    // send failed.
    fun triggerWol(target: WolTargetEntity, onResult: ((Boolean) -> Unit)? = null) {
        viewModelScope.launch {
            if (!isValidMac(target.macAddress) || target.port !in 1..65535 || target.broadcastIp.isBlank()) {
                onResult?.invoke(false)
                return@launch
            }
            val ok = try {
                kotlinx.coroutines.withContext(Dispatchers.IO) {
                    val macBytes = getMacBytes(target.macAddress)
                    val bytes = ByteArray(6 + 16 * macBytes.size)
                    for (i in 0..5) bytes[i] = 0xff.toByte()
                    for (i in 6 until bytes.size step macBytes.size) {
                        System.arraycopy(macBytes, 0, bytes, i, macBytes.size)
                    }
                    val address = java.net.InetAddress.getByName(target.broadcastIp)
                    val packet = java.net.DatagramPacket(bytes, bytes.size, address, target.port)
                    val socket = java.net.DatagramSocket()
                    socket.broadcast = true
                    socket.send(packet)
                    socket.close()
                }
                repository.updateLastWoken(target.id, System.currentTimeMillis())
                true
            } catch (e: Exception) {
                // Invalid network/broadcast state should not crash or fake a successful wake.
                false
            }
            onResult?.invoke(ok)
        }
    }

    private fun isValidMac(macStr: String): Boolean =
        Regex("""^[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(\1[0-9A-Fa-f]{2}){4}$""").matches(macStr.trim())

    private fun getMacBytes(macStr: String): ByteArray {
        val bytes = ByteArray(6)
        val hex = macStr.split(":", "-")
        if (hex.size != 6) return bytes
        for (i in 0..5) {
            bytes[i] = Integer.parseInt(hex[i], 16).toByte()
        }
        return bytes
    }

    /** Run a saved quick-script command on the selected host; returns combined stdout/stderr. */
    suspend fun runQuickScript(command: String): String {
        val srv = selectedServer ?: return "No server selected."
        return executeSshCommand(srv, command)
    }

    // BULK SELECTIONS & OPERATIONS
    fun toggleBulkSelectServer(id: Int) {
        if (selectedServerIdsForBulk.contains(id)) {
            selectedServerIdsForBulk.remove(id)
        } else {
            selectedServerIdsForBulk.add(id)
        }
    }

    fun selectAllServers() {
        selectedServerIdsForBulk.clear()
        selectedServerIdsForBulk.addAll(servers.value.map { it.id })
    }

    fun clearBulkSelect() {
        selectedServerIdsForBulk.clear()
        isMultiSelectMode = false
    }

    fun assignGroupToBulk(groupName: String) {
        viewModelScope.launch {
            servers.value.forEach { srv ->
                if (selectedServerIdsForBulk.contains(srv.id)) {
                    repository.updateServer(srv.copy(groupName = groupName.ifBlank { "Default" }))
                }
            }
            clearBulkSelect()
        }
    }

    fun startKeepAliveService() = TerminalSessionManager.startKeepAliveService()
    fun stopKeepAliveService() = TerminalSessionManager.stopKeepAliveService()

    // ── SSH TERMINAL (interactive PTY shell) ──

    /** Resolve a [ServerEntity] (+ referenced key/profile rows) into flat credentials. */
    private suspend fun buildCredentials(srv: ServerEntity): SshCredentials {
        // Read keys/profiles straight from the DB. The `keys`/`profiles` StateFlows are
        // `WhileSubscribed`, so when this runs with no active UI collector (telemetry, a
        // background exec, the test-connection probe) `.value` is the initial emptyList() and
        // the private key is silently dropped — which surfaced to the user as "invalid
        // credentials" for key/profile auth even when the key was correct.
        val allKeys = repository.getAllKeys()
        var user = srv.username
        var pass: String? = srv.authPassword
        var pem: String? = null
        when (srv.authType) {
            "key" -> pem = allKeys.find { it.alias == srv.authKeyAlias }?.privateKey
            "profile" -> repository.getAllProfiles().find { it.id == srv.authProfileId }?.let { p ->
                user = p.username
                if (p.authType == "password") pass = p.password
                else pem = allKeys.find { it.alias == p.keyAlias }?.privateKey
            }
        }
        return SshCredentials(
            srv.host, srv.port, user, pass, pem,
            proxyType = srv.proxyType,
            proxyHost = srv.proxyHost,
            proxyPort = srv.proxyPort,
            proxyUser = srv.proxyUser,
            proxyPassword = srv.proxyPassword,
            proxyKeyPem = srv.proxyKeyAlias?.let { a -> allKeys.find { it.alias == a }?.privateKey },
            keepAliveSeconds = srv.keepAlive,
            compression = srv.sshCompression,
            agentForwarding = srv.agentForwarding,
        )
    }

    // ── Port-forward tunnels ──
    /** Ids of tunnels currently up. A Compose snapshot list so the UI recomposes on start/stop. */
    val activeTunnelIds = mutableStateListOf<Int>()
    /** Transient per-tunnel error (keyed by tunnel id), surfaced next to the row. */
    val tunnelErrors = mutableStateMapOf<Int, String>()
    private val tunnelBusyIds = mutableStateListOf<Int>()
    private val tunnelWatchJobs = mutableMapOf<Int, Job>()
    fun isTunnelBusy(id: Int): Boolean = id in tunnelBusyIds

    fun isTunnelActive(id: Int): Boolean =
        id in activeTunnelIds && com.jetsetslow.omniterm.data.ssh.SshTunnelManager.isActive(id)

    private fun watchTunnel(id: Int) {
        tunnelWatchJobs.remove(id)?.cancel()
        val watcher = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                while (isActive) {
                    delay(2_000)
                    if (!com.jetsetslow.omniterm.data.ssh.SshTunnelManager.isActive(id)) {
                        activeTunnelIds.remove(id)
                        tunnelErrors.putIfAbsent(id, "Tunnel disconnected; check the network and start it again.")
                        break
                    }
                }
            } finally {
                val owner = currentCoroutineContext()[Job]
                if (tunnelWatchJobs[id] === owner) tunnelWatchJobs.remove(id)
            }
        }
        tunnelWatchJobs[id] = watcher
        watcher.start()
    }

    fun savePortForward(pf: PortForwardEntity, onDone: (String?) -> Unit = {}) {
        // Basic validation: a listening port, and a destination for local/remote kinds.
        if (pf.name.isBlank()) { onDone("Name is required."); return }
        if (pf.bindPort !in 1..65535) { onDone("Bind port must be 1–65535."); return }
        if (pf.kind != "dynamic" && (pf.destHost.isBlank() || pf.destPort !in 1..65535)) {
            onDone("Destination host and port are required for ${pf.kind} forwards."); return
        }
        viewModelScope.launch {
            try {
                if (pf.id == 0) repository.insertPortForward(pf) else repository.updatePortForward(pf)
                onDone(null)
            } catch (e: Exception) { onDone(e.message ?: "Could not save tunnel") }
        }
    }

    fun deletePortForward(pf: PortForwardEntity) {
        stopTunnel(pf.id)
        viewModelScope.launch { repository.deletePortForward(pf) }
    }

    /** Start a saved tunnel over its owning server's SSH connection. */
    fun startTunnel(pf: PortForwardEntity) {
        if (isTunnelActive(pf.id) || isTunnelBusy(pf.id)) return
        tunnelBusyIds.add(pf.id)
        tunnelErrors.remove(pf.id)
        viewModelScope.launch {
            try {
                val srv = servers.value.firstOrNull { it.id == pf.serverId }
                    ?: repository.getServerById(pf.serverId)
                    ?: throw IllegalStateException("This tunnel's SSH host no longer exists.")
                val creds = buildCredentials(srv)
                com.jetsetslow.omniterm.data.ssh.SshTunnelManager.start(
                    id = pf.id,
                    creds = creds,
                    kind = pf.kind,
                    bindHost = pf.bindHost.ifBlank { "127.0.0.1" },
                    bindPort = pf.bindPort,
                    destHost = pf.destHost,
                    destPort = pf.destPort,
                )
                if (com.jetsetslow.omniterm.data.ssh.SshTunnelManager.isActive(pf.id) && pf.id !in activeTunnelIds) {
                    activeTunnelIds.add(pf.id)
                }
                if (com.jetsetslow.omniterm.data.ssh.SshTunnelManager.isActive(pf.id)) watchTunnel(pf.id)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                tunnelErrors[pf.id] = e.message ?: "Failed to start tunnel"
            } finally {
                tunnelBusyIds.remove(pf.id)
            }
        }
    }

    fun stopTunnel(id: Int) {
        tunnelWatchJobs.remove(id)?.cancel()
        com.jetsetslow.omniterm.data.ssh.SshTunnelManager.stop(id)
        activeTunnelIds.remove(id)
        tunnelBusyIds.remove(id)
    }

    fun toggleTunnel(pf: PortForwardEntity) {
        if (isTunnelActive(pf.id)) stopTunnel(pf.id) else startTunnel(pf)
    }

    /**
     * Real connection test for the Add/Edit Host sheet: resolves the (possibly unsaved)
     * credentials and actually authenticates over SSH. [onResult] gets null on success or a
     * short error string. This replaces the old ping-only "test" that was misleading.
     */
    fun testConnectionDraft(
        host: String, port: Int, username: String, authType: String,
        password: String?, keyAlias: String?, profileId: Int?,
        proxyType: String = "none", proxyHost: String = "", proxyPort: Int = 0,
        proxyUser: String = "", proxyPassword: String = "", proxyKeyAlias: String? = null,
        onResult: (String?) -> Unit,
    ) {
        if (host.isBlank()) { onResult("Host is required."); return }
        isTestingConnection = true
        viewModelScope.launch {
            // A direct TCP precheck only makes sense without a proxy — through a proxy/jump host the
            // target isn't reachable directly, so skip it and let the SSH test be the source of truth.
            if (proxyType == "none") {
                val rtt = withContext(Dispatchers.IO) { tcpReachable(host, port) }
                if (rtt < 0) {
                    isTestingConnection = false
                    onResult("Host unreachable on $host:$port (no TCP route).")
                    return@launch
                }
            }
            var user = username
            var pass: String? = password
            var pem: String? = null
            when (authType) {
                "key" -> pem = repository.getAllKeys().find { it.alias == keyAlias }?.privateKey
                "profile" -> repository.getAllProfiles().find { it.id == profileId }?.let { p ->
                    user = p.username
                    if (p.authType == "password") pass = p.password
                    else pem = repository.getAllKeys().find { it.alias == p.keyAlias }?.privateKey
                }
            }
            val err = sshTransport.testConnection(
                SshCredentials(
                    host, port, user, pass, pem,
                    proxyType = proxyType, proxyHost = proxyHost, proxyPort = proxyPort,
                    proxyUser = proxyUser, proxyPassword = proxyPassword,
                    proxyKeyPem = proxyKeyAlias?.let { a ->
                        repository.getAllKeys().find { it.alias == a }?.privateKey
                    },
                )
            )
            isTestingConnection = false
            onResult(err?.let { cleanSshError(it) })
        }
    }

    fun cancelConnect() {
        pendingMultiSshConnections.clear()
        terminalConnectGeneration++
        terminalConnectJob?.cancel()
        terminalConnectJob = null
        isTerminalConnecting = false
        terminalConnectionPhase = "Connecting…"
    }

    fun connectTerminal() {
        val srv = selectedServer ?: return
        // Gate on the last reachability probe: if the SSH port was found unreachable, the host is
        // (very likely) offline. The probe can be stale, so warn-and-confirm instead of hard-blocking
        // — connectTerminalConfirmedOffline() re-enters with the gate bypassed. Only gate once the
        // host has actually been probed this run; an un-probed host falls through and connects.
        if (probedServerIds[srv.id] == true && srv.status == "offline" && !isTerminalConnecting) {
            offlineConnectPromptServer = srv
            return
        }
        connectTerminal(srv, forceDisablePersistence = false)
    }

    /**
     * Open a fresh (non-persistent) terminal session and, once connected, run [initialCommand] in it
     * — used by "exec into container" so the shell lands directly inside the container. Forces
     * persistence off: an exec shell is ephemeral and shouldn't be wrapped in tmux.
     */
    fun openTerminalWithCommand(srv: ServerEntity, initialCommand: String) {
        selectedServerId = srv.id
        // Exec should always land in single-session view so the shell is front-and-centre.
        if (activeSshTab == 1) exitMultiSsh()
        navigateTo(Screen.Shell)
        connectTerminal(srv, forceDisablePersistence = true, initialCommand = initialCommand)
    }

    /** Proceed with a connect the user confirmed despite an offline status (dismisses the warning). */
    fun connectTerminalConfirmedOffline() {
        val srv = offlineConnectPromptServer ?: return
        offlineConnectPromptServer = null
        connectTerminal(srv, forceDisablePersistence = false)
        // The gate now fires from the Hosts tab (the terminal hides offline hosts entirely), so a
        // confirmed force-connect has to bring the user to the terminal it just opened.
        navigateTo(Screen.Shell)
    }

    fun dismissOfflineConnectPrompt() { offlineConnectPromptServer = null }

    private fun connectTerminal(
        srv: ServerEntity,
        forceDisablePersistence: Boolean,
        initialCommand: String? = null,
        onFinished: ((Boolean) -> Unit)? = null,
    ) {
        if (isTerminalConnecting) return
        // Capture the destination now. Split-pane focus is still interactive while a connection is
        // in flight; reading it only after SSH completes lets a harmless focus tap redirect the new
        // session into the wrong pane.
        val targetMultiSshPane = multiSshFocusedPane.takeIf { activeSshTab == 1 }
        isTerminalConnecting = true
        terminalConnectError = null
        terminalConnectionPhase = "Connecting…"
        val attemptGeneration = ++terminalConnectGeneration

        terminalConnectJob = viewModelScope.launch {
            var openedSession: TerminalSession? = null
            var registeredSession: ShellSession? = null
            var setupComplete = false
            try {
                val creds = buildCredentials(srv)
                val usePersistence = srv.persistentSession && !forceDisablePersistence

                // Persistent sessions need tmux on the host. On the first connect where it's missing,
                // stop and ask the user to install it (rather than silently falling back to a normal,
                // non-surviving shell). Checked once per host per app run to avoid a round-trip on
                // every connect; the "Install tmux" action re-runs connect afterwards.
                if (usePersistence && srv.id !in tmuxVerifiedServerIds) {
                    terminalConnectionPhase = "Checking tmux…"
                    val present = runCatching {
                        sshTransport.exec(creds, RemoteCommands.TMUX_CHECK).trim().endsWith("yes")
                    }.getOrDefault(true) // on probe failure, don't block the connect
                    if (present) {
                        tmuxVerifiedServerIds.add(srv.id)
                    } else {
                        isTerminalConnecting = false
                        tmuxInstallPromptServer = srv
                        return@launch
                    }
                }

                val emulator = TerminalEmulator(termCols, termRows, scrollbackLimit = terminalScrollbackLimit)
                val session = sshTransport.openShell(creds, termCols, termRows) { phase ->
                    viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                        if (attemptGeneration == terminalConnectGeneration) terminalConnectionPhase = phase
                    }
                }
                openedSession = session
                currentCoroutineContext().ensureActive()
                check(attemptGeneration == terminalConnectGeneration) { "Connection attempt was superseded" }
                val shellSession = ShellSession(srv.id, srv.name, session, emulator)
                // Keep what auto-reconnect needs to reopen this exact shell without the UI.
                shellSession.creds = creds
                shellSession.termCols = termCols
                shellSession.termRows = termRows
                shellSession.lastCols = termCols
                shellSession.lastRows = termRows
                shellSession.persistent = usePersistence
                if (usePersistence) {
                    shellSession.tmuxName = nextTmuxSessionName()
                }

                // Persistent session: enter a tmux session unique to this shell so a reconnect
                // re-attaches the SAME session (and any running command keeps going server-side),
                // and multiple persistent shells to one host don't collide on a shared name.
                if (usePersistence) {
                    shellSession.controlMode = tmuxControlMode
                    // A regular tmux attach is itself an alternate-screen TUI, so capture its
                    // repaint history. Control mode feeds the pane application's raw bytes and
                    // must retain normal terminal semantics (vim/htop alt frames are not history).
                    emulator.setCaptureAlternateScreenScrollback(!shellSession.controlMode)
                    if (shellSession.controlMode) {
                        // Control mode: no attach repaint exists, so seeding (history + screen)
                        // happens in initControlModeSession AFTER I/O is wired.
                        session.write(RemoteCommands.tmuxControlCreateAttachCommand(shellSession.tmuxName, terminalScrollbackLimit).toByteArray())
                    } else {
                        // Seed real tmux history into local scrollback before the attach repaint
                        // (no-op for a brand-new session), so back-scroll works immediately.
                        seedTmuxHistory(emulator, creds, shellSession.tmuxName)
                        session.write(RemoteCommands.tmuxCreateAttachCommand(shellSession.tmuxName, terminalScrollbackLimit).toByteArray())
                    }
                    check(!session.closed.value) { "SSH channel closed while attaching tmux" }
                }

                activeSessions.add(shellSession)
                registeredSession = shellSession
                openedSession = null // ownership transferred to the registered ShellSession
                withContext(Dispatchers.Main) {
                    check(attemptGeneration == terminalConnectGeneration) { "Connection attempt was superseded" }
                    if (activeSshTab == 1 && targetMultiSshPane != null) {
                        if (targetMultiSshPane == 1) multiSshSessionId1 = shellSession.id
                        else multiSshSessionId2 = shellSession.id
                    } else {
                        currentSessionId = shellSession.id
                    }
                }
                wireSessionIo(shellSession)
                if (shellSession.controlMode) initControlModeSession(shellSession, creds)
                if (usePersistence) rememberRestorablePersistentSession(shellSession)
                setupComplete = true
                noteSuccessfulSshSession()
                TerminalSessionManager.updateKeepaliveCount()
                startKeepAliveService()

                // Run a requested initial command (e.g. `docker exec -it … sh`) once the remote
                // shell prompt is likely up. Routed through sendBytesTo (not the raw channel) so
                // ordering matches typed keystrokes AND a control-mode session encodes it as
                // send-keys instead of leaking shell text into the tmux command stream.
                if (!initialCommand.isNullOrBlank()) {
                    viewModelScope.launch {
                        delay(400)
                        sendBytesTo(shellSession, (initialCommand + "\r").toByteArray())
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attemptGeneration == terminalConnectGeneration) {
                    val msg = e.message ?: "Connection failed."
                    if (msg.contains("reject HostKey", ignoreCase = true) ||
                        msg.contains("HostKey has been changed", ignoreCase = true)) {
                        hostKeyChangedServer = srv
                    } else {
                        terminalConnectError = cleanSshError(msg)
                    }
                }
            } finally {
                if (!setupComplete) {
                    registeredSession?.let { cleanupSession(it) }
                    openedSession?.close()
                }
                if (attemptGeneration == terminalConnectGeneration) {
                    isTerminalConnecting = false
                    terminalConnectJob = null
                    terminalConnectionPhase = "Connecting…"
                    onFinished?.invoke(setupComplete)
                }
            }
        }
    }

    /**
     * Pre-fill a fresh emulator's scrollback with the pane's real tmux history (side-channel
     * `capture-pane`) so scrolling back right after an attach shows what actually happened in the
     * session — not just what has streamed since this client connected. Must run BEFORE the attach
     * output arrives: the emulator is still on the normal screen, so the fed lines flow cleanly
     * into scrollback; a screen-height of line feeds then pushes the tail rows off so the attach
     * repaint starts from a blank grid. `capture-pane` stops at the last history line above the
     * visible pane (the repaint provides the screen itself), and the whole thing is a no-op when
     * the tmux session doesn't exist yet or has no history. Only ever seeds an emulator with no
     * scrollback — a reconnect keeps its accumulated buffer and must not get a duplicated copy.
     */
    /**
     * Fetch a pane's full history WITHOUT the transport's flat 240K exec cap. `exec()` returns a
     * CappedTextBuffer tail that silently drops the oldest output mid-line AND injects a
     * "[Output truncated…]" banner — for a large colourful history that manufactured exactly the
     * gaps/half-lines this capture exists to fix. Streaming chunks lets the budget scale with
     * the configured scrollback limit; if a freak capture still exceeds it, whole leading chars
     * are dropped (oldest first, like the emulator's own scrollback trim) with no banner.
     */
    private suspend fun captureTmuxHistoryFull(creds: SshCredentials, tmuxName: String): String? = runCatching {
        val budget = terminalScrollbackLimit * 300 + 65_536
        val sb = StringBuilder()
        val result = sshTransport.execStream(creds, RemoteCommands.tmuxCaptureHistoryCommand(tmuxName, terminalScrollbackLimit)) { chunk ->
            sb.append(chunk)
            if (sb.length > budget) sb.delete(0, sb.length - budget)
        }
        check(!result.startsWith("SSH Error:")) { result }
        sb.toString()
    }.getOrNull()

    private suspend fun seedTmuxHistory(emulator: TerminalEmulator, creds: SshCredentials, tmuxName: String) {
        val history = captureTmuxHistoryFull(creds, tmuxName)?.trimEnd('\n')
        if (history.isNullOrBlank()) return
        synchronized(emulator) {
            if (emulator.scrollbackRowCount() > 0) return
            emulator.feed(history.replace("\n", "\r\n").toByteArray())
            emulator.feed("\r\n".repeat(emulator.rows).toByteArray())
        }
    }

    /**
     * Re-sync a persistent session's local scrollback from the pane's authoritative tmux history.
     *
     * tmux does NOT stream every output line to an attached client — output faster than the
     * client keeps up with is collapsed into a screen repaint, so rows the user never had on
     * screen are simply absent from the locally captured scrollback (they show as gaps/blanks).
     * The pane's real history (bounded by history-limit) lives server-side; this fetches it via
     * side-channel `capture-pane`, re-parses it through a scratch emulator at the live grid's
     * width, and swaps it in wholesale — which also replaces the attach-seed's padding and any
     * partial repaint junk. Called when the user scrolls off the tail with new output pending
     * ([ShellSession.scrollbackDirty]); skipped while a full-screen TUI owns the alt screen,
     * because tmux history covers only the normal screen and swapping would trade captured TUI
     * frames for unrelated shell history.
     *
     * Returns the resulting change in total row count so the caller can shift its viewport
     * anchor and keep the content under the user's finger stationary; 0 when nothing changed.
     */
    suspend fun resyncTmuxScrollbackFor(session: ShellSession?): Int {
        session ?: return 0
        val creds = session.creds ?: return 0
        if (!session.persistent || !session.scrollbackDirty || !session.scrollbackSyncMutex.tryLock()) return 0
        try {
            val emulator = session.emulator
            val cols: Int
            val rows: Int
            synchronized(emulator) {
                if (emulator.isAlternateScreenActive()) return 0
                cols = emulator.cols
                rows = emulator.rows
            }
            // Clear the dirty flag BEFORE capturing: output arriving mid-capture re-arms it, so
            // the next scroll-up re-syncs again rather than trusting a capture that missed it.
            session.scrollbackDirty = false
            val history = withContext(kotlinx.coroutines.Dispatchers.IO) {
                captureTmuxHistoryFull(creds, session.tmuxName)
            }?.trimEnd('\n')
            if (history.isNullOrBlank()) {
                // Transient failure (or empty pane): re-arm so the next scroll-up retries
                // instead of silently never re-syncing again.
                session.scrollbackDirty = true
                return 0
            }
            val result = withContext(kotlinx.coroutines.Dispatchers.Default) {
                // Same trick as seedTmuxHistory: feed the history, then a screen-height of LFs
                // pushes the tail rows off the scratch screen so its scrollback holds everything.
                val scratch = TerminalEmulator(cols, rows, scrollbackLimit = terminalScrollbackLimit)
                scratch.feed(history.replace("\n", "\r\n").toByteArray())
                scratch.feed("\r\n".repeat(rows).toByteArray())
                synchronized(emulator) {
                    if (emulator.isAlternateScreenActive() || emulator.cols != cols) {
                        // The capture is valid only for the grid/mode observed at the start. Keep it
                        // dirty so a later scroll gesture can retry instead of trusting no-op data.
                        session.scrollbackDirty = true
                        return@withContext false to 0
                    }
                    val before = emulator.scrollbackRowCount()
                    emulator.adoptScrollbackFrom(scratch)
                    val d = emulator.scrollbackRowCount() - before
                    session.viewportFirstRow = (session.viewportFirstRow + d).coerceAtLeast(0)
                    true to d
                }
            }
            val (adopted, delta) = result
            // A replacement may correct gaps/colours while keeping exactly the same row count.
            // Publish on every adoption, not only when the count changed.
            if (adopted) TerminalSessionManager.publishTerminalSnapshot(session)
            return delta
        } finally {
            session.scrollbackSyncMutex.unlock()
        }
    }

    /** Write one tmux command line to a control-mode session's channel (wire-ready bytes). */
    private fun sendControlLine(session: ShellSession, command: String, awaitReply: Boolean = false): Long? {
        return enqueueControlCommandBatch(session, listOf((command + "\n").toByteArray()), awaitReply)
    }

    /** Enqueue control commands and return the reply ordinal of the last command. */
    private fun enqueueControlCommandBatch(
        session: ShellSession,
        commands: List<ByteArray>,
        awaitLastReply: Boolean = false,
    ): Long? {
        synchronized(session.controlReplyLock) {
            if (!enqueueTerminalWireBatch(session, commands)) return null
            session.controlCommandsEnqueued += commands.size
            val target = session.controlReplyBaseline + session.controlCommandsEnqueued
            if (awaitLastReply) session.controlAwaitedOrdinals.add(target)
            return target
        }
    }

    /** Send one in-band tmux command and wait for its exact ordered reply ordinal. */
    private suspend fun awaitControlReply(session: ShellSession, command: String) {
        val target = sendControlLine(session, command, awaitReply = true)
            ?: error("tmux control command queue is unavailable")
        try {
            withTimeout(5_000) {
                while (true) {
                    val result = synchronized(session.controlReplyLock) {
                        if (session.controlRepliesSeen >= target) {
                            true to session.controlReplyErrors.remove(target)
                        } else false to null
                    }
                    if (result.first) {
                        check(result.second == null) { result.second ?: "tmux rejected: $command" }
                        return@withTimeout
                    }
                    session.controlReplySignal.receive()
                }
            }
        } finally {
            synchronized(session.controlReplyLock) {
                session.controlAwaitedOrdinals.remove(target)
                session.controlReplyErrors.remove(target)
            }
        }
    }

    /** Paint a stable pane snapshot: tmux buffers pane output between pause and continue. */
    private suspend fun repaintControlPane(
        shellSession: ShellSession,
        creds: SshCredentials,
        pane: String,
        expectedTransport: TerminalSession,
    ) {
        awaitControlReply(shellSession, TmuxControlCommands.refreshClientSize(shellSession.termCols, shellSession.termRows))
        awaitControlReply(shellSession, TmuxControlCommands.paneOutputState(pane, "pause"))
        try {
            val screenResult = sshTransport.exec(creds, RemoteCommands.tmuxCapturePaneScreenCommand(pane))
            check(!screenResult.startsWith("SSH Error:")) { screenResult }
            val cursorResult = sshTransport.exec(creds, RemoteCommands.tmuxPaneCursorQuery(pane))
            check(!cursorResult.startsWith("SSH Error:")) { cursorResult }
            currentCoroutineContext().ensureActive()
            check(!shellSession.userClosed && shellSession.session === expectedTransport) {
                "terminal transport changed during control repaint"
            }
            val cursor = cursorResult.trim().split(' ')
            val cx = cursor.getOrNull(0)?.toIntOrNull() ?: 0
            val cy = cursor.getOrNull(1)?.toIntOrNull() ?: 0
            val repaint = "\u001B[r\u001B[0m\u001B[2J\u001B[H" +
                screenResult.trimEnd('\n').replace("\n", "\r\n") +
                "\u001B[${cy + 1};${cx + 1}H\u001B[0m"
            synchronized(shellSession.emulator) { shellSession.emulator.feed(repaint.toByteArray()) }
            TerminalSessionManager.publishTerminalSnapshot(shellSession)
        } finally {
            // Resume buffered output even if capture/paint failed; never strand the remote pane.
            val resumed = withContext(NonCancellable) {
                runCatching {
                    awaitControlReply(shellSession, TmuxControlCommands.paneOutputState(pane, "continue"))
                }
            }
            check(resumed.isSuccess) { "tmux pane output could not be resumed: ${resumed.exceptionOrNull()?.message}" }
        }
    }

    private fun flushPendingControlInput(shellSession: ShellSession, pane: String) {
        synchronized(shellSession.pendingControlInput) {
            val wireBatch = ArrayList<ByteArray>()
            for (pending in shellSession.pendingControlInput) {
                for (command in TmuxControlCommands.sendKeysHex(pane, pending)) {
                    wireBatch.add((command + "\n").toByteArray())
                }
            }
            check(enqueueControlCommandBatch(shellSession, wireBatch) != null) {
                "terminal input queue filled while control mode was initialising"
            }
            shellSession.pendingControlInput.clear()
            shellSession.pendingControlInputBytes = 0
            shellSession.controlReady = true
        }
    }

    /** Re-resolve and repaint after tmux reports a window/active-pane transition. */
    private fun refreshControlActivePane(shellSession: ShellSession) {
        if (!shellSession.controlMode || shellSession.userClosed) return
        if (shellSession.controlPaneRefreshJob?.isActive == true || !shellSession.controlReady) return
        val creds = shellSession.creds ?: return
        val expectedTransport = shellSession.session
        shellSession.controlReady = false
        shellSession.controlPaneRefreshJob = TerminalSessionManager.scope.launch(Dispatchers.IO) {
            try {
                while (true) {
                    val revision = shellSession.controlPaneChangeRevision.get()
                    val out = sshTransport.exec(creds, RemoteCommands.tmuxActivePaneQuery(shellSession.tmuxName)).trim()
                    check(Regex("%\\d+").matches(out)) { "tmux active pane is unavailable" }
                    ensureActive()
                    check(shellSession.session === expectedTransport && !shellSession.userClosed)
                    shellSession.activePaneId = out
                    repaintControlPane(shellSession, creds, out, expectedTransport)
                    ensureActive()
                    check(shellSession.session === expectedTransport && shellSession.activePaneId == out)
                    if (shellSession.controlPaneChangeRevision.get() != revision) continue
                    flushPendingControlInput(shellSession, out)
                    if (shellSession.controlPaneChangeRevision.get() == revision) {
                        shellSession.scrollbackDirty = true
                        break
                    }
                    shellSession.controlReady = false
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (shellSession.session === expectedTransport && !shellSession.userClosed) {
                    shellSession.controlInitFailed = true
                    synchronized(shellSession.pendingControlInput) {
                        shellSession.pendingControlInput.clear()
                        shellSession.pendingControlInputBytes = 0
                    }
                    synchronized(shellSession.emulator) {
                        shellSession.emulator.feed(
                            "\r\n\u001B[31m-- tmux changed panes but the new pane could not be loaded; input is disabled. Reconnect to retry. --\u001B[0m\r\n".toByteArray()
                        )
                    }
                    TerminalSessionManager.publishTerminalSnapshot(shellSession)
                    android.util.Log.w("OmniTermTmuxCtl", "active-pane refresh failed: ${e.message}")
                }
            }
        }
    }

    /** Queue wire-ready input without ever blocking Main; memory is bounded per session. */
    private fun enqueueTerminalWireBytes(session: ShellSession, bytes: ByteArray): Boolean {
        return enqueueTerminalWireBatch(session, listOf(bytes))
    }

    /** Reserve and enqueue one logical input atomically: never deliver a truncated paste prefix. */
    private fun enqueueTerminalWireBatch(session: ShellSession, chunks: List<ByteArray>): Boolean {
        val queue = session.terminalInputQueue ?: return false
        synchronized(queue) {
            val total = chunks.sumOf { it.size.toLong() }
            if (total > Int.MAX_VALUE || queue.queuedBytes.toLong() + total > TERMINAL_INPUT_QUEUE_MAX_BYTES) return false
            // Cleanup/reconnect closes this channel under the same monitor, so after the open check
            // every send to the unlimited channel succeeds and the batch cannot be partially queued.
            if (queue.closed) return false
            queue.queuedBytes += total.toInt()
            for (chunk in chunks) check(queue.channel.trySend(chunk).isSuccess)
            return true
        }
    }

    private fun warnTerminalInputOverflow(session: ShellSession, controlInit: Boolean = false) {
        val alreadyWarned = if (controlInit) session.controlInputOverflowWarned else session.terminalInputOverflowWarned
        if (alreadyWarned) return
        if (controlInit) session.controlInputOverflowWarned = true else session.terminalInputOverflowWarned = true
        synchronized(session.emulator) {
            session.emulator.feed(
                "\r\n\u001B[31m-- Input queue is full; excess pasted data was rejected. Wait for the connection to catch up and retry. --\u001B[0m\r\n".toByteArray()
            )
        }
        TerminalSessionManager.publishTerminalSnapshot(session)
    }

    /**
     * Bring a freshly attached CONTROL-MODE session to a usable state. Unlike a regular attach,
     * control mode renders nothing on its own — tmux only streams %output for NEW bytes — so the
     * client must: match the tmux client size to our grid, learn the active pane id (early
     * %output for an unknown pane is dropped; the screen seed below repaints whatever that
     * missed), seed history into scrollback, paint the current screen + cursor, and flush any
     * input the user typed before the pane id was known. Pane/cursor/screen come over the side
     * exec channel — correlating in-band %begin replies by order is avoidable complexity.
     */
    private fun initControlModeSession(shellSession: ShellSession, creds: SshCredentials) {
        shellSession.controlInitJob?.cancel()
        shellSession.controlReady = false
        shellSession.controlInitFailed = false
        shellSession.controlInputOverflowWarned = false
        shellSession.activePaneId = null
        val expectedTransport = shellSession.session
        val job = TerminalSessionManager.scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            try {
                withTimeout(12_000) { shellSession.controlAttached.await() }
                val paneRevisionAtStart = shellSession.controlPaneChangeRevision.get()
                // A BRAND-NEW session is still being created by the bootstrap command in the
                // interactive shell when this runs, so the first pane queries can return empty —
                // poll until tmux is up (~10s budget). Without the retry, activePaneId stayed
                // null forever and every keystroke sat in pendingControlInput: "new sessions
                // don't type, existing ones do".
                var pane: String? = null
                for (attempt in 1..25) {
                    ensureActive()
                    if (shellSession.userClosed || shellSession.session !== expectedTransport) return@launch
                    val out = runCatching {
                        sshTransport.exec(creds, RemoteCommands.tmuxActivePaneQuery(shellSession.tmuxName)).trim()
                    }.getOrDefault("")
                    if (Regex("%\\d+").matches(out)) { pane = out; break }
                    delay(400)
                }
                if (pane == null) {
                    error("tmux pane was not found after 10 seconds")
                }
                shellSession.activePaneId = pane
                // Seed history BEFORE sizing the client: refresh-client SIGWINCHes the pane app,
                // whose redraw can flood %output and overflow the screen — a non-empty scrollback
                // then makes the fresh-emulator seed skip entirely ("scroll doesn't go all the
                // way back"). Seeding first sees the guaranteed-empty buffer.
                seedTmuxHistory(shellSession.emulator, creds, shellSession.tmuxName)
                repaintControlPane(shellSession, creds, pane, expectedTransport)
                ensureActive()
                check(shellSession.session === expectedTransport && shellSession.activePaneId == pane)
                flushPendingControlInput(shellSession, pane)
                if (shellSession.controlPaneChangeRevision.get() != paneRevisionAtStart) {
                    refreshControlActivePane(shellSession)
                }
                // Insurance: if live %output raced the seed/repaint above (e.g. a resize-redraw
                // flood), the first scroll-up rebuilds scrollback from the pane's authoritative
                // history via the existing capture-pane re-sync.
                shellSession.scrollbackDirty = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (!shellSession.userClosed && shellSession.session === expectedTransport) {
                    shellSession.controlInitFailed = true
                    synchronized(shellSession.pendingControlInput) {
                        shellSession.pendingControlInput.clear()
                        shellSession.pendingControlInputBytes = 0
                    }
                    val detail = e.message?.removePrefix("SSH Error: ")?.take(160)
                        ?: "unknown initialisation error"
                    synchronized(shellSession.emulator) {
                        shellSession.emulator.feed(
                            "\r\n\u001B[31m-- tmux control mode could not initialise: $detail. Input is disabled; reconnect or turn control mode off. --\u001B[0m\r\n".toByteArray()
                        )
                    }
                    TerminalSessionManager.publishTerminalSnapshot(shellSession)
                    android.util.Log.w("OmniTermTmuxCtl", "control-mode init failed: $detail")
                }
            }
        }
        shellSession.controlInitJob = job
        job.start()
    }

    fun resumePersistentSession(tmuxName: String) {
        val existingSession = activeSessions.find { it.tmuxName == tmuxName }
        if (existingSession != null) {
            if (isMultiSsh) assignMultiSshPane(multiSshFocusedPane, existingSession.id)
            else attachSession(existingSession.id)
            return
        }
        val sessionEntity = restorablePersistentSessions.find { it.tmuxName == tmuxName } ?: return
        val srv = servers.value.find { it.id == sessionEntity.serverId } ?: return

        if (isTerminalConnecting) return
        val targetMultiSshPane = multiSshFocusedPane.takeIf { activeSshTab == 1 }
        isTerminalConnecting = true
        terminalConnectError = null
        terminalConnectionPhase = "Connecting…"
        val attemptGeneration = ++terminalConnectGeneration

        terminalConnectJob = viewModelScope.launch {
            var openedSession: TerminalSession? = null
            var registeredSession: ShellSession? = null
            var setupComplete = false
            try {
                val creds = buildCredentials(srv)
                when (remoteTmuxSessionExists(creds, tmuxName)) {
                    false -> {
                        forgetPersistentSession(tmuxName)
                        isTerminalConnecting = false
                        terminalConnectError = "Server disconnected; tmux session is no longer running."
                        return@launch
                    }
                    null -> {
                        isTerminalConnecting = false
                        terminalConnectError = "Unable to reach server; tmux session may still be running."
                        return@launch
                    }
                    true -> Unit
                }
                val emulator = TerminalEmulator(termCols, termRows, scrollbackLimit = terminalScrollbackLimit)
                val session = sshTransport.openShell(creds, termCols, termRows) { phase ->
                    viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                        if (attemptGeneration == terminalConnectGeneration) terminalConnectionPhase = phase
                    }
                }
                openedSession = session
                currentCoroutineContext().ensureActive()
                check(attemptGeneration == terminalConnectGeneration) { "Connection attempt was superseded" }
                val shellSession = ShellSession(srv.id, srv.name, session, emulator)
                shellSession.creds = creds
                shellSession.termCols = termCols
                shellSession.termRows = termRows
                shellSession.lastCols = termCols
                shellSession.lastRows = termRows
                shellSession.persistent = true
                shellSession.tmuxName = tmuxName
                shellSession.controlMode = tmuxControlMode
                emulator.setCaptureAlternateScreenScrollback(!shellSession.controlMode)
                if (shellSession.controlMode) {
                    session.write(RemoteCommands.tmuxControlAttachCommand(tmuxName, terminalScrollbackLimit).toByteArray())
                } else {
                    // Resume re-attaches an existing session with a fresh emulator: seed its local
                    // scrollback from the pane's tmux history so back-scroll shows the real past.
                    seedTmuxHistory(emulator, creds, tmuxName)
                    session.write(RemoteCommands.tmuxAttachCommand(tmuxName, terminalScrollbackLimit).toByteArray())
                }
                check(!session.closed.value) { "SSH channel closed while attaching tmux" }

                activeSessions.add(shellSession)
                registeredSession = shellSession
                openedSession = null
                withContext(kotlinx.coroutines.Dispatchers.Main) {
                    check(attemptGeneration == terminalConnectGeneration) { "Connection attempt was superseded" }
                    if (activeSshTab == 1 && targetMultiSshPane != null) {
                        if (targetMultiSshPane == 1) multiSshSessionId1 = shellSession.id
                        else multiSshSessionId2 = shellSession.id
                    } else {
                        currentSessionId = shellSession.id
                    }
                }
                wireSessionIo(shellSession)
                if (shellSession.controlMode) initControlModeSession(shellSession, creds)
                setupComplete = true
                noteSuccessfulSshSession()
                TerminalSessionManager.updateKeepaliveCount()
                startKeepAliveService()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attemptGeneration == terminalConnectGeneration) {
                    val msg = e.message ?: "Connection failed."
                    if (msg.contains("reject HostKey", ignoreCase = true) ||
                        msg.contains("HostKey has been changed", ignoreCase = true)) {
                        hostKeyChangedServer = srv
                    } else {
                        terminalConnectError = cleanSshError(msg)
                    }
                }
            } finally {
                if (!setupComplete) {
                    registeredSession?.let { cleanupSession(it) }
                    openedSession?.close()
                }
                if (attemptGeneration == terminalConnectGeneration) {
                    isTerminalConnecting = false
                    terminalConnectJob = null
                    terminalConnectionPhase = "Connecting…"
                }
            }
        }
    }

    /**
     * Wire a [ShellSession]'s live [session] to the keystroke channel and output stream. On an
     * unexpected output-stream end (network drop, not a clean shell exit or user disconnect), kick
     * off [reconnectSession] instead of tearing the session down — the emulator/scrollback is kept
     * so the reconnected shell continues in place. Called on first connect and after each reconnect.
     */
    private fun wireSessionIo(shellSession: ShellSession) {
        val session = shellSession.session
        val emulator = shellSession.emulator

        shellSession.terminalInputJob?.cancel()
        shellSession.terminalInputQueue?.let { synchronized(it) { it.closed = true; it.channel.close() } }

        // Serialize keystrokes through a single bounded channel so writes never reorder and a large
        // paste cannot grow memory without backpressure. Recreated per (re)connect so it always
        // targets the current live channel.
        val inputQueue = TerminalInputQueue()
        shellSession.terminalInputQueue = inputQueue
        shellSession.terminalInputOverflowWarned = false
        if (shellSession.controlMode) {
            shellSession.controlReplySignal.close()
            shellSession.controlReplySignal = Channel(Channel.CONFLATED)
            shellSession.controlAttached = CompletableDeferred()
            synchronized(shellSession.controlReplyLock) {
                shellSession.controlRepliesSeen = 0
                shellSession.controlReplyBaseline = 0
                shellSession.controlCommandsEnqueued = 0
                shellSession.controlReplyErrors.clear()
                shellSession.controlAwaitedOrdinals.clear()
            }
            shellSession.controlExitSeen = false
            shellSession.controlExitReason = null
        }
        shellSession.terminalInputJob = TerminalSessionManager.scope.launch(Dispatchers.IO) {
            for (bytes in inputQueue.channel) {
                synchronized(inputQueue) {
                    inputQueue.queuedBytes = (inputQueue.queuedBytes - bytes.size).coerceAtLeast(0)
                }
                try { shellSession.session.write(bytes) } catch (_: Exception) {}
            }
        }

        shellSession.terminalOutputJob = TerminalSessionManager.scope.launch(Dispatchers.Default) {
            var cleanExit = false
            var lastSnapshotMs = 0L
            var pendingSnapshotJob: Job? = null
            try {
                // Control mode: the channel carries the tmux control protocol, not rendered ANSI.
                // Only the active pane's %output bytes reach the emulator; command replies and
                // notifications are protocol metadata. Recreated per (re)connect like the input
                // channel, so a reconnect never resumes half a protocol line.
                val controlParser = if (shellSession.controlMode) TmuxControlParser() else null
                session.output.collect { bytes ->
                    if (controlParser != null) {
                        var fed = false
                        for (event in controlParser.feed(bytes)) when (event) {
                            is TmuxControlEvent.Output ->
                                if (event.paneId == shellSession.activePaneId) {
                                    synchronized(emulator) { emulator.feed(event.data) }
                                    fed = true
                                }
                            is TmuxControlEvent.Reply -> {
                                synchronized(shellSession.controlReplyLock) {
                                    shellSession.controlRepliesSeen++
                                    if (event.isError && shellSession.controlRepliesSeen in shellSession.controlAwaitedOrdinals) {
                                        shellSession.controlReplyErrors[shellSession.controlRepliesSeen] =
                                            event.body.ifBlank { "tmux command failed" }
                                    }
                                }
                                shellSession.controlReplySignal.trySend(Unit)
                                if (event.isError) android.util.Log.w("OmniTermTmuxCtl", "tmux error: ${event.body}")
                            }
                            is TmuxControlEvent.SessionChanged -> {
                                val firstAttach = !shellSession.controlAttached.isCompleted
                                if (firstAttach) {
                                    synchronized(shellSession.controlReplyLock) {
                                        shellSession.controlReplyBaseline = shellSession.controlRepliesSeen
                                    }
                                    shellSession.controlAttached.complete(Unit)
                                } else {
                                    shellSession.controlPaneChangeRevision.incrementAndGet()
                                    refreshControlActivePane(shellSession)
                                }
                            }
                            is TmuxControlEvent.Notification -> {
                                if (event.line.startsWith("%window-pane-changed ") ||
                                    event.line.startsWith("%session-window-changed ") ||
                                    event.line.startsWith("%client-session-changed ") ||
                                    event.line.startsWith("%window-close ") ||
                                    event.line.startsWith("%window-add ")
                                ) {
                                    shellSession.controlPaneChangeRevision.incrementAndGet()
                                    refreshControlActivePane(shellSession)
                                }
                            }
                            is TmuxControlEvent.Exit -> {
                                shellSession.controlExitSeen = true
                                shellSession.controlExitReason = event.reason
                            }
                        }
                        // No scrollbackDirty here: control mode streams every byte, so the
                        // capture-pane re-sync is only needed after a reconnect (set there).
                        if (!fed) return@collect
                    } else {
                        synchronized(emulator) { emulator.feed(bytes) }
                        if (shellSession.persistent) shellSession.scrollbackDirty = true
                    }
                    val now = System.currentTimeMillis()
                    val elapsed = now - lastSnapshotMs
                    if (elapsed >= 16L) {
                        pendingSnapshotJob?.cancel(); pendingSnapshotJob = null
                        lastSnapshotMs = now
                        TerminalSessionManager.publishTerminalSnapshot(shellSession)
                    } else if (pendingSnapshotJob?.isActive != true) {
                        pendingSnapshotJob = launch {
                            delay(16L - elapsed)
                            lastSnapshotMs = System.currentTimeMillis()
                            TerminalSessionManager.publishTerminalSnapshot(shellSession)
                            pendingSnapshotJob = null
                        }
                    }
                }
                synchronized(emulator) { emulator.finishInput() }
                pendingSnapshotJob?.cancel()
                TerminalSessionManager.publishTerminalSnapshot(shellSession)
                // remoteExited is the authoritative "the user ended the shell/tmux" signal (genuine
                // remote channel-EOF). It's only ever true for a deliberate exit, never a socket drop.
                cleanExit = session.remoteExited.value || isCleanShellExit(session.exitStatus.value)
                if (shellSession.controlMode && shellSession.persistent && shellSession.controlExitSeen) {
                    // A control client may exit/detach while its tmux session remains healthy. Only
                    // forget recovery metadata when the server confirms the session itself is gone.
                    cleanExit = when (shellSession.creds?.let { remoteTmuxSessionExists(it, shellSession.tmuxName) }) {
                        false -> true
                        true, null -> false
                    }
                }
                android.util.Log.i(
                    "OmniTermSession",
                    "output flow completed normally: remoteExited=${session.remoteExited.value} " +
                        "exitStatus=${session.exitStatus.value} cleanExit=$cleanExit " +
                        "persistent=${shellSession.persistent} userClosed=${shellSession.userClosed}"
                )
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                // Non-cancellation: connection lost unexpectedly → fall through to reconnect.
                cleanExit = session.remoteExited.value
                android.util.Log.i(
                    "OmniTermSession",
                    "output flow ended with exception: ${e.javaClass.simpleName}: ${e.message} " +
                        "remoteExited=${runCatching { session.remoteExited.value }.getOrNull()} " +
                        "exitStatus=${runCatching { session.exitStatus.value }.getOrNull()}"
                )
            }

            // Teardown vs. reconnect decision, driven by cleanExit (= remoteExited: a genuine remote
            // channel-EOF). remoteExited is true ONLY for a deliberate exit and NEVER for a socket
            // death, so it cleanly separates the two cases:
            //
            //   • cleanExit (remote `exit`): tear the session down. For a persistent session this
            //     means the user fully exited tmux (inner shell → `exec tmux attach` → login shell all
            //     ended), so the tmux server is gone — do NOT reconnect, or it loops into a fresh
            //     session.
            //   • not cleanExit + creds + not user-closed (a drop): auto-reconnect (re-attaching tmux
            //     for a persistent session).
            //   • user-initiated close: tear down.
            val isUserClose = shellSession.userClosed
            val hasCreds = shellSession.creds != null
            val shouldReconnect = !isUserClose && hasCreds && !cleanExit
            val shouldTearDown = !shouldReconnect && (cleanExit || isUserClose)
            android.util.Log.i(
                "OmniTermSession",
                "teardown decision: cleanExit=$cleanExit shouldReconnect=$shouldReconnect " +
                    "shouldTearDown=$shouldTearDown creds=$hasCreds persistent=${shellSession.persistent} " +
                    "userClosed=$isUserClose"
            )
            withContext(Dispatchers.Main) {
                shellSession.isConnected = false
                TerminalSessionManager.updateKeepaliveCount()
                if (shouldReconnect) {
                    rememberRestorablePersistentSession(shellSession)
                    reconnectSession(shellSession)
                } else if (shouldTearDown) {
                    if (shellSession.persistent) {
                        forgetPersistentSession(shellSession.tmuxName)
                    }
                    cleanupSession(shellSession)
                } else {
                    shellSession.disconnectError = "Connection lost."
                    rememberRestorablePersistentSession(shellSession)
                    TerminalSessionManager.startKeepAliveService()
                }
            }
        }
    }

    private val persistentSessionMutationMutex = Mutex()

    private suspend fun rememberRestorablePersistentSession(shellSession: ShellSession) {
        if (!shellSession.persistent) return
        val entity = PersistentSessionEntity(
            shellSession.tmuxName,
            shellSession.serverId,
            shellSession.serverName,
        )
        persistentSessionMutationMutex.withLock {
            repository.upsertPersistentSession(entity)
            if (restorablePersistentSessions.none { it.tmuxName == entity.tmuxName }) {
                restorablePersistentSessions = restorablePersistentSessions + entity
            }
        }
    }

    private fun nextTmuxSessionName(): String {
        val existingNames = buildSet {
            activeSessions.forEach { add(it.tmuxName) }
            restorablePersistentSessions.forEach { add(it.tmuxName) }
        }
        return generateUniqueTmuxSessionName(existingNames)
    }

    private suspend fun forgetPersistentSession(tmuxName: String) {
        persistentSessionMutationMutex.withLock {
            repository.deletePersistentSession(tmuxName)
            restorablePersistentSessions = restorablePersistentSessions.filter { it.tmuxName != tmuxName }
        }
    }

    private suspend fun remoteTmuxSessionExists(creds: SshCredentials, tmuxName: String): Boolean? {
        val out = sshTransport.exec(creds, RemoteCommands.tmuxHasSessionCommand(tmuxName)).trim()
        return when {
            out.endsWith("yes") -> true
            out.endsWith("no") -> false
            else -> null
        }
    }

    /**
     * Auto-reconnect a dropped session with capped exponential backoff. Reopens a shell with the
     * same credentials, re-attaches the per-session tmux (if persistent) so a long-running command
     * resumes, writes a "— reconnected —" marker into the kept scrollback, and re-wires I/O. Gives
     * up after [RECONNECT_MAX_ATTEMPTS], leaving a "Connection lost." session the user can retry.
     */
    private fun reconnectSession(shellSession: ShellSession) {
        if (shellSession.reconnectJob?.isActive == true) return
        val creds = shellSession.creds ?: return
        shellSession.reconnecting = true
        shellSession.disconnectError = null
        TerminalSessionManager.updateKeepaliveCount()
        TerminalSessionManager.startKeepAliveService()
        shellSession.reconnectJob = TerminalSessionManager.scope.launch(Dispatchers.IO) {
            var delayMs = RECONNECT_BASE_DELAY_MS
            for (attempt in 1..RECONNECT_MAX_ATTEMPTS) {
                if (shellSession.userClosed) return@launch
                delay(delayMs)
                delayMs = (delayMs * 2).coerceAtMost(RECONNECT_MAX_DELAY_MS)
                val newSession = try {
                    sshTransport.openShell(creds, shellSession.lastCols, shellSession.lastRows)
                } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    null
                } ?: continue
                var adopted = false
                try {
                    currentCoroutineContext().ensureActive()
                    if (shellSession.userClosed) return@launch
                    if (shellSession.persistent) {
                        val tmuxAvailable = when (remoteTmuxSessionExists(creds, shellSession.tmuxName)) {
                            false -> {
                                withContext(Dispatchers.Main) {
                                    shellSession.reconnecting = false
                                    shellSession.disconnectError = "Server disconnected; tmux session is no longer running."
                                    forgetPersistentSession(shellSession.tmuxName)
                                    cleanupSession(shellSession)
                                    terminalConnectError = "Server disconnected; tmux session is no longer running."
                                }
                                return@launch
                            }
                            null -> false
                            true -> true
                        }
                        if (!tmuxAvailable) continue
                    }
                    currentCoroutineContext().ensureActive()
                    if (shellSession.userClosed) return@launch
                    if (shellSession.persistent) {
                        synchronized(shellSession.emulator) {
                            shellSession.emulator.setCaptureAlternateScreenScrollback(!shellSession.controlMode)
                        }
                        val attach = if (shellSession.controlMode) {
                            RemoteCommands.tmuxControlAttachCommand(shellSession.tmuxName, terminalScrollbackLimit)
                        } else {
                            RemoteCommands.tmuxAttachCommand(shellSession.tmuxName, terminalScrollbackLimit)
                        }
                        newSession.write(attach.toByteArray())
                        check(!newSession.closed.value) { "SSH channel closed while reattaching tmux" }
                    }
                    currentCoroutineContext().ensureActive()
                    synchronized(shellSession.sessionOwnershipLock) {
                        check(!shellSession.userClosed) { "Session closed while reconnecting" }
                        shellSession.session = newSession
                        adopted = true
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                    continue
                } finally {
                    if (!adopted) runCatching { newSession.close() }
                }
                try {
                    shellSession.controlInitJob?.cancel()
                    shellSession.controlReady = false
                    shellSession.controlInitFailed = false
                    shellSession.activePaneId = null
                    // Visible marker in the kept scrollback so the user knows the stream resumed.
                    synchronized(shellSession.emulator) {
                        shellSession.emulator.feed("\r\n\u001B[32m-- reconnected --\u001B[0m\r\n".toByteArray())
                    }
                    withContext(Dispatchers.Main) {
                        synchronized(shellSession.sessionOwnershipLock) {
                            check(!shellSession.userClosed && shellSession.session === newSession) {
                                "Session closed while finalising reconnect"
                            }
                            shellSession.isConnected = true
                            shellSession.reconnecting = false
                            shellSession.disconnectError = null
                            TerminalSessionManager.updateKeepaliveCount()
                            TerminalSessionManager.startKeepAliveService()
                        }
                    }
                    currentCoroutineContext().ensureActive()
                    // Cleanup and this handoff share the ownership lock. Either cleanup wins and
                    // this check refuses to install jobs, or wiring wins and cleanup subsequently
                    // sees/cancels every newly installed job before closing the adopted session.
                    synchronized(shellSession.sessionOwnershipLock) {
                        check(!shellSession.userClosed && shellSession.session === newSession) {
                            "Session closed before reconnect I/O handoff"
                        }
                        // Clear the reconnect guard before starting output: a replacement that dies
                        // immediately must be able to schedule another reconnect.
                        shellSession.reconnectJob = null
                        wireSessionIo(shellSession)
                        if (shellSession.controlMode) {
                            // Output during the drop never streamed — the one gap control mode has.
                            shellSession.scrollbackDirty = true
                            initControlModeSession(shellSession, creds)
                        }
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    runCatching { newSession.close() }
                    throw e
                } catch (_: Exception) {
                    runCatching { newSession.close() }
                    if (shellSession.userClosed) return@launch
                    continue
                }
                return@launch
            }
            // Exhausted attempts.
            withContext(Dispatchers.Main) {
                shellSession.reconnecting = false
                shellSession.disconnectError = "Connection lost — reconnect failed."
                rememberRestorablePersistentSession(shellSession)
                if (shellSession.persistent) {
                    cleanupSession(shellSession)
                    if (currentSessionId == shellSession.id) currentSessionId = null
                } else {
                    TerminalSessionManager.updateKeepaliveCount()
                    if (TerminalSessionManager.activeKeepaliveSessionsCount == 0) {
                        TerminalSessionManager.stopKeepAliveService()
                    } else {
                        TerminalSessionManager.startKeepAliveService()
                    }
                }
            }
        }
    }

    /** Manually retry a dropped session (the UI "Reconnect" button after auto-retry gives up). */
    fun retrySession(sessionId: String) {
        val s = activeSessions.find { it.id == sessionId } ?: return
        if (s.isConnected || s.reconnecting) return
        reconnectSession(s)
    }

    // ── tmux (persistent session) install gating ──
    // Hosts whose tmux presence we've confirmed this run, so we only probe once per host.
    private val tmuxVerifiedServerIds = mutableSetOf<Int>()
    /** Non-null ⇒ show the "Install tmux?" dialog for this server (persistent mode, tmux missing). */
    var tmuxInstallPromptServer by mutableStateOf<ServerEntity?>(null)
    /** Streamed output of the tmux install, shown live in the dialog; null when not installing. */
    var tmuxInstallOutput by mutableStateOf<String?>(null)
    var tmuxInstalling by mutableStateOf(false)

    fun dismissTmuxInstallPrompt() {
        tmuxInstallPromptServer = null
        tmuxInstallOutput = null
        tmuxInstalling = false
    }

    /** Connect once without persistence — user declined installing tmux but still wants a shell. */
    fun connectWithoutPersistence() {
        val srv = tmuxInstallPromptServer ?: return
        dismissTmuxInstallPrompt()
        connectTerminal(srv, forceDisablePersistence = true)
    }

    /**
     * Install tmux on the prompted host (with the user's confirmation), streaming progress into the
     * dialog, then mark it verified and connect. Uses the host's sudo password via stdin when set.
     */
    fun installTmuxAndConnect() {
        val srv = tmuxInstallPromptServer ?: return
        if (tmuxInstalling) return
        tmuxInstalling = true
        tmuxInstallOutput = ""
        viewModelScope.launch {
            val creds = buildCredentials(srv)
            val stdin = srv.sudoPassword.takeIf { it.isNotBlank() }?.let { "$it\n" }
            val result = runCatching {
                sshTransport.execStream(creds, RemoteCommands.tmuxInstallCommand(), stdin) { chunk ->
                    withContext(Dispatchers.Main) { tmuxInstallOutput = (tmuxInstallOutput ?: "") + chunk }
                }
            }
            tmuxInstalling = false
            val ok = result.getOrNull()?.let { sshTransport.exec(creds, RemoteCommands.TMUX_CHECK).trim().endsWith("yes") } == true
            if (ok) {
                tmuxVerifiedServerIds.add(srv.id)
                dismissTmuxInstallPrompt()
                connectTerminal(srv, forceDisablePersistence = false)
            } else {
                tmuxInstallOutput = (tmuxInstallOutput ?: "") +
                    "\n\nInstall did not complete. You can retry, connect non-resumable, or install tmux manually."
            }
        }
    }

    /** Tell the shell + emulator about the visible grid size (from the UI measurement). */
    fun resizeTerminal(cols: Int, rows: Int) = resizeTerminalFor(currentSession, cols, rows)

    /**
     * Resize a specific session's PTY. Session-parameterized so each split pane can size its own
     * remote terminal independently (a side-by-side pane is narrower than a full-screen one). The
     * grid is tracked per-session on [ShellSession.termCols]/[ShellSession.termRows]; the global
     * termCols/termRows only mirror the single-session (currentSession) path so a freshly opened
     * session still seeds at the last full-screen size.
     */
    fun resizeTerminalFor(session: ShellSession?, cols: Int, rows: Int) {
        if (cols < 1 || rows < 1) return
        val s = session ?: return
        if (cols == s.termCols && rows == s.termRows) return
        s.termCols = cols; s.termRows = rows
        s.lastCols = cols; s.lastRows = rows
        if (s.id == currentSessionId) { termCols = cols; termRows = rows }
        synchronized(s.emulator) {
            s.emulator.resize(cols, rows)
        }
        TerminalSessionManager.publishTerminalSnapshot(s)
        // Remote resize goes through the session's conflated channel + single consumer so a burst
        // of resizes (layout flip, IME churn) can never land out of order and strand the remote at
        // a stale size (see ShellSession.resizeChannel). `s.session` is read at send time so the
        // consumer follows a reconnect's channel swap, same as the input job.
        s.resizeChannel.trySend(cols to rows)
        if (s.resizeJob?.isActive != true) {
            s.resizeJob = TerminalSessionManager.scope.launch(Dispatchers.IO) {
                for ((c, r) in s.resizeChannel) {
                    try { s.session.resize(c, r) } catch (_: Exception) {}
                }
            }
        }
        // Control clients aren't sized by their PTY — tmux takes the size from refresh-client.
        if (s.controlMode && s.controlReady) sendControlLine(s, TmuxControlCommands.refreshClientSize(cols, rows))
        // Any grid change makes the locally reflowed scrollback diverge from the pane's real
        // history (tmux moves lines between screen and history on its own terms, and streams
        // nothing for it). Re-arm the capture-pane re-sync so the next scroll-up rebuilds from
        // the authoritative history — without this, history looked intact only until the first
        // resize after the post-connect sync (e.g. backgrounding the app bounces the IME and
        // resizes every pane, then scroll-up showed gaps/"disappeared" history).
        if (s.persistent) s.scrollbackDirty = true
    }

    fun updateTerminalViewport(firstRow: Int, rowCount: Int, followTail: Boolean) =
        updateTerminalViewportFor(currentSession, firstRow, rowCount, followTail)

    fun updateTerminalViewportFor(session: ShellSession?, firstRow: Int, rowCount: Int, followTail: Boolean) {
        val s = session ?: return
        val count = rowCount.coerceIn(1, 300)
        val changed = s.viewportFirstRow != firstRow || s.viewportRowCount != count || s.followTail != followTail
        s.viewportFirstRow = firstRow.coerceAtLeast(0)
        s.viewportRowCount = count
        s.followTail = followTail
        if (changed) TerminalSessionManager.publishTerminalSnapshot(s)
    }

    fun terminalBufferText(full: Boolean, firstRow: Int = 0, rowCount: Int = Int.MAX_VALUE): String =
        terminalBufferTextFor(currentSession, full, firstRow, rowCount)

    fun terminalBufferTextFor(session: ShellSession?, full: Boolean, firstRow: Int = 0, rowCount: Int = Int.MAX_VALUE): String {
        val s = session ?: return ""
        val scrollbackRows: Int
        val rows = synchronized(s.emulator) {
            scrollbackRows = s.emulator.scrollbackRowCount()
            if (full) s.emulator.snapshot().rows
            else s.emulator.snapshotRange(firstRow, rowCount).rows
        }
        var termRows = rows
        if (full) {
            // tmux (and other full-screen apps we capture scrollback from) often replays the visible
            // pane right after a scroll, so the tail of captured scrollback repeats the head of the
            // live screen verbatim. That overlap is why "Full buffer" showed duplicated content. Drop
            // the longest exact run where scrollback's tail equals the screen's head — a conservative
            // collapse at just the scrollback↔screen boundary, so genuinely repeated output elsewhere
            // in the buffer is left intact.
            termRows = dropBoundaryDuplication(termRows, scrollbackRows) { row ->
                row.spans.joinToString("") { it.text }.trimEnd()
            }
        }
        // Re-join soft-wrapped rows so a long line that only broke at the right edge copies as one
        // logical line instead of picking up a newline per visual row.
        return joinRowsRespectingWraps(termRows)
    }

    fun clearTerminalScrollback() = clearTerminalScrollbackFor(currentSession)

    fun clearTerminalScrollbackFor(session: ShellSession?) {
        val s = session ?: return
        synchronized(s.emulator) {
            s.emulator.clearScrollback()
        }
        s.viewportFirstRow = 0
        s.followTail = true
        TerminalSessionManager.publishTerminalSnapshot(s)
    }

    private fun sendBytes(bytes: ByteArray) = sendBytesTo(focusedTerminalSession, bytes)

    /**
     * Write to a specific session's bounded input channel. Large payloads are chunked and sent with
     * blocking backpressure so ordering is preserved without an unbounded in-memory queue. Avoid
     * coroutine fallbacks here; they can reorder paste/key bytes. Used by per-pane scroll/jump in
     * split mode so a gesture on one pane reaches THAT pane's remote, not whichever pane currently
     * has keyboard focus.
     */
    private fun sendBytesTo(session: ShellSession?, bytes: ByteArray) {
        val s = session ?: return
        if (s.controlMode) {
            // Control mode: keystrokes become `send-keys -H` command lines (already chunked by
            // the encoder). Input typed before the active pane is known is queued and flushed by
            // the control-mode init — sending it raw would execute as tmux commands.
            var pane: String? = null
            var queuedDuringInit = false
            var overflowed = false
            synchronized(s.pendingControlInput) {
                if (!s.controlReady) {
                    queuedDuringInit = true
                    if (!s.controlInitFailed && s.pendingControlInputBytes + bytes.size <= CONTROL_PENDING_INPUT_MAX_BYTES) {
                        s.pendingControlInput.add(bytes)
                        s.pendingControlInputBytes += bytes.size
                    } else if (!s.controlInitFailed) {
                        overflowed = true
                    }
                } else {
                    pane = s.activePaneId
                }
            }
            if (overflowed) warnTerminalInputOverflow(s, controlInit = true)
            if (queuedDuringInit) return
            val targetPane = pane ?: return
            val batch = TmuxControlCommands.sendKeysHex(targetPane, bytes)
                .map { (it + "\n").toByteArray() }
            if (enqueueControlCommandBatch(s, batch) == null) {
                warnTerminalInputOverflow(s)
            }
            return
        }
        if (bytes.size <= TERMINAL_INPUT_CHUNK_BYTES) {
            if (!enqueueTerminalWireBytes(s, bytes)) warnTerminalInputOverflow(s)
            return
        }
        if (bytes.size > TERMINAL_INPUT_QUEUE_MAX_BYTES) {
            warnTerminalInputOverflow(s)
            return
        }
        val chunks = ArrayList<ByteArray>((bytes.size + TERMINAL_INPUT_CHUNK_BYTES - 1) / TERMINAL_INPUT_CHUNK_BYTES)
        var offset = 0
        while (offset < bytes.size) {
            val end = (offset + TERMINAL_INPUT_CHUNK_BYTES).coerceAtMost(bytes.size)
            chunks.add(bytes.copyOfRange(offset, end))
            offset = end
        }
        if (!enqueueTerminalWireBatch(s, chunks)) warnTerminalInputOverflow(s)
    }

    /** Printable text typed by the user (soft or hardware keyboard). Applies sticky Ctrl/Alt. */
    fun typeText(text: String) {
        val session = focusedTerminalSession ?: return
        if (text.isEmpty() || !session.isConnected) return
        // Printable input exits tmux copy-mode, so the pane is back at the live tail — drop the
        // jump-to-bottom flag to match. (Wheel scrolling re-arms it in terminalMouseWheel.)
        if (session.tmuxScrolledBack) session.tmuxScrolledBack = false
        pendingSwipeFlush?.invoke()
        var t = text
        if (isShiftPressed && t.codePointCount(0, t.length) == 1) {
            t = t.uppercase()
        }
        if (isCtrlPressed || isAltPressed) {
            val out = ArrayList<Byte>()
            if (isAltPressed) out.add(0x1B)
            val firstCodePoint = t.codePointAt(0)
            val firstEnd = Character.charCount(firstCodePoint)
            val control = if (isCtrlPressed) TerminalKeyEncoder.controlByte(firstCodePoint) else null
            if (control != null) {
                out.add(control)
                if (firstEnd < t.length) out.addAll(t.substring(firstEnd).toByteArray().toList())
            } else {
                // Ctrl has no portable byte representation for non-ASCII text. Preserve the full
                // scalar instead of splitting a surrogate pair or emitting an arbitrary mask.
                out.addAll(t.toByteArray().toList())
            }
            isCtrlPressed = false
            isAltPressed = false
            isShiftPressed = false
            sendBytes(out.toByteArray())
        } else {
            sendBytes(t.toByteArray())
            isShiftPressed = false
        }
    }

    /**
     * Send a multi-character block (a paste) as a single ordered write. Sending the whole block at
     * once — rather than one typeText() call per character — keeps the bytes contiguous and avoids
     * any chance of interleaving with other input. Newlines are normalized to CR (0x0D), matching
     * what the Enter key sends, so each pasted line is submitted as the shell expects. Sticky
     * Ctrl/Alt/Shift modifiers are intentionally ignored for bulk paste.
     */
    fun pasteText(text: String) {
        val session = focusedTerminalSession ?: return
        if (text.isEmpty() || !session.isConnected) return
        val normalized = text.replace("\r\n", "\n").replace('\n', '\r')
        val bracketed = synchronized(session.emulator) { session.emulator.bracketedPasteMode }
        val payload = if (bracketed) "\u001B[200~$normalized\u001B[201~" else normalized
        sendBytes(payload.toByteArray())
    }

    /**
     * Apply an editor-style line edit from the swipe input field: [backspaces] DEL bytes (0x7F) to
     * erase the changed tail, then the [insert] text. Sent as one ordered write and deliberately does
     * NOT trigger pendingSwipeFlush — it IS the field mirroring its own edit, not a shell-owned key.
     */
    fun applyLineEdit(backspaces: Int, insert: String) {
        val session = focusedTerminalSession ?: return
        if (!session.isConnected) return
        if (backspaces <= 0 && insert.isEmpty()) return
        val out = ArrayList<Byte>(backspaces + insert.length)
        repeat(backspaces) { out.add(0x7F) }
        out.addAll(insert.toByteArray().toList())
        sendBytes(out.toByteArray())
    }

    fun sendKey(key: TermKey) {
        val session = focusedTerminalSession ?: return
        if (!session.isConnected) return
        pendingSwipeFlush?.invoke()
        val app = synchronized(session.emulator) { session.emulator.applicationCursorKeys }
        val seq = TerminalKeyEncoder.encode(
            key = key,
            applicationCursorKeys = app,
            shift = isShiftPressed,
            alt = isAltPressed,
            ctrl = isCtrlPressed,
        )
        sendBytes(seq)
        isCtrlPressed = false
        isAltPressed = false
        isShiftPressed = false
    }

    /**
     * Touch scrolling should behave like a normal Android scroll view: the content tracks the finger
     * against the local terminal buffer. Forwarding drags into tmux mouse-wheel copy-mode made the
     * direction and bottom state feel inconsistent, so remote mouse-wheel scrolling is reserved for
     * explicit key actions rather than ordinary touch scroll gestures.
     */
    fun terminalScrollForwardsToRemote(): Boolean = false

    fun terminalScrollForwardsToRemoteFor(session: ShellSession?): Boolean = false

    /**
     * Forward a vertical scroll gesture to the remote as SGR (1006) mouse-wheel events. [wheelUp]
     * picks wheel-up (button 64, scroll back into history) vs wheel-down (button 65). [ticks] is how
     * many discrete wheel notches the gesture covered. Coordinates are 1-based; we report the gesture
     * at the top-left cell, which is sufficient for tmux copy-mode scrolling (it scrolls the pane the
     * pointer is over, and a single pane fills the view). No-ops for a non-tmux/disconnected session.
     */
    fun terminalMouseWheel(wheelUp: Boolean, ticks: Int = 1) =
        terminalMouseWheelFor(focusedTerminalSession, wheelUp, ticks)

    fun terminalMouseWheelFor(session: ShellSession?, wheelUp: Boolean, ticks: Int = 1) {
        val s = session ?: return
        if (!s.isConnected || !s.persistent) return
        // A wheel-up scroll puts tmux into copy-mode; remember it so the terminal can show the
        // jump-to-bottom control. Only ARM here, never clear: a wheel-down tick doesn't mean
        // copy-mode exited (tmux only leaves it at the very bottom of history), and drag gestures
        // routinely end with a tiny reversed delta — clearing on wheel-down made the control
        // vanish while the pane was still scrolled back. Cleared by jump-to-tail and typeText.
        if (wheelUp) s.tmuxScrolledBack = true
        val button = if (wheelUp) 64 else 65
        val out = ArrayList<Byte>(ticks.coerceIn(1, 10) * 8)
        // SGR mouse: ESC [ < button ; col ; row M   (M = press; wheel has no release).
        val seq = "[<$button;1;1M".toByteArray()
        repeat(ticks.coerceIn(1, 10)) { seq.forEach { out.add(it) } }
        sendBytesTo(s, out.toByteArray())
    }

    /**
     * True when a tmux (persistent) session has been scrolled up into copy-mode, so the terminal
     * should offer a jump-to-bottom control. Reset on jump-to-bottom or session switch.
     */
    val terminalTmuxScrolledBack: Boolean get() = currentSession?.tmuxScrolledBack == true

    fun clearTerminalTmuxScrolledBack() { currentSession?.tmuxScrolledBack = false }

    /**
     * Return a scrolled-up tmux pane to the live tail by leaving copy-mode. Uses a side exec
     * channel to run `tmux send-keys -X cancel` against the session — NOT a `q` typed into the
     * PTY, which turned into a literal letter q at the prompt whenever the pane had already left
     * copy-mode on its own (tmux exits it when wheel-scrolled back to the bottom). No-op for
     * non-tmux sessions and outside copy-mode.
     */
    fun terminalJumpToLiveTail() = terminalJumpToLiveTailFor(focusedTerminalSession)

    fun terminalJumpToLiveTailFor(session: ShellSession?) {
        val s = session ?: return
        if (!s.isConnected || !s.persistent) return
        s.tmuxScrolledBack = false
        val creds = s.creds
        if (creds != null) {
            viewModelScope.launch(Dispatchers.IO) {
                runCatching { sshTransport.exec(creds, RemoteCommands.tmuxExitCopyModeCommand(s.tmuxName)) }
            }
        } else {
            // No stored credentials for a side channel (shouldn't happen for persistent sessions):
            // fall back to the in-band copy-mode cancel key.
            sendBytesTo(s, "q".toByteArray())
        }
    }

    fun disconnectTerminal() {
        val s = terminalActionSession ?: return
        disconnectSession(s.id)
    }

    fun sendToBackground() {
        val s = terminalActionSession ?: return
        sendSessionToBackground(s.id)
    }

    /** Keep a live SSH channel running, but remove it from the visible terminal pane. */
    fun sendSessionToBackground(sessionId: String) {
        val s = activeSessions.find { it.id == sessionId } ?: return
        if (isMultiSsh) clearMultiSshRefsFor(s.id)
        if (currentSessionId == s.id) currentSessionId = null
        // Stay on Shell — ShellScreen shows SessionPicker when currentSession==null && activeSessions.isNotEmpty()
        // Always start the service so per-session notifications with Disconnect buttons appear
        val connected = activeSessions.filter { it.isConnected }
        if (connected.isNotEmpty()) {
            val context = getApplication<android.app.Application>()
            val svcIntent = android.content.Intent(context, com.jetsetslow.omniterm.SessionService::class.java).apply {
                action = com.jetsetslow.omniterm.SessionService.ACTION_UPDATE_SESSIONS
                putStringArrayListExtra(com.jetsetslow.omniterm.SessionService.EXTRA_SESSIONS, encodeSessionNotificationPayload(connected))
            }
            try { androidx.core.content.ContextCompat.startForegroundService(context, svcIntent) } catch (_: Exception) {}
        }
    }

    fun attachSession(sessionId: String) {
        val session = activeSessions.find { it.id == sessionId }
        if (session == null) {
            // Session was lost (app process was restarted while service notification persisted).
            // Cancel the stale notification and navigate to Shell so user can reconnect.
            val context = getApplication<android.app.Application>()
            (context.getSystemService(android.app.NotificationManager::class.java))
                ?.cancel(sessionId.hashCode())
            screenHistory.clear()
            screenHistory.add(Screen.Servers)
            screenHistory.add(Screen.Shell)
            currentScreen = Screen.Shell
            return
        }
        selectedServerId = session.serverId
        currentSessionId = sessionId
        TerminalSessionManager.publishTerminalSnapshot(session)
        screenHistory.clear()
        screenHistory.add(Screen.Servers)
        screenHistory.add(Screen.Shell)
        currentScreen = Screen.Shell
    }

    fun disconnectSession(sessionId: String) {
        val s = activeSessions.find { it.id == sessionId } ?: return
        // User-initiated: stop any auto-reconnect in flight and don't start a new one on teardown.
        s.userClosed = true
        s.reconnectJob?.cancel()
        // A user-closed persistent session should also kill its tmux session server-side and forget
        // it, so it isn't re-offered next launch. (A drop/background does NOT do this — that's the point.)
        if (s.persistent) {
            val creds = s.creds
            viewModelScope.launch {
                val confirmedGone = if (creds != null) {
                    withContext(Dispatchers.IO) {
                        val kill = sshTransport.exec(creds, RemoteCommands.tmuxKillCommand(s.tmuxName))
                        !kill.startsWith("SSH Error:") && remoteTmuxSessionExists(creds, s.tmuxName) == false
                    }
                } else false
                if (confirmedGone) {
                    forgetPersistentSession(s.tmuxName)
                } else {
                    terminalConnectError =
                        "Disconnected locally, but the remote tmux session could not be confirmed stopped. It remains available for recovery."
                }
            }
        }
        // cleanupSession closes the socket off the main thread (JSch disconnect can block on network
        // I/O — on a dead/changed network a synchronous close would freeze the UI, which is exactly
        // the "can't disconnect" limbo this avoids) and removes the session from the active list.
        cleanupSession(s)
    }

    fun requestDisconnectSession(sessionId: String) {
        pendingDisconnectSessionId = sessionId
    }

    fun leaveSessionResumable(sessionId: String) {
        val s = activeSessions.find { it.id == sessionId } ?: return
        if (!s.persistent) {
            disconnectSession(sessionId)
            return
        }
        s.userClosed = true
        s.reconnectJob?.cancel()
        viewModelScope.launch {
            rememberRestorablePersistentSession(s)
            // cleanupSession closes the socket off the main thread (see disconnectSession).
            cleanupSession(s)
            if (currentSessionId == sessionId) currentSessionId = null
        }
    }

    fun requestDisconnectAllSessions() {
        pendingDisconnectAllSessions = true
    }

    fun cancelPendingDisconnect() {
        pendingDisconnectSessionId = null
        pendingDisconnectAllSessions = false
    }

    fun closeAllSessions() {
        activeSessions.toList().forEach { disconnectSession(it.id) }
        currentSessionId = null
        stopKeepAliveService()
    }

    fun cleanupSession(s: ShellSession) {
        TerminalSessionManager.cleanupSession(s)
        if (currentSessionId == s.id) currentSessionId = null
        // A torn-down session must not linger as a split-view pane reference, or the pane would keep
        // rendering a dead emulator and route input into a closed channel.
        clearMultiSshRefsFor(s.id)
    }

    /** One-shot remote command (used by Fleet broadcast). [stdin] feeds e.g. `sudo -S`. */
    suspend fun executeSshCommand(srv: ServerEntity, command: String, stdin: String? = null): String =
        sshTransport.exec(buildCredentials(srv), command, stdin)

    // ── CONTAINERS (Docker or Podman over SSH) ──
    fun loadDocker() {
        val srv = selectedServer ?: return
        dockerJob?.cancel()
        dockerJob = viewModelScope.launch {
            dockerLoading = true
            dockerError = null
            try {
                coroutineScope {
                    val outAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_PS) }
                    val restartsAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_RESTARTS) }
                    val imagesAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_IMAGES) }
                    val volumesAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_VOLUMES) }
                    val networksAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_NETWORKS) }
                    val runtimesAsync = async { executeSshCommand(srv, RemoteCommands.DOCKER_RUNTIMES) }

                    val out = outAsync.await()
                    if (srv.id != selectedServerId) return@coroutineScope
                    if (out.startsWith("SSH Error")) {
                        dockerError = out
                        dockerContainers = emptyList()
                        dockerImages = emptyList()
                        dockerVolumes = emptyList()
                        dockerNetworks = emptyList()
                        availableContainerRuntimes = emptySet()
                        // A transport failure says nothing about stack state — don't present
                        // registry rows as "down" (or keep another host's list) on no evidence.
                        downedStacks = emptyList()
                    } else {
                        val restarts = runCatching { RemoteParsers.parseDockerRestartCounts(restartsAsync.await()) }.getOrDefault(emptyMap())
                        if (srv.id != selectedServerId) return@coroutineScope

                        val parsedContainers = RemoteParsers.parseDockerPs(out).map {
                            it.copy(host = srv.name, restartCount = restarts["${it.runtime}:${it.id}"] ?: restarts[it.id] ?: it.restartCount)
                        }
                        dockerContainers = parsedContainers
                        syncStackRegistry(srv, parsedContainers)

                        val imgOut = imagesAsync.await()
                        dockerImages = RemoteParsers.parseDockerImages(imgOut).map { img ->
                            val inUse = parsedContainers.any { c ->
                                c.runtime == img.runtime &&
                                    (c.image == img.repository || c.image == "${img.repository}:${img.tag}" || c.image.contains(img.id.take(12)))
                            }
                            img.copy(inUse = inUse)
                        }

                        val volOut = volumesAsync.await()
                        dockerVolumes = RemoteParsers.parseDockerVolumes(volOut)

                        val netOut = networksAsync.await()
                        dockerNetworks = RemoteParsers.parseDockerNetworks(netOut)

                        availableContainerRuntimes = RemoteParsers.parseRuntimeList(runtimesAsync.await())
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (srv.id == selectedServerId) {
                    dockerError = e.message ?: "Could not query containers."
                    dockerContainers = emptyList()
                    dockerImages = emptyList()
                    dockerVolumes = emptyList()
                    dockerNetworks = emptyList()
                    availableContainerRuntimes = emptySet()
                    downedStacks = emptyList()
                }
            } finally {
                if (srv.id == selectedServerId) dockerLoading = false
            }
        }
    }

    fun dockerAction(containerId: String, action: String, runtime: String = "") {
        runStreamingAction("container $action", RemoteCommands.dockerAction(containerId, action, runtime)) { loadDocker() }
    }

    fun dockerImageAction(imageId: String, action: String, runtime: String = "") {
        runStreamingAction("image $action", RemoteCommands.dockerImageAction(imageId, action, runtime)) { loadDocker() }
    }

    fun dockerVolumeAction(volumeName: String, action: String, runtime: String = "") {
        runStreamingAction("volume $action", RemoteCommands.dockerVolumeAction(volumeName, action, runtime)) { loadDocker() }
    }

    fun dockerNetworkAction(networkId: String, action: String, runtime: String = "") {
        runStreamingAction("network $action", RemoteCommands.dockerNetworkAction(networkId, action, runtime)) { loadDocker() }
    }

    fun dockerPruneImages() {
        runStreamingAction("prune unused images", RemoteCommands.dockerPruneImages()) { loadDocker() }
    }

    fun dockerPruneVolumes() {
        runStreamingAction("prune unused volumes", RemoteCommands.dockerPruneVolumes()) { loadDocker() }
    }

    fun dockerPruneNetworks() {
        runStreamingAction("prune unused networks", RemoteCommands.dockerPruneNetworks()) { loadDocker() }
    }

    /** Stream a container's recent logs into the shared action panel. */
    fun dockerContainerLogs(containerId: String, name: String, runtime: String = "") {
        runStreamingAction("logs · $name", RemoteCommands.dockerLogs(containerId, runtime))
    }

    /** Show a one-shot resource-usage sample (CPU/mem/net/IO) for a container in the action panel. */
    fun dockerContainerStats(containerId: String, name: String, runtime: String = "") {
        runStreamingAction("stats · $name", RemoteCommands.dockerStats(containerId, runtime))
    }

    /**
     * Open an interactive shell inside a container: connects a fresh terminal to the container's host
     * and runs `docker/podman exec -it … bash||sh`. Needs the host it runs on — [SimContainer.host]
     * carries the server name, matched back to the ServerEntity.
     */
    fun dockerExecIntoContainer(container: SimContainer) {
        val srv = selectedServer?.takeIf { it.name == container.host }
            ?: servers.value.firstOrNull { it.name == container.host }
            ?: selectedServer
            ?: return
        openTerminalWithCommand(srv, RemoteCommands.dockerExecShell(container.id, container.runtime))
    }

    // ── Shared streaming-action panel ──

    /**
     * Run [command] on the selected host and stream its combined output into the shared live panel
     * (the same panel Docker stack actions use). [onComplete] runs once the stream ends, e.g. to
     * refresh the relevant list.
     */
    fun runStreamingAction(title: String, command: String, stdin: String? = null, onComplete: (() -> Unit)? = null) {
        val srv = selectedServer ?: return
        // Supersede any previous action so its late chunks can't bleed into this one.
        actionStreamJob?.cancel()
        val epoch = ++actionStreamEpoch
        actionStreamJob = viewModelScope.launch {
            actionStreamTitle = title
            actionStreamOutput = ""
            actionStreamRunning = true
            try {
                sshTransport.execStream(buildCredentials(srv), command, stdin) { chunk ->
                    // onChunk runs on the IO dispatcher; apply the snapshot-state write on Main.
                    if (epoch == actionStreamEpoch) withContext(Dispatchers.Main) {
                        if (epoch == actionStreamEpoch) {
                            val appended = actionStreamOutput + chunk
                            actionStreamOutput =
                                if (appended.length > ACTION_STREAM_MAX_CHARS) appended.takeLast(ACTION_STREAM_MAX_CHARS)
                                else appended
                        }
                    }
                }
            } finally {
                if (epoch == actionStreamEpoch) {
                    actionStreamRunning = false
                    // Make zero-output actions (kill, service start, …) read as clearly finished.
                    if (actionStreamOutput.isBlank()) actionStreamOutput = "Done (no output)"
                }
            }
            if (epoch == actionStreamEpoch) onComplete?.invoke()
        }
    }

    /** Show a static message in the action panel (used when an action isn't possible). */
    private fun showActionMessage(title: String, message: String) {
        actionStreamJob?.cancel()
        actionStreamEpoch++
        actionStreamTitle = title
        actionStreamOutput = message
        actionStreamRunning = false
    }

    /** Dismiss the action panel and stop any stream still feeding it. */
    fun closeActionStream() {
        actionStreamEpoch++          // invalidate appends from any in-flight stream
        actionStreamJob?.cancel()
        actionStreamJob = null
        actionStreamOutput = ""
        actionStreamTitle = ""
        actionStreamRunning = false
    }

    fun dockerStackAction(project: String, workingDir: String, configFiles: String, action: String, removeOrphans: Boolean = false, runtime: String = "") {
        if (project == "standalone" || workingDir.isBlank()) {
            showActionMessage(project, "This stack does not expose compose working directory labels, so OmniTerm cannot run compose actions for it.")
            return
        }
        runStreamingAction("$project · $action", RemoteCommands.dockerComposeAction(project, workingDir, configFiles, action, removeOrphans = removeOrphans, runtime = runtime)) { loadDocker() }
    }

    fun dockerStackUpdate(project: String, workingDir: String, configFiles: String, runtime: String = "") {
        dockerStackAction(project, workingDir, configFiles, "update", runtime = runtime)
    }

    /**
     * Record every compose stack visible in `ps -a` into the app-side stack registry, then diff
     * the registry against what's live to surface downed stacks. `compose down` deletes a stack's
     * containers and networks and the daemon keeps NO record of the project (`docker compose ls`
     * is container-derived too), so this registry is the only way to keep listing the stack and
     * offer to bring it back — the same approach Portainer/Dockge take. A stack the app never saw
     * while it was up has nothing recorded and cannot be surfaced.
     */
    private suspend fun syncStackRegistry(srv: ServerEntity, containers: List<SimContainer>) {
        val now = System.currentTimeMillis()
        val live = containers.filter { it.group != "standalone" }.groupBy { it.runtime to it.group }
        val seen = live.mapNotNull { (key, list) ->
            val (runtime, project) = key
            val configFiles = list.firstOrNull { it.composeConfigFiles.isNotBlank() }?.composeConfigFiles.orEmpty()
            val workingDir = RemoteParsers.composeStackWorkingDir(
                list.firstOrNull { it.composeWorkingDir.isNotBlank() }?.composeWorkingDir.orEmpty(),
                configFiles,
            )
            // No working dir ⇒ no compose actions can ever run for it (including a later UP), so
            // there is nothing actionable to record.
            if (workingDir.isBlank()) null
            else StackRegistryEntity(
                serverId = srv.id, runtime = runtime, project = project,
                workingDir = workingDir, configFiles = configFiles, lastSeenAt = now,
            )
        }
        // Registry bookkeeping must never break the container refresh itself.
        runCatching {
            if (seen.isNotEmpty()) repository.upsertStacks(seen)
            val downed = repository.getStacksForServer(srv.id).filter { (it.runtime to it.project) !in live.keys }
            if (srv.id == selectedServerId) downedStacks = downed
        }
    }

    /**
     * Bring a downed (registry-only) stack back up. The recorded compose config is verified to
     * still exist on the host first — it can be deleted or moved behind the app's back, and
     * compose's own missing-file error is confusing; a clear message + Forget is more honest.
     */
    fun bringUpDownedStack(stack: StackRegistryEntity) {
        val srv = selectedServer ?: return
        viewModelScope.launch {
            val probe = runCatching {
                executeSshCommand(srv, RemoteCommands.composeConfigPresent(stack.workingDir, stack.configFiles))
            }.getOrDefault("")
            if (!probe.contains("OMNITERM_COMPOSE_OK")) {
                showActionMessage(
                    stack.project,
                    "Compose file no longer exists on the host (recorded: " +
                        "${stack.configFiles.ifBlank { stack.workingDir }}). " +
                        "If the stack moved, bring it up once over SSH so it can be re-recorded; " +
                        "otherwise use Forget to drop it from this list.",
                )
                return@launch
            }
            dockerStackAction(stack.project, stack.workingDir, stack.configFiles, "up", runtime = stack.runtime)
        }
    }

    /** Drop a downed stack from the registry (the containers are already gone — this is list-only). */
    fun forgetDownedStack(stack: StackRegistryEntity) {
        viewModelScope.launch {
            runCatching { repository.deleteStack(stack.serverId, stack.runtime, stack.project) }
            downedStacks = downedStacks.filter { it.id != stack.id }
        }
    }

    /**
     * Read an existing compose file's raw text so the builder can edit it surgically. Returns null
     * (and shows nothing) on transport failure; returns "" when the file does not exist yet.
     */
    suspend fun readComposeFile(composeFilePath: String): String? {
        val srv = selectedServer ?: return null
        val out = executeSshCommand(srv, RemoteCommands.composeRead(composeFilePath))
        if (out.startsWith("SSH Error")) return null
        return if (out.trim() == "OMNITERM_NO_FILE") "" else out
    }

    /**
     * Deploy a compose file atomically: validate → swap → up, restoring the previous file if the
     * deploy fails. [onResult] receives (success, combinedOutput) so the UI can show a loud,
     * unambiguous outcome instead of mislabelling a failed deploy as success.
     */
    fun deployComposeStack(
        composeFilePath: String,
        project: String,
        yaml: String,
        workingDir: String = "",
        configFiles: String = "",
        runtime: String = "",
        onResult: (Boolean, String) -> Unit,
    ) {
        val srv = selectedServer ?: return onResult(false, "No host selected.")
        viewModelScope.launch {
            val b64 = android.util.Base64.encodeToString(yaml.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
            val cmd = RemoteCommands.composeDeploy(composeFilePath, project, b64, workingDir, configFiles, runtime)
            val out = executeSshCommand(srv, cmd)
            // Success only when the runtime printed our end-of-pipeline sentinel AND the transport
            // didn't report an SSH/command failure. Any compose validation or `up` error trips this.
            val ok = !out.startsWith("SSH Error") && out.contains("OMNITERM_DEPLOY_OK")
            // Strip the transport-wrapper prefix ("SSH Error: command failed (N): ") so the user
            // sees the actual docker/compose error text, not the JSch bookkeeping noise.
            val cleaned = out
                .replace("OMNITERM_DEPLOY_OK", "")
                .replace(Regex("^SSH Error: command failed \\(\\d+\\): "), "")
                .trim()
            // If compose up -d ran but nothing actually changed, every line ends with "Running"
            // or "Healthy" and no action verb appears. Flag it so the user knows what happened.
            val anyContainerChanged = ok && cleaned.contains(
                Regex("""(?m)^\s*Container\s+\S+\s+(Created|Recreated|Started|Stopped|Removed)\s*$""")
            )
            val msg = when {
                ok && anyContainerChanged -> cleaned.ifBlank { "Stack deployed." }
                ok -> cleaned.ifBlank { "Stack deployed — no containers changed (config already up to date)." }
                else -> cleaned.ifBlank { "Deploy failed." }
            }
            onResult(ok, msg)
            if (ok) loadDocker()
        }
    }

    fun dockerStackServiceAction(project: String, workingDir: String, configFiles: String, service: String, action: String, replicas: Int? = null, runtime: String = "") {
        if (project == "standalone" || workingDir.isBlank() || service.isBlank()) {
            showActionMessage("$project · $service", "This service does not expose enough compose metadata for service-level actions.")
            return
        }
        runStreamingAction(
            "$project/$service · $action",
            RemoteCommands.dockerComposeAction(project, workingDir, configFiles, action, service, replicas, runtime = runtime),
        ) { loadDocker() }
    }

    fun openDockerExecShell(containerId: String) {
        if (containerId.isBlank()) return
        navigateTo(Screen.Shell)
        if (!isTerminalConnected && !isTerminalConnecting) connectTerminal()
        viewModelScope.launch {
            // Wait (up to ~6s) for the shell to connect, then send the exec command as soon as
            // it's ready. `return@repeat` only ends one iteration, so exit via return@launch.
            repeat(30) {
                if (isTerminalConnected) {
                    val runtime = dockerContainers.firstOrNull { it.id == containerId }?.runtime.orEmpty()
                    typeText(RemoteCommands.dockerComposeExecShellCommand(containerId, runtime) + "\r")
                    return@launch
                }
                delay(200)
            }
        }
    }

    // ── SYSTEMD SERVICES (real `systemctl` over SSH) ──
    fun loadServices() {
        val srv = selectedServer ?: return
        servicesJob?.cancel()
        servicesJob = viewModelScope.launch {
            servicesLoading = true
            val parsed = RemoteParsers.parseServices(executeSshCommand(srv, RemoteCommands.SERVICES))
            if (srv.id != selectedServerId) return@launch
            services = parsed
            servicesLoading = false
        }
    }

    fun runServiceCommand(serviceName: String, action: String) {
        val srv = selectedServer ?: return
        withSudoAuth(srv) {
            runStreamingAction(
                "service $action $serviceName",
                RemoteCommands.serviceAction(serviceName, action, srv.sudoPassword),
                stdin = RemoteCommands.sudoStdin(srv.sudoPassword),
            ) { loadServices() }
        }
    }

    // ── LOGS (real `journalctl` over SSH) ──
    fun loadLogs(level: String) {
        val srv = selectedServer ?: return
        logsJob?.cancel()
        logsJob = viewModelScope.launch {
            logsLoading = true
            val all = RemoteParsers.parseJournal(executeSshCommand(srv, RemoteCommands.journal()))
            if (srv.id != selectedServerId) return@launch
            logs = if (level == "ALL") all else all.filter { it.level == level }
            logsLoading = false
        }
    }

    // ── HOST METRICS (real, for Monitor → Overview) ──
    fun loadHostMetrics() {
        val srv = selectedServer ?: return
        hostMetricsJob?.cancel()
        hostMetricsJob = viewModelScope.launch {
            metricsLoading = true
            val parsed = RemoteParsers.parseMetrics(executeSshCommand(srv, RemoteCommands.metricsFor(osByServer[srv.id].orEmpty())), srv.name)
            if (srv.id != selectedServerId) return@launch
            // This one-shot fetch can't compute per-core/network rates (those need two samples from
            // the poller), so preserve whatever the poller already derived for this host.
            val prev = hostMetricsById[srv.id]
            val m = parsed.copy(
                perCoreCpu = parsed.perCoreCpu.ifEmpty { prev?.perCoreCpu ?: emptyList() },
                netInterfaces = parsed.netInterfaces.ifEmpty { prev?.netInterfaces ?: emptyList() },
            )
            hostMetrics = m
            // Keep the shared map in sync so the Servers tab and Fleet always reflect the
            // most-recent values fetched by the Monitor tab as well.
            hostMetricsById[srv.id] = m
            metricsLoading = false
        }
    }

    // ── PROCESSES (real `ps` over SSH) ──
    fun loadProcesses() {
        val srv = selectedServer ?: return
        processesJob?.cancel()
        processesJob = viewModelScope.launch {
            processesLoading = true
            val list = RemoteParsers.parseProcesses(executeSshCommand(srv, RemoteCommands.processesFor(osByServer[srv.id].orEmpty())))
            if (srv.id != selectedServerId) return@launch
            processes = if (processSortByCpu) list.sortedByDescending { it.cpu }
                        else list.sortedByDescending { it.mem }
            processesLoading = false
        }
    }

    fun killProcess(pid: Int, signal: Int = 15) {
        runStreamingAction("kill -$signal $pid", "kill -$signal $pid 2>&1") { loadProcesses() }
    }

    // ── CRON (real `crontab -l`) ──

    fun loadCron() {
        val srv = selectedServer ?: return
        cronJob?.cancel()
        cronJob = viewModelScope.launch {
            cronLoading = true
            cronStatus = ""
            val cmd = "crontab -l 2>/dev/null || true"
            val out = executeSshCommand(srv, cmd).trim()
            if (srv.id != selectedServerId) return@launch
            cronText = out
            cronLoading = false
        }
    }

    fun saveCron(text: String, onResult: (Boolean, String) -> Unit = { _, _ -> }) {
        val srv = selectedServer ?: return onResult(false, "No host selected.")
        cronJob?.cancel()
        cronJob = viewModelScope.launch {
            cronLoading = true
            val normalized = text.trimEnd() + "\n"
            val encoded = android.util.Base64.encodeToString(normalized.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
            val decode = "{ printf '%s' '$encoded' | base64 -d 2>/dev/null || printf '%s' '$encoded' | base64 --decode 2>/dev/null || printf '%s' '$encoded' | base64 -D; }"
            val out = executeSshCommand(srv, "$decode | crontab - 2>&1").trim()
            val ok = out.isBlank()
            if (srv.id == selectedServerId) {
                if (ok) cronText = normalized.trimEnd()
                cronStatus = if (ok) "Crontab saved." else out
                cronLoading = false
            }
            onResult(ok, if (ok) "Crontab saved." else out)
        }
    }

    fun appendCronEntry(expression: String, command: String, label: String, onResult: (Boolean, String) -> Unit = { _, _ -> }) {
        val line = listOf(expression.trim(), command.trim(), "# OmniTerm:", label.trim().ifBlank { "scheduled command" }).joinToString(" ")
        val next = (cronText.lines().filter { it.isNotBlank() } + line).joinToString("\n")
        saveCron(next, onResult)
    }

    // ── PING (device-side ICMP via the system ping binary) ──

    var pingRunning by mutableStateOf(false); private set
    var pingLines by mutableStateOf<List<String>>(emptyList()); private set
    private var pingJob: Job? = null
    private var pingProcess: Process? = null

    /**
     * Ping [host] from the phone itself ([count] tries, 0 = until stopped). Runs the platform
     * `ping` binary so results are real ICMP, streamed line by line. The process handle is kept
     * so [stopPing] can destroy it — cancellation alone can't interrupt a blocked readLine().
     */
    fun startPing(host: String, count: Int) {
        if (pingRunning) return
        val target = host.trim()
        if (target.isEmpty() || !target.all { it.isLetterOrDigit() || it in ".-:%_[]" }) {
            pingLines = listOf("Enter a valid hostname or IP address.")
            return
        }
        pingRunning = true
        pingLines = emptyList()
        pingJob = viewModelScope.launch(Dispatchers.IO) {
            try {
                val cmd = buildList {
                    add(ANDROID_PING_BINARY)
                    if (count > 0) { add("-c"); add(count.toString()) }
                    add("-W"); add("3")
                    add(target)
                }
                val process = ProcessBuilder(cmd).redirectErrorStream(true).start()
                pingProcess = process
                val reader = process.inputStream.bufferedReader()
                while (isActive) {
                    val line = reader.readLine() ?: break
                    if (line.isBlank()) continue
                    withContext(Dispatchers.Main) { pingLines = (pingLines + line).takeLast(200) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                withContext(NonCancellable + Dispatchers.Main) {
                    pingLines = pingLines + "ping failed: ${e.message}"
                }
            } finally {
                pingProcess?.destroy()
                pingProcess = null
                withContext(NonCancellable + Dispatchers.Main) { pingRunning = false }
            }
        }
    }

    fun stopPing() {
        // Destroy first: it unblocks the reader thread stuck in readLine(), letting the
        // cancelled coroutine actually finish.
        pingProcess?.destroy()
        pingJob?.cancel()
    }

    // ── Traceroute (modeled on ping above) ──
    var tracerouteRunning by mutableStateOf(false); private set
    var tracerouteLines by mutableStateOf<List<String>>(emptyList()); private set
    private var tracerouteJob: Job? = null
    private var tracerouteProcess: Process? = null

    /**
     * Trace the route to [host] from the phone, streaming each hop. Runs the platform `traceroute`
     * binary if present; many Android builds ship it (toybox), but not all. If it can't be launched
     * we surface a clear message rather than failing silently. Same process/cancel handling as
     * [startPing] — the handle lets [stopTraceroute] interrupt a blocked readLine().
     */
    fun startTraceroute(host: String) {
        if (tracerouteRunning) return
        val target = host.trim()
        if (target.isEmpty() || !target.all { it.isLetterOrDigit() || it in ".-:%_[]" }) {
            tracerouteLines = listOf("Enter a valid hostname or IP address.")
            return
        }
        tracerouteRunning = true
        tracerouteLines = emptyList()
        tracerouteJob = viewModelScope.launch(Dispatchers.IO) {
            try {
                // Prefer numeric, capped hops, then a bare invocation when flags are unsupported.
                // Every candidate is an absolute trusted system path; never search an inherited PATH.
                var process: Process? = null
                val commandsToTry = ANDROID_TRACEROUTE_BINARIES.flatMap { binary ->
                    listOf(
                        listOf(binary, "-n", "-m", "30", target),
                        listOf(binary, target),
                    )
                }
                for (cmd in commandsToTry) {
                    try {
                        process = ProcessBuilder(cmd).redirectErrorStream(true).start()
                        break
                    } catch (_: java.io.IOException) {
                        // ignore and try next
                    }
                }
                if (process == null) {
                    // No traceroute binary (the common case on Android — toybox doesn't ship one):
                    // step the TTL manually with single-shot pings instead of giving up.
                    pingSteppedTraceroute(target)
                    return@launch
                }
                tracerouteProcess = process
                val reader = process.inputStream.bufferedReader()
                while (isActive) {
                    val line = reader.readLine() ?: break
                    if (line.isBlank()) continue
                    withContext(Dispatchers.Main) { tracerouteLines = (tracerouteLines + line).takeLast(200) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: java.io.IOException) {
                withContext(NonCancellable + Dispatchers.Main) {
                    tracerouteLines = tracerouteLines + "traceroute is not available on this device."
                }
            } catch (e: Throwable) {
                withContext(NonCancellable + Dispatchers.Main) {
                    tracerouteLines = tracerouteLines + "traceroute failed: ${e.message}"
                }
            } finally {
                tracerouteProcess?.destroy()
                tracerouteProcess = null
                withContext(NonCancellable + Dispatchers.Main) { tracerouteRunning = false }
            }
        }
    }

    fun stopTraceroute() {
        tracerouteProcess?.destroy()
        tracerouteJob?.cancel()
    }

    /**
     * Rootless traceroute: one `ping -c 1 -t <ttl>` per hop. Routers that drop the probe reply with
     * "From <ip> ... Time to live exceeded", which ping prints — that IP is the hop. The destination
     * answers with a normal echo reply. Intermediate-hop RTT is approximated by process wall time
     * (ping doesn't print a time for TTL-exceeded replies); the final hop uses ping's own time.
     */
    private suspend fun pingSteppedTraceroute(target: String) {
        withContext(Dispatchers.Main) {
            tracerouteLines = listOf("ICMP trace via TTL-stepped ping (no traceroute binary on this device)")
        }
        var reached = false
        for (ttl in 1..30) {
            if (!currentCoroutineContext().isActive) return
            val startedNs = System.nanoTime()
            val output = try {
                val p = ProcessBuilder(ANDROID_PING_BINARY, "-c", "1", "-W", "2", "-t", ttl.toString(), target)
                    .redirectErrorStream(true).start()
                tracerouteProcess = p
                val text = p.inputStream.bufferedReader().readText()
                p.waitFor()
                text
            } catch (e: java.io.IOException) {
                withContext(NonCancellable + Dispatchers.Main) {
                    tracerouteLines = tracerouteLines + "ping is not available on this device — cannot trace."
                }
                return
            } finally {
                tracerouteProcess = null
            }
            if (ttl == 1 && (output.contains("unknown host", ignoreCase = true) || output.contains("Name or service not known", ignoreCase = true))) {
                withContext(NonCancellable + Dispatchers.Main) { tracerouteLines = tracerouteLines + "Cannot resolve $target." }
                return
            }
            val elapsedMs = (System.nanoTime() - startedNs) / 1e6
            val hop = parseTracerouteHop(ttl, output, elapsedMs)
            reached = hop.reachedDestination
            withContext(Dispatchers.Main) { tracerouteLines = (tracerouteLines + hop.line).takeLast(200) }
            if (reached) break
        }
        withContext(Dispatchers.Main) {
            tracerouteLines = tracerouteLines +
                if (reached) "Trace complete." else "Stopped after 30 hops without reaching $target."
        }
    }

    // ── Network shares (SMB/FTP/SFTP/NFS/WebDAV profiles + LAN discovery) ──
    fun defaultNetworkSharePort(protocol: String): Int = when (protocol.uppercase(Locale.ROOT)) {
        "SMB" -> 445
        "FTP" -> 21
        "SFTP" -> 22
        "NFS" -> 2049
        "WEBDAV" -> 443
        else -> 0
    }

    private suspend fun persistNetworkShare(share: NetworkShareEntity): NetworkShareEntity? {
        val normalizedProtocol = share.protocol.uppercase(Locale.ROOT).ifBlank { "SMB" }
        var normalized = share.copy(
            name = share.name.trim().ifBlank { "${normalizedProtocol.lowercase(Locale.ROOT)}://${share.address.trim()}" },
            protocol = normalizedProtocol,
            address = share.address.trim(),
            port = share.port.takeIf { it > 0 } ?: defaultNetworkSharePort(normalizedProtocol),
            sharePath = share.sharePath.trim().trimStart('/'),
            workgroup = share.workgroup.trim(),
            username = if (share.anonymous || share.authProfileId != null) "" else share.username.trim(),
            password = if (share.anonymous || share.authProfileId != null) "" else share.password,
            authProfileId = if (share.anonymous) null else share.authProfileId,
            notes = share.notes.trim(),
        )
        if (normalized.address.isBlank()) {
            networkShareScanStatus = "Address is required."
            return null
        }
        if (normalized.protocol != "CUSTOM" && normalized.port !in 1..65535) {
            networkShareScanStatus = "Port must be between 1 and 65535."
            return null
        }
        if (normalized.protocol == "SFTP" && normalized.anonymous) {
            networkShareScanStatus = "SFTP shares need a username or credential profile."
            return null
        }
        if (normalized.protocol == "SMB" && normalized.sharePath.isBlank()) {
            networkShareScanStatus = "SMB shares need a Share/path value such as Public or Media."
            return null
        }
        if (!normalized.anonymous && normalized.authProfileId == null && normalized.username.isBlank()) {
            networkShareScanStatus = "Username is required for ${normalized.protocol} shares that are not anonymous."
            return null
        }
        if (!normalized.anonymous && normalized.authProfileId == null && normalized.username.isNotBlank()) {
            val profileName = normalized.name.ifBlank { "${normalized.protocol} ${normalized.address}" }
            val profileId = repository.insertProfile(
                CredentialProfileEntity(
                    profileName = "Network Share - $profileName",
                    username = normalized.username,
                    authType = "password",
                    password = normalized.password,
                    groupName = "Network Shares",
                )
            ).toInt()
            normalized = normalized.copy(authProfileId = profileId, username = "", password = "")
        }
        repository.insertNetworkShare(normalized)
        networkShareScanStatus = "Saved ${normalized.name}."
        return normalized
    }

    fun saveNetworkShare(share: NetworkShareEntity) {
        viewModelScope.launch {
            try {
                persistNetworkShare(share)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                networkShareScanStatus = "Save failed: ${e.message ?: "unknown error"}"
            }
        }
    }

    fun deleteNetworkShare(share: NetworkShareEntity) {
        viewModelScope.launch {
            repository.deleteNetworkShare(share)
            repository.deleteSetting("share_bookmarks_${share.id}")
            allBookmarks.removeAll { it.shareId == share.id }
            if (browsingShare?.id == share.id) closeShareBrowser()
            networkShareScanStatus = "Deleted ${share.name}."
        }
    }

    fun testNetworkShare(share: NetworkShareEntity) {
        viewModelScope.launch(Dispatchers.IO) {
            repository.getAllNetworkShares().firstOrNull { it.id == share.id }?.let {
                repository.updateNetworkShare(it.copy(lastStatus = "checking"))
            }
            val status = updateNetworkShareAvailability(share)
            withContext(Dispatchers.Main) {
                networkShareScanStatus = "${share.name}: $status on ${share.address}:${share.port}."
            }
        }
    }

    fun refreshNetworkSharesAvailability() {
        viewModelScope.launch(Dispatchers.IO) {
            val shares = repository.getAllNetworkShares()
            if (shares.isEmpty()) {
                withContext(Dispatchers.Main) { scanNetworkShares() }
                return@launch
            }
            shares.forEach { share ->
                launch {
                    repository.getAllNetworkShares().firstOrNull { it.id == share.id }?.let {
                        repository.updateNetworkShare(it.copy(lastStatus = "checking"))
                    }
                    updateNetworkShareAvailability(share)
                }
            }
        }
    }

    private fun startNetworkShareAvailabilityProbe() {
        if (networkShareAvailabilityJob != null) return
        networkShareAvailabilityJob = viewModelScope.launch(Dispatchers.IO) {
            delay(3_000)
            while (isActive) {
                probeSavedNetworkShares(markChecking = false)
                delay(NETWORK_SHARE_PROBE_INTERVAL_MS)
            }
        }
    }

    private suspend fun probeSavedNetworkShares(markChecking: Boolean) {
        if (networkShareAvailabilityRunning || batterySaverActive) return
        networkShareAvailabilityRunning = true
        try {
            val shares = repository.getAllNetworkShares()
            if (shares.isEmpty()) return
            val semaphore = Semaphore(8)
            coroutineScope {
                shares.forEach { share ->
                    launch {
                        semaphore.withPermit {
                            if (markChecking) {
                                repository.getAllNetworkShares().firstOrNull { it.id == share.id }?.let {
                                    repository.updateNetworkShare(it.copy(lastStatus = "checking"))
                                }
                            }
                            updateNetworkShareAvailability(share)
                        }
                    }
                }
            }
        } finally {
            networkShareAvailabilityRunning = false
        }
    }

    private suspend fun updateNetworkShareAvailability(share: NetworkShareEntity): String {
        val ok = canConnect(share.address, share.port, timeoutMs = 1200)
        val now = System.currentTimeMillis()
        val status = if (ok) "online" else "unreachable"
        // Re-read before writing: the user may have edited (or deleted) this share while the probe
        // was in flight, and a blind copy(share) would resurrect stale row fields.
        val current = repository.getAllNetworkShares().firstOrNull { it.id == share.id }
        if (current != null) {
            repository.updateNetworkShare(current.copy(lastChecked = now, lastStatus = status))
        }
        return status
    }

    fun addNetworkShareFromScan(hit: NetworkShareScanHit) {
        viewModelScope.launch {
            if (hit.protocol in setOf("SMB", "SFTP")) {
                networkShareScanStatus = "${hit.protocol} needs configuration before saving."
                return@launch
            }
            try {
                val saved = persistNetworkShare(
                    NetworkShareEntity(
                        name = hit.label,
                        protocol = hit.protocol,
                        address = hit.address,
                        port = hit.port,
                        anonymous = true,
                        useHttps = hit.protocol == "WEBDAV" && (hit.port == 443 || hit.port == 8443),
                        lastChecked = System.currentTimeMillis(),
                        lastStatus = "online",
                    )
                )
                if (saved != null) {
                    networkShareScanHits.remove(hit)
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                networkShareScanStatus = "Save failed: ${e.message ?: "unknown error"}"
            }
        }
    }

    fun scanNetworkShares(cidrInput: String = networkShareScanCidr) {
        if (networkShareScanRunning) return
        val input = cidrInput.ifBlank { networkShareScanCidr }.trim()
        val enabledProtocols = networkShareScanProtocols.toSet()
        val protocolLabel = enabledProtocols.joinToString(", ")
        networkShareScanRunning = true
        networkShareScanHits.clear()
        networkShareScanStatus = if (input.isBlank()) {
            "Scanning LAN hosts, then probing $protocolLabel."
        } else {
            "Scanning share services for $protocolLabel."
        }
        viewModelScope.launch(Dispatchers.IO) {
            val ports = listOf("SMB" to 445, "FTP" to 21, "SFTP" to 22, "NFS" to 2049, "WEBDAV" to 80, "WEBDAV" to 443)
                .filter { it.first in enabledProtocols }
            val semaphore = Semaphore(64)
            val found = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
            try {
                if (input.isBlank()) withContext(Dispatchers.Main) { refreshLanScan(force = false) }
                val targets = if (input.isBlank() && hostScanResults.isNotEmpty()) {
                    withContext(Dispatchers.Main) { hostScanResults.filter { it.isOnline }.map { it.ip } }
                } else {
                    expandScanTargets(input)
                }
                if (targets.isEmpty()) {
                    withContext(Dispatchers.Main) {
                        networkShareScanStatus = "Enter a /24 subnet like 192.168.1.0/24, or leave it blank on Wi-Fi/LAN."
                    }
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    networkShareScanStatus = "Scanning ${targets.size} host(s) for $protocolLabel."
                }
                coroutineScope {
                    targets.forEach { host ->
                        ports.forEach { (protocol, port) ->
                            launch {
                                semaphore.withPermit {
                                    if (canConnect(host, port, timeoutMs = 700)) {
                                        val key = "$host:$port"
                                        if (found.add(key)) {
                                            if (protocol == "SMB") {
                                                try {
                                                    val shares = enumerateSmbShares(host, port)
                                                    if (shares.isNotEmpty()) {
                                                        shares.forEach { shareName ->
                                                            withContext(Dispatchers.Main) {
                                                                networkShareScanHits.add(
                                                                    NetworkShareScanHit(
                                                                        address = host,
                                                                        protocol = protocol,
                                                                        port = port,
                                                                        label = "SMB Share: $shareName on $host",
                                                                        sharePath = shareName
                                                                    )
                                                                )
                                                            }
                                                        }
                                                    } else {
                                                        withContext(Dispatchers.Main) {
                                                            networkShareScanHits.add(NetworkShareScanHit(host, protocol, port))
                                                        }
                                                    }
                                                } catch(e: Exception) {
                                                    withContext(Dispatchers.Main) {
                                                        networkShareScanHits.add(NetworkShareScanHit(host, protocol, port))
                                                    }
                                                }
                                            } else {
                                                withContext(Dispatchers.Main) {
                                                    networkShareScanHits.add(NetworkShareScanHit(host, protocol, port))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                withContext(Dispatchers.Main) {
                    networkShareScanStatus = "Scan complete: ${networkShareScanHits.size} candidate share service(s)."
                }
            } finally {
                withContext(NonCancellable + Dispatchers.Main) { networkShareScanRunning = false }
            }
        }
    }

    /**
     * Best-effort anonymous SRVSVC share enumeration for scan hits. Short timeouts (smbj's
     * defaults include an infinite socket read) so one stalled host can't wedge a scan worker;
     * any failure — guest login disabled, RPC blocked — just means the caller falls back to a
     * plain host hit. Hidden/admin shares (trailing "$") are skipped.
     */
    private suspend fun enumerateSmbShares(host: String, port: Int): List<String> = withContext(Dispatchers.IO) {
        val shares = mutableListOf<String>()
        try {
            val config = com.hierynomus.smbj.SmbConfig.builder()
                .withTimeout(5, java.util.concurrent.TimeUnit.SECONDS)
                .withSoTimeout(5, java.util.concurrent.TimeUnit.SECONDS)
                .build()
            val client = com.hierynomus.smbj.SMBClient(config)
            client.connect(host, port.takeIf { it > 0 } ?: 445).use { connection ->
                connection.authenticate(com.hierynomus.smbj.auth.AuthenticationContext.anonymous()).use { session ->
                    val transport = com.rapid7.client.dcerpc.transport.SMBTransportFactories.SRVSVC.getTransport(session, config)
                    val srvsvc = com.rapid7.client.dcerpc.mssrvs.ServerService(transport)
                    val shareInfos = srvsvc.shares0
                    for (info in shareInfos) {
                        val shareName = info.netName
                        if (shareName != null && !shareName.endsWith("$")) {
                            shares.add(shareName)
                        }
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Ignore error
        } catch (e: LinkageError) {
            // smbj-rpc is built against smbj 0.11.x while the app ships 0.13.x; if the ABI ever
            // drifts this surfaces as NoSuchMethodError — degrade to a plain host hit, not a crash.
        }
        shares
    }

    private fun canConnect(host: String, port: Int, timeoutMs: Int): Boolean =
        runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), timeoutMs)
                true
            }
        }.getOrDefault(false)

    private fun expandScanTargets(input: String): List<String> {
        val trimmed = input.trim()
        if (trimmed.isBlank()) return localIpv4Prefixes().firstOrNull()?.let { prefix ->
            (1..254).map { "$prefix.$it" }
        } ?: emptyList()
        if (!trimmed.contains("/")) return listOf(trimmed)
        val base = trimmed.substringBefore("/")
        val cidr = trimmed.substringAfter("/").toIntOrNull() ?: return emptyList()
        val octets = base.split(".").mapNotNull { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
        if (octets.size != 4 || cidr != 24) return emptyList()
        val prefix = octets.take(3).joinToString(".")
        return (1..254).map { "$prefix.$it" }
    }

    private fun localIpv4Prefixes(): List<String> =
        runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .mapNotNull { addr ->
                    val host = addr.hostAddress ?: return@mapNotNull null
                    val parts = host.split(".")
                    if (parts.size == 4 && parts.none { it.isBlank() } && !host.startsWith("127.")) {
                        parts.take(3).joinToString(".")
                    } else null
                }
                .distinct()
        }.getOrDefault(emptyList())

    // ── Network share browser (real SMB/FTP/SFTP/WebDAV file operations) ──

    /** Resolve the share's login: linked credential profile first, then inline creds. */
    private suspend fun shareCredentials(share: NetworkShareEntity): Pair<String, String> {
        if (share.anonymous) return "" to ""
        share.authProfileId?.let { id ->
            repository.getAllProfiles().firstOrNull { it.id == id }?.let { p ->
                return p.username to (p.password ?: "")
            }
        }
        return share.username to share.password
    }

    /** Build a protocol client for [share]. SFTP shares honor key-based credential profiles. */
    private suspend fun shareFsClient(share: NetworkShareEntity): RemoteFsClient {
        if (share.protocol.uppercase(Locale.ROOT) == "SFTP" && !share.anonymous && share.authProfileId != null) {
            val profile = repository.getAllProfiles().firstOrNull { it.id == share.authProfileId }
            if (profile != null && profile.authType == "key") {
                val pem = repository.getAllKeys().find { it.alias == profile.keyAlias }?.privateKey
                    ?: throw java.io.IOException("Key \"${profile.keyAlias}\" for profile \"${profile.profileName}\" no longer exists.")
                return JschSftp(SshCredentials(share.address, share.port, profile.username, privateKeyPem = pem))
            }
        }
        val (user, pass) = shareCredentials(share)
        return ShareClients.forShare(share, user, pass)
    }

    /**
     * The cached browsing connection, dialing it on first use. [shareClientDialLock] serializes
     * the check-evict-dial-cache sequence: two cold callers (e.g. a directory load racing an
     * upload right after the browser opens) would otherwise both miss the cache, both dial, and
     * the loser's connection would be overwritten into a leak.
     */
    private suspend fun browserClient(share: NetworkShareEntity): RemoteFsClient = shareClientDialLock.withLock {
        shareClient?.takeIf { shareClientShareId == share.id }?.let { return@withLock it }

        val stale = shareClient
        shareClient = null
        shareClientShareId = null
        // NonCancellable: these run when the browser was switched or the job is being torn down —
        // exactly when the calling job may already be cancelled, and a cancelled withContext would
        // skip the close and leak the connection.
        withContext(NonCancellable + Dispatchers.IO) { runCatching { stale?.close() } }

        val client = shareFsClient(share)
        if (browsingShare?.id != share.id) {
            withContext(NonCancellable + Dispatchers.IO) { runCatching { client.close() } }
            throw CancellationException("Share browser switched")
        }
        shareClient = client
        shareClientShareId = share.id
        client
    }

    private fun closeShareBrowserClient() {
        val client = shareClient ?: return
        shareClient = null
        shareClientShareId = null
        // Teardown can block on socket close, so it must leave the main thread — and it can't use
        // viewModelScope because that is already cancelled when onCleared calls this.
        @OptIn(DelicateCoroutinesApi::class)
        GlobalScope.launch(Dispatchers.IO) { runCatching { client.close() } }
    }

    fun openShareBrowser(share: NetworkShareEntity, startPath: String? = null) {
        if (browsingShare?.id == share.id) {
            if (startPath != null) loadShareDir(startPath)
            return
        }
        shareJob?.cancel()
        closeShareBrowserClient()
        browsingShare = share
        sharePath = ""
        shareEntries = emptyList()
        shareError = null
        shareStatus = null
        loadShareBookmarks(share.id)
        loadShareDir(startPath)
    }

    fun closeShareBrowser() {
        shareJob?.cancel()
        closeShareBrowserClient()
        browsingShare = null
        sharePath = ""
        shareEntries = emptyList()
        shareError = null
        shareStatus = null
        shareBookmarks.clear()
        shareSelected.clear()
        shareSearchClear()
        edittingShareFile = null
    }

    fun loadShareDir(path: String? = null, clearError: Boolean = true) {
        val share = browsingShare ?: return
        shareJob?.cancel()
        shareJob = viewModelScope.launch {
            shareLoading = true
            if (clearError) shareError = null
            try {
                val client = browserClient(share)
                val target = (path ?: sharePath.ifBlank { ShareClients.startPath(share, client) }).ifBlank { "/" }
                val listing = client.list(target)
                if (browsingShare?.id != share.id) return@launch  // browser switched; discard.
                shareEntries = sortEntriesBy(listing, shareSortOption)
                sharePath = target
                // A directory change ends any active selection — the names no longer apply here.
                shareSelected.clear()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (browsingShare?.id == share.id) shareError = e.message ?: "Share error"
            } finally {
                if (shareJob == coroutineContext[Job]) shareLoading = false
            }
        }
    }

    fun shareNavigateInto(name: String) = loadShareDir(joinPath(sharePath, name))

    fun shareNavigateUp() {
        val parent = sharePath.trimEnd('/').substringBeforeLast('/', "")
        loadShareDir(parent.ifBlank { "/" })
    }

    /** Run one mutation on the browsed share, then refresh without clobbering the banner. */
    private fun shareMutate(successStatus: String, op: suspend (RemoteFsClient) -> Unit) {
        val share = browsingShare ?: return
        if (shareOpRunning) return
        viewModelScope.launch {
            shareOpRunning = true
            try {
                op(browserClient(share))
                if (browsingShare?.id != share.id) return@launch
                shareError = null
                shareStatus = successStatus
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (browsingShare?.id == share.id) shareError = e.message ?: "Share operation failed"
            } finally {
                shareOpRunning = false
            }
            if (browsingShare?.id == share.id) loadShareDir(sharePath, clearError = false)
        }
    }

    /** True for protocols the in-app browser can actually open (NFS/CUSTOM are save-only). */
    fun isShareBrowsable(share: NetworkShareEntity): Boolean =
        share.protocol.uppercase(Locale.ROOT) in setOf("SMB", "FTP", "SFTP", "WEBDAV")

    fun shareMkdir(name: String) {
        val trimmed = name.trim()
        if (trimmed.isBlank()) return
        shareMutate("Created folder \"$trimmed\"") { it.mkdir(joinPath(sharePath, trimmed)) }
    }

    fun shareRename(file: SftpFile, newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isBlank() || trimmed == file.name) return
        shareMutate("Renamed to \"$trimmed\"") {
            it.rename(joinPath(sharePath, file.name), joinPath(sharePath, trimmed))
        }
    }

    fun shareDelete(file: SftpFile) {
        shareMutate("Deleted \"${file.name}\"") { it.delete(joinPath(sharePath, file.name), file.isDirectory) }
    }

    /** Download a file from the browsed share into a SAF-picked destination. */
    fun shareDownload(remoteName: String, uri: android.net.Uri, context: android.content.Context) {
        val share = browsingShare ?: return
        val remotePath = joinPath(sharePath, remoteName)
        viewModelScope.launch {
            shareTransferRunning = true
            try {
                shareDownloadInner(share, remoteName, remotePath, uri, context)
            } finally {
                shareTransferRunning = false
            }
        }
    }

    /** Returns true when the download completed; failures are logged to the transfer row. */
    private suspend fun shareDownloadInner(
        share: NetworkShareEntity,
        remoteName: String,
        remotePath: String,
        uri: android.net.Uri,
        context: android.content.Context,
    ): Boolean {
        val transferId = addTransfer(-share.id, shareEndpointLabel(share), "Download", remoteName, remotePath)
        // A dedicated connection, not the shared browsing one: the download must keep running
        // (and the browser must stay responsive) when the user navigates to another share or
        // closes the browser mid-transfer — closing the browsing client used to kill it.
        var client: RemoteFsClient? = null
        try {
            client = shareFsClient(share)
            val bytes = withContext(Dispatchers.IO) {
                context.contentResolver.openOutputStream(uri).use { output ->
                    output ?: throw java.io.IOException("Could not open destination.")
                    client.downloadTo(remotePath, output, transferProgress(transferId))
                }
            }
            finishSftpTransfer(transferId, SftpTransferStatus.Success, bytes, bytes, "Downloaded $bytes bytes")
            if (browsingShare?.id == share.id) shareStatus = "Downloaded \"$remoteName\""
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (browsingShare?.id == share.id) shareError = e.message ?: "Download failed"
            finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = e.message ?: "Download failed")
            return false
        } finally {
            withContext(NonCancellable + Dispatchers.IO) { runCatching { client?.close() } }
        }
    }

    /** Upload device files (SAF picker) into the browsed share's current directory. */
    fun shareUploadMany(uris: List<android.net.Uri>, context: android.content.Context) {
        val share = browsingShare ?: return
        val picked = uris.distinct()
        if (picked.isEmpty()) return
        val destDir = sharePath.ifBlank { "/" }
        viewModelScope.launch {
            shareTransferRunning = true
            var ok = 0
            var firstErr: String? = null
            // One dedicated connection for the whole batch (not the shared browsing client), so
            // uploads keep running when the user browses elsewhere or closes the share browser.
            var client: RemoteFsClient? = null
            val batchId = beginTransferBatch(picked.size)
            try {
                client = shareFsClient(share)
                for ((index, uri) in picked.withIndex()) {
                    val name = queryDisplayName(context, uri)?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                        ?: "upload_${System.currentTimeMillis()}_${index + 1}"
                    val remotePath = joinPath(destDir, name)
                    val transferId = addTransfer(-share.id, shareEndpointLabel(share), "Upload", name, remotePath, sourceUri = uri.toString())
                    try {
                        val totalBytes = queryOpenableSize(context, uri)
                        withContext(Dispatchers.IO) {
                            context.contentResolver.openInputStream(uri).use { input ->
                                input ?: throw java.io.IOException("Could not read the selected file from this device.")
                                client.uploadStream(remotePath, input, totalBytes, transferProgress(transferId))
                            }
                        }
                        ok++
                        finishSftpTransfer(transferId, SftpTransferStatus.Success, totalBytes, totalBytes, "Uploaded")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        val msg = e.message ?: "upload failed"
                        if (firstErr == null) firstErr = "$name: $msg"
                        finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = msg)
                    }
                    advanceTransferBatch(batchId)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Reached only when the share connection itself couldn't be built.
                if (firstErr == null) firstErr = e.message ?: "share connection failed"
            } finally {
                shareTransferRunning = false
                endTransferBatch(batchId)
                withContext(NonCancellable + Dispatchers.IO) { runCatching { client?.close() } }
            }
            if (browsingShare?.id == share.id) {
                shareError = firstErr?.let { "Upload failed: $it" }
                shareStatus = if (firstErr == null) "Uploaded $ok file(s)" else "Uploaded $ok of ${picked.size} file(s) — see error"
                loadShareDir(destDir, clearError = false)
            }
        }
    }

    private fun shareEndpointLabel(share: NetworkShareEntity): String = "${share.name} (${share.protocol})"

    // ── Share browser: sort (parity with the SFTP Files tab) ──
    var shareSortOption by mutableStateOf(SftpSortOption.NameAsc); private set
    fun chooseShareSortOption(option: SftpSortOption) {
        shareSortOption = option
        shareEntries = sortEntriesBy(shareEntries, option)
        viewModelScope.launch { repository.insertSetting("share_sort", option.name) }
    }

    // ── Share browser: multi-select + batch actions ──
    /** Names within [sharePath] selected for a bulk action; non-empty ⇒ selection mode. */
    val shareSelected = mutableStateListOf<String>()
    val shareSelectionMode: Boolean get() = shareSelected.isNotEmpty()
    fun shareToggleSelect(name: String) {
        if (name in shareSelected) shareSelected.remove(name) else shareSelected.add(name)
    }
    fun shareSelectAll() {
        shareSelected.clear()
        shareSelected.addAll(shareEntries.map { it.name })
    }
    fun shareClearSelection() = shareSelected.clear()

    /** Stage every selected entry on the cross-endpoint clipboard (copy or cut). */
    fun shareClipSelection(move: Boolean) {
        val share = browsingShare ?: return
        if (shareSelected.isEmpty()) return
        val byName = shareEntries.associateBy { it.name }
        val refs = shareSelected.mapNotNull { name ->
            byName[name]?.let { f ->
                RemoteFileRef(
                    shareId = share.id,
                    sourceLabel = shareEndpointLabel(share),
                    dir = sharePath.ifBlank { "/" },
                    name = f.name,
                    isDirectory = f.isDirectory,
                    size = f.size,
                )
            }
        }
        stageCrossRefs(refs, move)
        sftpClipboard = emptyList()
        sftpClipboardIsMove = false
        val verb = if (move) "Cut" else "Copied"
        shareStatus = "$verb ${refs.size} item(s) — paste in a folder here, another share, or the SFTP tab"
        shareSelected.clear()
    }

    /** Delete every selected entry, sequentially, refreshing once at the end. */
    fun shareDeleteSelected() {
        val share = browsingShare ?: return
        if (shareSelected.isEmpty() || shareOpRunning) return
        val byName = shareEntries.associateBy { it.name }
        val targets = shareSelected.mapNotNull { byName[it] }
        viewModelScope.launch {
            shareOpRunning = true
            var ok = 0
            var firstErr: String? = null
            try {
                val client = browserClient(share)
                for (f in targets) {
                    try {
                        client.delete(joinPath(sharePath, f.name), f.isDirectory)
                        ok++
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        if (firstErr == null) firstErr = "${f.name}: ${e.message}"
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (firstErr == null) firstErr = e.message
            } finally {
                shareOpRunning = false
            }
            if (browsingShare?.id == share.id) {
                shareSelected.clear()
                shareError = firstErr?.let { "Delete failed: $it" }
                shareStatus = if (firstErr == null) "Deleted $ok item(s)" else "Deleted $ok of ${targets.size} — see error"
                loadShareDir(sharePath, clearError = false)
            }
        }
    }

    /** Download every selected file into a SAF-picked destination folder (folders are skipped). */
    fun shareDownloadSelectedToFolder(names: List<String>, treeUri: android.net.Uri, context: android.content.Context) {
        val share = browsingShare ?: return
        val byName = shareEntries.associateBy { it.name }
        val files = names.mapNotNull { byName[it] }.filter { !it.isDirectory }
        if (files.isEmpty()) return
        viewModelScope.launch {
            shareTransferRunning = true
            var ok = 0
            var firstErr: String? = null
            val batchId = beginTransferBatch(files.size)
            try {
                for (f in files) {
                    try {
                        val destUri = createDocumentInTree(context, treeUri, f.name)
                        // Inner logs its own failures to the transfer row; only count real successes.
                        if (shareDownloadInner(share, f.name, joinPath(sharePath, f.name), destUri, context)) {
                            ok++
                        } else if (firstErr == null) {
                            firstErr = "${f.name}: see transfer log"
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        if (firstErr == null) firstErr = "${f.name}: ${e.message}"
                    }
                    advanceTransferBatch(batchId)
                }
            } finally {
                shareTransferRunning = false
                endTransferBatch(batchId)
            }
            if (browsingShare?.id == share.id) {
                shareSelected.clear()
                shareError = firstErr?.let { "Download failed: $it" }
                shareStatus = if (firstErr == null) "Downloaded $ok file(s)" else "Downloaded $ok of ${files.size} — see error"
            }
        }
    }

    // ── Share browser: live filter (non-recursive) + recursive search ──
    var shareSearchActive by mutableStateOf(false)
    var shareSearchQuery by mutableStateOf("")
    var shareSearchWildcard by mutableStateOf(false)
    var shareSearchRecursive by mutableStateOf(false); private set
    var shareSearchRunning by mutableStateOf(false); private set
    var shareSearchResults by mutableStateOf<List<SftpSearchHit>?>(null); private set
    var shareSearchTruncated by mutableStateOf(false); private set
    private var shareSearchJob: Job? = null

    fun shareSearchToggleRecursive() {
        shareSearchRecursive = !shareSearchRecursive
        shareSearchResults = null
        shareSearchTruncated = false
    }

    fun shareSearchClear() {
        shareSearchActive = false
        shareSearchQuery = ""
        shareSearchResults = null
        shareSearchTruncated = false
        shareSearchJob?.cancel()
    }

    /**
     * Recursive share search: walk the tree from the current folder via list() (RemoteFsClient has
     * no server-side find), matching names by substring or glob. Bounded to keep a huge tree from
     * running away — capped result count and directory-visit budget.
     */
    fun runShareSearch() {
        val share = browsingShare ?: return
        val query = shareSearchQuery.trim()
        if (query.isBlank()) return
        shareSearchJob?.cancel()
        shareSearchTruncated = false
        val matcher: (String) -> Boolean =
            if (shareSearchWildcard) { val rx = globToRegexVm(query); { n -> rx.matches(n) } }
            else { { n -> n.contains(query, ignoreCase = true) } }
        shareSearchJob = viewModelScope.launch {
            shareSearchRunning = true
            shareSearchResults = null
            val hits = mutableListOf<SftpSearchHit>()
            val maxHits = 500
            var dirBudget = 4000
            try {
                val client = browserClient(share)
                val queue = ArrayDeque<String>()
                queue.add(sharePath.ifBlank { "/" })
                while (queue.isNotEmpty() && hits.size < maxHits && dirBudget > 0) {
                    val dir = queue.removeFirst()
                    dirBudget--
                    val listing = try { client.list(dir) } catch (_: Exception) { continue }
                    if (browsingShare?.id != share.id) return@launch
                    for (f in listing) {
                        val full = joinPath(dir, f.name)
                        if (matcher(f.name)) {
                            hits.add(SftpSearchHit(full, f.isDirectory))
                            if (hits.size >= maxHits) { shareSearchTruncated = true; break }
                        }
                        if (f.isDirectory) queue.add(full)
                    }
                }
                if (queue.isNotEmpty() && hits.size >= maxHits) shareSearchTruncated = true
                shareSearchResults = hits.sortedBy { it.path.lowercase(Locale.ROOT) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (browsingShare?.id == share.id) shareError = e.message ?: "Search failed"
                shareSearchResults = emptyList()
            } finally {
                shareSearchRunning = false
            }
        }
    }

    /** Glob → Regex for share wildcard search (mirrors the SFTP tab's globToRegex). */
    private fun globToRegexVm(glob: String): Regex {
        val sb = StringBuilder("(?i)")
        for (c in glob) when (c) {
            '*' -> sb.append(".*")
            '?' -> sb.append('.')
            '.', '(', ')', '+', '|', '^', '$', '@', '%', '{', '}', '[', ']', '\\' -> sb.append('\\').append(c)
            else -> sb.append(c)
        }
        return Regex(sb.toString())
    }

    // ── Share browser: in-app text file editing (parity with openSftpFileForEdit) ──
    var edittingShareFile by mutableStateOf<SftpFile?>(null)
    var shareSaving by mutableStateOf(false); private set
    private val shareEditMaxBytes = 5L * 1024 * 1024   // guard against opening a huge binary as text

    fun openShareFileForEdit(file: SftpFile) {
        val share = browsingShare ?: return
        if (file.isDirectory) return
        if (file.size > shareEditMaxBytes) {
            shareError = "File is too large to edit in-app (${formatBytes(file.size)})."
            return
        }
        val remotePath = joinPath(sharePath, file.name)
        viewModelScope.launch {
            shareError = null
            try {
                val bytes = withContext(Dispatchers.IO) {
                    val out = java.io.ByteArrayOutputStream()
                    browserClient(share).downloadTo(remotePath, out)
                    out.toByteArray()
                }
                if (browsingShare?.id != share.id) return@launch
                edittingShareFile = file.copy(content = String(bytes, Charsets.UTF_8))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                shareError = e.message ?: "Could not open file for editing"
            }
        }
    }

    /** Write edited text back to the share, then refresh. [onSaved] runs on verified success. */
    fun shareSaveText(file: SftpFile, text: String, onSaved: () -> Unit) {
        val share = browsingShare ?: return
        val remotePath = joinPath(sharePath, file.name)
        viewModelScope.launch {
            shareSaving = true
            shareError = null
            try {
                val bytes = text.toByteArray(Charsets.UTF_8)
                withContext(Dispatchers.IO) {
                    browserClient(share).uploadStream(
                        remotePath,
                        java.io.ByteArrayInputStream(bytes),
                        bytes.size.toLong(),
                    )
                }
                if (browsingShare?.id != share.id) return@launch
                shareStatus = "Saved ${file.name}"
                onSaved()
                loadShareDir(sharePath, clearError = false)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                shareError = "Save failed: ${e.message}"
            } finally {
                shareSaving = false
            }
        }
    }

    // ── Cross-endpoint copy/paste ──

    /** Stage one browsed-share entry on the cross-endpoint clipboard (appends while staging). */
    fun shareClipFile(file: SftpFile, move: Boolean) {
        val share = browsingShare ?: return
        val ref = RemoteFileRef(
            shareId = share.id,
            sourceLabel = shareEndpointLabel(share),
            dir = sharePath.ifBlank { "/" },
            name = file.name,
            isDirectory = file.isDirectory,
            size = file.size,
        )
        stageCrossRefs(listOf(ref), move)
        // A share staging replaces any same-server SFTP staging (the two would be ambiguous).
        sftpClipboard = emptyList()
        sftpClipboardIsMove = false
        shareStatus = "${if (move) "Cut" else "Copied"} \"${file.name}\" — paste in a folder here, another share, or the SFTP tab"
    }

    private fun stageCrossRefs(refs: List<RemoteFileRef>, move: Boolean) {
        crossClipboard = if (crossClipboardIsMove != move) refs else {
            (crossClipboard + refs).distinctBy { "${it.serverId}|${it.shareId}|${it.dir}|${it.name}" }
        }
        crossClipboardIsMove = move
    }

    fun clearCrossClipboard() {
        crossClipboard = emptyList()
        crossClipboardIsMove = false
    }

    /** True when the staged SFTP clipboard can be pasted server-side on the selected host. */
    val sftpClipboardIsLocal: Boolean
        get() = sftpClipboard.isNotEmpty() && sftpClipboardServerId == selectedServerId

    /** Paste bar entry point for the SFTP Files tab: server-side when local, streamed otherwise. */
    fun pasteIntoSftp() {
        val srv = selectedServer ?: return
        if (sftpClipboardIsLocal) {
            sftpPaste()
            return
        }
        pasteCrossTo(destServer = srv, destShare = null, destDir = sftpPath.ifBlank { "/" })
    }

    /** Paste bar entry point for the share browser. */
    fun pasteIntoShare() {
        val share = browsingShare ?: return
        pasteCrossTo(destServer = null, destShare = share, destDir = sharePath.ifBlank { "/" })
    }

    /**
     * Copy (or move) every staged clipboard file into [destDir] on the destination endpoint,
     * streaming each file through the device. Folders are copied recursively only when the user
     * has opted in ([crossPasteRecurseFolders]); otherwise they're skipped and reported. A move
     * within the same share collapses to a rename (files and folders alike).
     */
    private fun pasteCrossTo(destServer: ServerEntity?, destShare: NetworkShareEntity?, destDir: String) {
        if (crossPasteRunning) return
        val refs = crossClipboard
        if (refs.isEmpty()) return
        val isMove = crossClipboardIsMove
        val destLabel = destServer?.name ?: destShare?.let(::shareEndpointLabel).orEmpty()
        viewModelScope.launch {
            crossPasteRunning = true
            crossPasteProgress = null
            var copiedFiles = 0
            val sourceClients = mutableMapOf<String, RemoteFsClient>()
            var destClient: RemoteFsClient? = null
            var ok = 0
            var skippedDirs = 0
            var firstErr: String? = null
            val batchId = beginTransferBatch(refs.size)
            try {
                // Every client here is owned by this paste — deliberately NOT the shared browsing
                // connection, so the transfer survives the user switching shares or closing the
                // browser mid-paste (closing the browsing client used to abort it).
                destClient = when {
                    destServer != null -> sftpClientFor(destServer)
                    destShare != null -> shareFsClient(destShare)
                    else -> return@launch
                }
                val recurse = crossPasteRecurseFolders
                for (ref in refs) {
                    // finally-based advance so `continue` paths (self-paste, skipped folder) and
                    // failures all still count the item as processed for the "X of N" banner.
                    try {
                    val srcPath = joinPath(ref.dir, ref.name)
                    val destPath = joinPath(destDir, ref.name)
                    if (srcPath == destPath && ((destShare != null && ref.shareId == destShare.id) || (destServer != null && ref.serverId == destServer.id))) {
                        continue  // pasted onto itself; nothing to do.
                    }
                    // A move within the same share (file or folder) is just a rename — no data travels.
                    if (isMove && destShare != null && ref.shareId == destShare.id) {
                        try {
                            destClient.rename(srcPath, destPath)
                            ok++
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            if (firstErr == null) firstErr = "${ref.name}: ${e.message ?: "move failed"}"
                        }
                        continue
                    }
                    val sourceKey = "${ref.serverId}|${ref.shareId}"
                    val src = sourceClients.getOrPut(sourceKey) { clientForRef(ref) }

                    if (ref.isDirectory) {
                        if (!recurse) { skippedDirs++; continue }
                        try {
                            val filesCopied = copyTreeBetween(src, srcPath, destClient, destPath, ref.name, destLabel, isMove)
                            if (isMove) deleteTree(src, srcPath)
                            ok++
                            copiedFiles += filesCopied
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            if (firstErr == null) firstErr = "${ref.name}: ${e.message ?: "folder copy failed"}"
                        }
                        continue
                    }

                    crossPasteProgress = ref.name
                    val transferId = addTransfer(
                        endpointId = ref.shareId?.let { -it } ?: ref.serverId ?: 0,
                        endpointName = ref.sourceLabel,
                        direction = if (isMove) "Move" else "Copy",
                        name = ref.name,
                        remotePath = "$destLabel:$destPath",
                    )
                    try {
                        val copied = streamCopyBetween(src, srcPath, destClient, destPath, ref.size, transferId)
                        if (isMove) src.delete(srcPath, false)
                        ok++
                        copiedFiles++
                        finishSftpTransfer(transferId, SftpTransferStatus.Success, copied, copied, "${if (isMove) "Moved" else "Copied"} $copied bytes to $destLabel")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        val msg = e.message ?: "copy failed"
                        if (firstErr == null) firstErr = "${ref.name}: $msg"
                        finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = msg)
                    }
                    } finally {
                        advanceTransferBatch(batchId)
                    }
                }
                val summary = buildString {
                    append(if (isMove) "Moved" else "Copied")
                    append(" $ok of ${refs.size} item(s) to $destLabel")
                    if (recurse && copiedFiles > 0) append(" ($copiedFiles file(s) total)")
                    if (skippedDirs > 0) append(" — $skippedDirs folder(s) skipped (enable \"Include folders\" to copy them)")
                }
                if (destShare != null) {
                    shareError = firstErr
                    shareStatus = summary
                } else {
                    sftpError = firstErr
                    sftpStatus = summary
                }
                // A fully successful paste consumes the clipboard — for moves (the sources are
                // gone) and for copies (pasting the same thing twice is almost never intended;
                // re-copying is one tap). Partial failures keep it staged for a retry.
                if (firstErr == null) {
                    clearCrossClipboard()
                    sftpClearClipboard()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = "Paste failed: ${e.message}"
                if (destShare != null) shareError = msg else sftpError = msg
            } finally {
                crossPasteRunning = false
                crossPasteProgress = null
                endTransferBatch(batchId)
                withContext(NonCancellable + Dispatchers.IO) {
                    sourceClients.values.forEach { runCatching { it.close() } }
                    runCatching { destClient?.close() }
                }
            }
            // Refresh whichever destination view the user is (still) looking at.
            if (destShare != null && browsingShare?.id == destShare.id) loadShareDir(destDir, clearError = false)
            if (destServer != null) refreshSftpIfStillViewing(destServer.id, destDir)
            // After a move, the source listing changed too — refresh it if it's on screen.
            if (isMove) {
                val srcShareId = refs.firstNotNullOfOrNull { it.shareId }
                if (srcShareId != null && srcShareId != destShare?.id && browsingShare?.id == srcShareId) {
                    loadShareDir(sharePath, clearError = false)
                }
                val srcServerId = refs.firstNotNullOfOrNull { it.serverId }
                if (srcServerId != null && srcServerId != destServer?.id) {
                    refreshSftpIfStillViewing(srcServerId, refs.first { it.serverId == srcServerId }.dir)
                }
            }
        }
    }

    /** Open a one-off client for the clipboard entry's source endpoint. */
    private suspend fun clientForRef(ref: RemoteFileRef): RemoteFsClient = when {
        ref.serverId != null -> {
            val srv = repository.getAllServers().firstOrNull { it.id == ref.serverId }
                ?: throw java.io.IOException("The source server no longer exists.")
            sftpClientFor(srv)
        }
        ref.shareId != null -> {
            val share = repository.getAllNetworkShares().firstOrNull { it.id == ref.shareId }
                ?: throw java.io.IOException("The source share no longer exists.")
            shareFsClient(share)
        }
        else -> throw java.io.IOException("Invalid clipboard entry.")
    }

    /**
     * Copy one file between two endpoints by piping the download straight into the upload — no
     * temp file, no full-file buffering — so a copy is bounded only by bandwidth, never by device
     * storage or memory (multi-GB files work). The two legs run as concurrent coroutines joined by
     * a 1 MiB pipe; [expectedSize] (from the source listing) sizes the progress bar and, for
     * protocols that want a Content-Length, the upload.
     *
     * A mid-stream source failure closes the pipe, which the uploader sees as EOF — so the byte
     * count is verified afterwards and a short copy fails loudly instead of leaving a silently
     * truncated file at the destination marked as success.
     */
    private suspend fun streamCopyBetween(
        src: RemoteFsClient,
        srcPath: String,
        dest: RemoteFsClient,
        destPath: String,
        expectedSize: Long,
        transferId: String,
    ): Long = withContext(Dispatchers.IO) {
        val pipeIn = java.io.PipedInputStream(1 shl 20)
        val pipeOut = java.io.PipedOutputStream(pipeIn)
        var downloaded = 0L
        try {
            coroutineScope {
                val downloader = launch {
                    try {
                        downloaded = src.downloadTo(srcPath, pipeOut) { done, total ->
                            if (transferId in cancelledTransferIds) throw TransferCancelledException()
                            updateSftpTransferProgress(transferId, done, if (total > 0) total else expectedSize)
                        }
                    } finally {
                        // Unblocks the uploader's read; on failure it sees EOF and the size check
                        // below turns that into an error.
                        runCatching { pipeOut.close() }
                    }
                }
                try {
                    dest.uploadStream(destPath, pipeIn, expectedSize)
                } finally {
                    // If the upload died first, unblock a writer stuck on a full pipe.
                    runCatching { pipeIn.close() }
                }
                downloader.join()
            }
        } finally {
            runCatching { pipeIn.close() }
        }
        if (expectedSize > 0 && downloaded != expectedSize) {
            throw java.io.IOException("Source stream ended early: got $downloaded of $expectedSize bytes.")
        }
        downloaded
    }

    /**
     * Recursively copy a directory tree between two endpoints. Creates [destPath], then walks
     * [srcPath] breadth-first, streaming each file with [streamCopyBetween] and recursing into
     * subfolders. Each file is one row in the transfer log; [crossPasteProgress] shows the
     * running per-folder position. Returns the number of files copied. A symlink loop is bounded
     * by [maxDepth] rather than followed forever.
     */
    private suspend fun copyTreeBetween(
        src: RemoteFsClient,
        srcPath: String,
        dest: RemoteFsClient,
        destPath: String,
        rootName: String,
        destLabel: String,
        isMove: Boolean,
        depth: Int = 0,
        maxDepth: Int = 40,
    ): Int {
        if (depth > maxDepth) throw java.io.IOException("Folder nesting too deep (>$maxDepth) — aborting to avoid a symlink loop.")
        // mkdir is idempotent enough here: a pre-existing dir on the destination is fine (merge).
        runCatching { dest.mkdir(destPath) }
        var files = 0
        val entries = src.list(srcPath)
        for (entry in entries) {
            val childSrc = joinPath(srcPath, entry.name)
            val childDest = joinPath(destPath, entry.name)
            if (entry.isDirectory) {
                files += copyTreeBetween(src, childSrc, dest, childDest, "$rootName/${entry.name}", destLabel, isMove, depth + 1, maxDepth)
            } else {
                crossPasteProgress = "$rootName/${entry.name}"
                val transferId = addTransfer(0, destLabel, if (isMove) "Move" else "Copy", "$rootName/${entry.name}", "$destLabel:$childDest")
                try {
                    val copied = streamCopyBetween(src, childSrc, dest, childDest, entry.size, transferId)
                    finishSftpTransfer(transferId, SftpTransferStatus.Success, copied, copied, "Copied $copied bytes")
                    files++
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = e.message ?: "copy failed")
                    throw e  // fail the whole folder so a move never deletes a partially-copied tree.
                }
            }
        }
        return files
    }

    /** Depth-first delete of a tree (used to finish a folder move). Files first, then the dirs. */
    private suspend fun deleteTree(client: RemoteFsClient, path: String, depth: Int = 0, maxDepth: Int = 40) {
        if (depth > maxDepth) return
        val entries = runCatching { client.list(path) }.getOrDefault(emptyList())
        for (entry in entries) {
            val child = joinPath(path, entry.name)
            if (entry.isDirectory) deleteTree(client, child, depth + 1, maxDepth)
            else runCatching { client.delete(child, false) }
        }
        runCatching { client.delete(path, true) }
    }

    // ── SFTP (real ChannelSftp) ──
    private suspend fun sftpClientOrNull(): JschSftp? =
        selectedServer?.let { JschSftp(buildCredentials(it)) }

    private suspend fun sftpClientFor(server: ServerEntity): JschSftp =
        JschSftp(buildCredentials(server))

    // ── Dual-pane: a second, independent SFTP browser (pane B) ──
    // Kept separate from the primary SFTP state so the two panes never clobber each other. Pane B is
    // read/copy oriented: it lists a second host and stages files onto the cross-endpoint clipboard,
    // which pastes into the primary pane (or vice-versa) via the existing streamed copy.
    var dualPaneEnabled by mutableStateOf(false); private set
    var paneBServerId by mutableStateOf<Int?>(null); private set
    var paneBPath by mutableStateOf(""); private set
    var paneBEntries by mutableStateOf<List<SftpFile>>(emptyList()); private set
    var paneBLoading by mutableStateOf(false); private set
    var paneBError by mutableStateOf<String?>(null); private set
    private var paneBJob: Job? = null

    fun toggleDualPane() {
        dualPaneEnabled = !dualPaneEnabled
        if (dualPaneEnabled && paneBServerId == null) {
            // Default pane B to a different host than the primary SFTP one, if there is one.
            paneBServerId = servers.value.firstOrNull { it.id != selectedServerId }?.id
                ?: servers.value.firstOrNull()?.id
            paneBServerId?.let { loadPaneB(null) }
        }
    }

    fun paneBSelectServer(serverId: Int) {
        if (paneBServerId == serverId) return
        paneBServerId = serverId
        paneBPath = ""
        paneBEntries = emptyList()
        paneBError = null
        loadPaneB(null)
    }

    fun loadPaneB(path: String?) {
        val srv = servers.value.firstOrNull { it.id == paneBServerId } ?: return
        paneBJob?.cancel()
        paneBJob = viewModelScope.launch {
            paneBLoading = true
            paneBError = null
            try {
                val client = sftpClientFor(srv)
                val target = (path ?: paneBPath.ifBlank { client.home() }).ifBlank { "/" }
                val listing = client.list(target)
                if (paneBServerId != srv.id) return@launch
                paneBEntries = sortEntriesBy(listing, sftpSortOption)
                paneBPath = target
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (paneBServerId == srv.id) paneBError = e.message ?: "Could not list folder"
            } finally {
                paneBLoading = false
            }
        }
    }

    fun paneBNavigateInto(name: String) = loadPaneB(joinPath(paneBPath, name))
    fun paneBNavigateUp() {
        val parent = paneBPath.trimEnd('/').substringBeforeLast('/', "")
        loadPaneB(parent.ifBlank { "/" })
    }

    /** Stage a pane-B entry on the cross-endpoint clipboard so it can be pasted into the other pane. */
    fun paneBClipFile(file: SftpFile, move: Boolean) {
        val srv = servers.value.firstOrNull { it.id == paneBServerId } ?: return
        val ref = RemoteFileRef(
            serverId = srv.id,
            sourceLabel = srv.name,
            dir = paneBPath.ifBlank { "/" },
            name = file.name,
            isDirectory = file.isDirectory,
            size = file.size,
        )
        stageCrossRefs(listOf(ref), move)
        sftpClipboard = emptyList()
        sftpClipboardIsMove = false
        sftpStatus = "${if (move) "Cut" else "Copied"} \"${file.name}\" from ${srv.name} — paste in the other pane"
    }

    private fun joinPath(base: String, name: String): String =
        if (base == "/" || base.isEmpty()) "/$name" else "$base/$name"

    private val sftpSessionPaths = mutableMapOf<Int, String>()

    private fun sortSftpEntries(entries: List<SftpFile>): List<SftpFile> = sortEntriesBy(entries, sftpSortOption)

    /** Order a directory listing by [option]. Shared by the SFTP Files tab and the Shares browser. */
    private fun sortEntriesBy(entries: List<SftpFile>, option: SftpSortOption): List<SftpFile> {
        val nameComparator = compareBy<SftpFile> { it.name.lowercase(Locale.ROOT) }
            .thenBy { it.name }
        val base = when (option) {
            SftpSortOption.NameAsc ->
                compareByDescending<SftpFile> { it.isDirectory }.then(nameComparator)
            SftpSortOption.NameDesc ->
                compareByDescending<SftpFile> { it.isDirectory }
                    .thenByDescending { it.name.lowercase(Locale.ROOT) }
                    .thenByDescending { it.name }
            SftpSortOption.ModifiedAsc ->
                compareByDescending<SftpFile> { it.isDirectory }
                    .thenBy { it.modTimeSeconds }
                    .then(nameComparator)
            SftpSortOption.ModifiedDesc ->
                compareByDescending<SftpFile> { it.isDirectory }
                    .thenByDescending { it.modTimeSeconds }
                    .then(nameComparator)
            SftpSortOption.SizeAsc ->
                compareByDescending<SftpFile> { it.isDirectory }
                    .thenBy { it.size }
                    .then(nameComparator)
            SftpSortOption.SizeDesc ->
                compareByDescending<SftpFile> { it.isDirectory }
                    .thenByDescending { it.size }
                    .then(nameComparator)
            SftpSortOption.TypeFoldersFirst ->
                compareByDescending<SftpFile> { it.isDirectory }.then(nameComparator)
            SftpSortOption.TypeFilesFirst ->
                compareBy<SftpFile> { it.isDirectory }.then(nameComparator)
        }
        return entries.sortedWith(base)
    }

    fun ensureSftpLoadedForSelectedServer() {
        val srv = selectedServer ?: return
        if (sftpLoadedServerId == srv.id && (sftpPath.isNotBlank() || sftpEntries.isNotEmpty() || sftpLoading)) return
        sftpLoadedServerId = srv.id
        sftpPath = ""
        sftpEntries = emptyList()
        sftpSelected.clear()
        sftpError = null
        sftpSearchClear()
        loadSftpBookmarks()
        loadSftp(sftpSessionPaths[srv.id]?.takeIf { it.isNotBlank() })
    }

    fun loadSftp(path: String? = null, clearError: Boolean = true) {
        sftpJob?.cancel()
        sftpJob = viewModelScope.launch {
            val targetServerId = selectedServerId
            val srv = selectedServer ?: return@launch
            val client = sftpClientFor(srv)
            sftpLoading = true
            // Mutating ops (paste/delete/save) manage their own error+status banner and then ask for
            // a refresh — they pass clearError=false so this reload doesn't wipe the message.
            if (clearError) sftpError = null
            try {
                val target = path ?: sftpPath.ifBlank { client.home() }
                val listing = client.list(target)
                if (selectedServerId != targetServerId) return@launch  // host changed; discard.
                // Navigating somewhere else invalidates the query/results; a same-path refresh
                // (mkdir/delete/paste reloads) keeps the search bar as-is.
                if (target != sftpPath) sftpSearchClear()
                val entries = if (showSftpFolderSizes) {
                    enrichSftpFolderSizes(srv, target, listing)
                } else {
                    listing
                }
                sftpEntries = sortSftpEntries(entries)
                sftpPath = target
                sftpLoadedServerId = srv.id
                sftpSessionPaths[srv.id] = target
                // Drop any selection that no longer refers to entries in the new listing.
                val names = listing.mapTo(HashSet()) { it.name }
                sftpSelected.retainAll { it in names }
            } catch (e: CancellationException) {
                // A newer navigation cancelled this one (common on high-latency hosts). This is not
                // an error — swallow it so "StandaloneCoroutine was cancelled" never reaches the UI.
                throw e
            } catch (e: Exception) {
                if (selectedServerId == targetServerId) sftpError = e.message ?: "SFTP error"
            } finally {
                // Only the job that's still current should clear the spinner; a cancelled one bows out.
                if (sftpJob == coroutineContext[Job]) sftpLoading = false
            }
        }
    }

    private suspend fun enrichSftpFolderSizes(
        srv: ServerEntity,
        currentPath: String,
        listing: List<SftpFile>,
    ): List<SftpFile> {
        val directories = listing.filter { it.isDirectory }
        if (directories.isEmpty()) return listing

        val paths = directories.map { joinPath(currentPath, it.name) }
        val script = buildString {
            append("for p in ")
            append(paths.joinToString(" ") { shellQuote(it) })
            append("; do ")
            append("b=${'$'}(du -sb -- \"${'$'}p\" 2>/dev/null | awk '{print ${'$'}1}'); ")
            append("if [ -z \"${'$'}b\" ]; then k=${'$'}(du -sk -- \"${'$'}p\" 2>/dev/null | awk '{print ${'$'}1}'); ")
            append("[ -n \"${'$'}k\" ] && b=${'$'}((k * 1024)); fi; ")
            append("[ -n \"${'$'}b\" ] && printf '%s\\t%s\\n' \"${'$'}b\" \"${'$'}p\"; ")
            append("done")
        }
        val out = executeSshCommand(srv, script)
        if (out.startsWith("SSH Error")) return listing

        val sizesByPath = out
            .lineSequence()
            .mapNotNull { line ->
                val parts = line.split('\t', limit = 2)
                val bytes = parts.getOrNull(0)?.toLongOrNull() ?: return@mapNotNull null
                val remotePath = parts.getOrNull(1)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
                remotePath to bytes
            }
            .toMap()

        if (sizesByPath.isEmpty()) return listing
        return listing.map { file ->
            if (file.isDirectory) {
                file.copy(size = sizesByPath[joinPath(currentPath, file.name)] ?: file.size)
            } else {
                file
            }
        }
    }

    /** Reset to the home directory (used when the selected server changes). */
    fun sftpReset() {
        sftpLoadedServerId = null
        sftpPath = ""
        sftpEntries = emptyList()
        sftpSelected.clear()
        sftpError = null
        sftpSearchClear()
        loadSftpBookmarks()
        loadSftp()
    }

    /** Close the search bar and drop the query and any recursive results. */
    fun sftpSearchClear() {
        sftpSearchJob?.cancel()
        sftpSearchActive = false
        sftpSearchQuery = ""
        sftpSearchResults = null
        sftpSearchRunning = false
        sftpSearchTruncated = false
    }

    /** Recursive off→on keeps the current query; on→off drops the host-side results. */
    fun sftpSearchToggleRecursive() {
        sftpSearchRecursive = !sftpSearchRecursive
        if (!sftpSearchRecursive) {
            sftpSearchJob?.cancel()
            sftpSearchResults = null
            sftpSearchRunning = false
            sftpSearchTruncated = false
        }
    }

    /**
     * Recursive search: runs `find` under the current directory over an exec channel, so matching
     * happens host-side and only matching paths cross the wire. Without the wildcard toggle the
     * query becomes a case-insensitive substring (`*q*`); with it, the query is the glob verbatim.
     * Respects [sftpSudo] so protected trees (e.g. /etc) are searchable too.
     */
    fun runSftpSearch() {
        val srv = selectedServer ?: return
        val q = sftpSearchQuery.trim()
        if (q.isEmpty()) return
        sftpSearchJob?.cancel()
        sftpSearchJob = viewModelScope.launch {
            sftpSearchRunning = true
            sftpSearchResults = null
            sftpSearchTruncated = false
            sftpError = null
            try {
                val base = sftpPath.ifBlank { "/" }
                val pattern = if (sftpSearchWildcard) q else "*$q*"
                // Type-tag each hit ('d'/'f' + tab + path) so the UI can render folders distinctly;
                // the while-read loop is POSIX sh, no GNU find -printf needed.
                val script = "find ${shellQuote(base)} -iname ${shellQuote(pattern)} 2>/dev/null | " +
                    "head -n ${SFTP_SEARCH_MAX_HITS + 1} | " +
                    "while IFS= read -r p; do " +
                    "if [ -d \"\$p\" ]; then printf 'd\\t%s\\n' \"\$p\"; else printf 'f\\t%s\\n' \"\$p\"; fi; " +
                    "done"
                val out = if (sftpSudo)
                    executeSshCommand(srv, RemoteCommands.sudoShWrap(script, srv.sudoPassword), stdin = RemoteCommands.sudoStdin(srv.sudoPassword))
                else
                    executeSshCommand(srv, script)
                if (out.startsWith("SSH Error")) { sftpError = out; return@launch }
                sftpReadError(out)?.let { sftpError = it; return@launch }
                val hits = out.lineSequence()
                    .mapNotNull { line ->
                        val tab = line.indexOf('\t')
                        if (tab <= 0) return@mapNotNull null
                        val hitPath = line.substring(tab + 1).trim()
                        // `find` emits the base dir itself when it matches the pattern; skip it.
                        if (hitPath.isEmpty() || hitPath == base) return@mapNotNull null
                        SftpSearchHit(hitPath, line.startsWith("d"))
                    }
                    .toList()
                sftpSearchTruncated = hits.size > SFTP_SEARCH_MAX_HITS
                sftpSearchResults = hits.take(SFTP_SEARCH_MAX_HITS)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                sftpError = e.message ?: "Search failed"
            } finally {
                if (sftpSearchJob == coroutineContext[Job]) sftpSearchRunning = false
            }
        }
    }

    private fun loadSftpBookmarks() {
        val srv = selectedServer ?: return
        viewModelScope.launch {
            val raw = repository.getSetting("sftp_bookmarks_${srv.id}")
            sftpBookmarks.clear()
            if (raw.isNullOrBlank()) {
                sftpBookmarks.addAll(listOf("/root", "/var/log", "/etc", "/opt", "/home"))
            } else {
                sftpBookmarks.addAll(raw.split("|||").filter { it.isNotBlank() })
            }
        }
    }

    fun addSftpBookmark(path: String) {
        val srv = selectedServer ?: return
        if (!sftpBookmarks.contains(path)) {
            sftpBookmarks.add(path)
            viewModelScope.launch {
                repository.insertSetting("sftp_bookmarks_${srv.id}", sftpBookmarks.joinToString("|||"))
            }
        }
    }

    fun removeSftpBookmark(path: String) {
        val srv = selectedServer ?: return
        if (sftpBookmarks.contains(path)) {
            sftpBookmarks.remove(path)
            viewModelScope.launch {
                repository.insertSetting("sftp_bookmarks_${srv.id}", sftpBookmarks.joinToString("|||"))
            }
        }
    }

    // ── Endpoint-scoped bookmarks (Bookmarks tab) ──
    // Bookmarks belong to a specific SSH host or network share, stored per endpoint:
    // "sftp_bookmarks_{serverId}" (the historical format) and "share_bookmarks_{shareId}".
    // The Bookmarks tab shows them all; unavailable endpoints render greyed and unclickable.

    data class EndpointBookmark(
        val serverId: Int?,
        val shareId: Int?,
        val endpointName: String,
        val path: String,
    )

    val allBookmarks = mutableStateListOf<EndpointBookmark>()

    /** Bookmarked paths for the share being browsed (drives the star in the share browser). */
    val shareBookmarks = mutableStateListOf<String>()

    fun loadAllBookmarks() {
        viewModelScope.launch {
            val result = mutableListOf<EndpointBookmark>()
            for (srv in repository.getAllServers()) {
                val raw = repository.getSetting("sftp_bookmarks_${srv.id}") ?: continue
                raw.split("|||").filter { it.isNotBlank() }
                    .forEach { result.add(EndpointBookmark(srv.id, null, srv.name, it)) }
            }
            for (share in repository.getAllNetworkShares()) {
                val raw = repository.getSetting("share_bookmarks_${share.id}") ?: continue
                raw.split("|||").filter { it.isNotBlank() }
                    .forEach { result.add(EndpointBookmark(null, share.id, shareEndpointLabel(share), it)) }
            }
            allBookmarks.clear()
            allBookmarks.addAll(result)
        }
    }

    private fun loadShareBookmarks(shareId: Int) {
        viewModelScope.launch {
            val raw = repository.getSetting("share_bookmarks_$shareId")
            shareBookmarks.clear()
            shareBookmarks.addAll(raw.orEmpty().split("|||").filter { it.isNotBlank() })
        }
    }

    fun addShareBookmark(path: String) {
        val share = browsingShare ?: return
        val normalized = path.ifBlank { "/" }
        if (normalized in shareBookmarks) return
        shareBookmarks.add(normalized)
        viewModelScope.launch {
            repository.insertSetting("share_bookmarks_${share.id}", shareBookmarks.joinToString("|||"))
        }
        shareStatus = "Bookmarked $normalized"
    }

    fun removeShareBookmark(path: String) {
        val share = browsingShare ?: return
        if (!shareBookmarks.remove(path)) return
        viewModelScope.launch {
            repository.insertSetting("share_bookmarks_${share.id}", shareBookmarks.joinToString("|||"))
        }
    }

    /** Remove a bookmark from whichever endpoint owns it, then refresh the unified list. */
    fun removeEndpointBookmark(bookmark: EndpointBookmark) {
        viewModelScope.launch {
            val key = when {
                bookmark.serverId != null -> "sftp_bookmarks_${bookmark.serverId}"
                bookmark.shareId != null -> "share_bookmarks_${bookmark.shareId}"
                else -> return@launch
            }
            val remaining = repository.getSetting(key).orEmpty()
                .split("|||").filter { it.isNotBlank() && it != bookmark.path }
            repository.insertSetting(key, remaining.joinToString("|||"))
            allBookmarks.remove(bookmark)
            // Keep the per-endpoint lists that drive the star toggles in sync.
            if (bookmark.serverId == selectedServerId) sftpBookmarks.remove(bookmark.path)
            if (bookmark.shareId == browsingShare?.id) shareBookmarks.remove(bookmark.path)
        }
    }

    /**
     * Follow a bookmark to its endpoint. Availability is enforced by the UI (greyed rows), but
     * re-checked here so a stale tap can't dial an offline endpoint.
     */
    fun openEndpointBookmark(bookmark: EndpointBookmark) {
        viewModelScope.launch {
            when {
                bookmark.serverId != null -> {
                    val online = servers.value.any { it.id == bookmark.serverId && it.status == "online" }
                    if (!online) return@launch
                    selectedServerId = bookmark.serverId
                    activeSftpTab = 0
                    loadSftp(bookmark.path)
                }
                bookmark.shareId != null -> {
                    val share = repository.getAllNetworkShares().firstOrNull { it.id == bookmark.shareId } ?: return@launch
                    if (share.lastStatus == "offline") return@launch
                    activeSftpTab = 1
                    openShareBrowser(share, startPath = bookmark.path)
                }
            }
        }
    }

    fun sftpCd(name: String) = loadSftp(joinPath(sftpPath, name))

    fun sftpHome() {
        sftpPath = ""
        loadSftp(null)
    }

    fun sftpUp() {
        if (sftpPath.isNotEmpty() && sftpPath != "/") {
            loadSftp(sftpPath.trimEnd('/').substringBeforeLast('/').ifEmpty { "/" })
        }
    }

    fun sftpMkdir(name: String) {
        val srv = selectedServer
        viewModelScope.launch {
            try {
                val err = if (sftpSudo && srv != null)
                    runSftpSudo(srv, "mkdir -- ${shellQuote(joinPath(sftpPath, name))}")
                else { sftpClientOrNull()?.mkdir(joinPath(sftpPath, name)); null }
                if (err != null) { sftpError = err; return@launch }
                sftpStatus = "Created \"$name\"${sudoTag()}"
                loadSftp(sftpPath)  // reload only on success — loadSftp clears sftpError.
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = e.message ?: "Create failed" }
        }
    }

    /**
     * Create an archive from the current selection (or a single [only] entry) in the current folder,
     * server-side via the host's zip/tar. [format] is "zip" | "tar.gz" | "tar". Refreshes on success.
     */
    fun sftpArchiveSelection(format: String, only: SftpFile? = null) {
        val srv = selectedServer ?: return
        val names = if (only != null) listOf(only.name) else sftpSelected.toList()
        if (names.isEmpty()) return
        val ext = when (format) { "zip" -> "zip"; "tar" -> "tar"; else -> "tar.gz" }
        val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(java.util.Date())
        val base = if (names.size == 1) names.first().substringBeforeLast('.', names.first()) else "archive-$stamp"
        val archiveName = "$base.$ext"
        viewModelScope.launch {
            sftpError = null
            try {
                val cmd = RemoteCommands.archiveCreate(sftpPath.ifBlank { "." }, archiveName, names, format)
                val out = executeSshCommand(srv, if (sftpSudo) RemoteCommands.sudoShWrap(cmd, srv.sudoPassword) else cmd,
                    stdin = if (sftpSudo) RemoteCommands.sudoStdin(srv.sudoPassword) else null)
                val err = sftpReadError(out)
                if (err != null) { sftpError = "Archive failed: $err"; return@launch }
                sftpClearSelection()
                sftpStatus = "Created $archiveName${sudoTag()}"
                loadSftp(sftpPath)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = "Archive failed: ${e.message}" }
        }
    }

    /** Extract an archive file into a same-named subfolder, server-side. */
    fun sftpExtractArchive(file: SftpFile) {
        val srv = selectedServer ?: return
        viewModelScope.launch {
            sftpError = null
            try {
                val cmd = RemoteCommands.archiveExtract(sftpPath.ifBlank { "." }, file.name)
                val out = executeSshCommand(srv, if (sftpSudo) RemoteCommands.sudoShWrap(cmd, srv.sudoPassword) else cmd,
                    stdin = if (sftpSudo) RemoteCommands.sudoStdin(srv.sudoPassword) else null)
                val err = sftpReadError(out)
                if (err != null) { sftpError = "Extract failed: $err"; return@launch }
                sftpStatus = "Extracted ${file.name}${sudoTag()}"
                loadSftp(sftpPath)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = "Extract failed: ${e.message}" }
        }
    }

    /** True for filenames the in-app extractor understands (zip / tar / tar.gz / tgz). */
    fun isArchiveFile(name: String): Boolean {
        val l = name.lowercase()
        return l.endsWith(".zip") || l.endsWith(".tar.gz") || l.endsWith(".tgz") || l.endsWith(".tar")
    }

    fun sftpDelete(file: SftpFile) {
        val srv = selectedServer
        viewModelScope.launch {
            try {
                val err = if (sftpSudo && srv != null)
                    runSftpSudo(srv, "rm -rf -- ${shellQuote(joinPath(sftpPath, file.name))}")
                else { sftpClientOrNull()?.delete(joinPath(sftpPath, file.name), file.isDirectory); null }
                if (err != null) { sftpError = err; return@launch }
                sftpStatus = "Deleted \"${file.name}\"${sudoTag()}"
                loadSftp(sftpPath)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = e.message ?: "Delete failed" }
        }
    }

    fun sftpRename(file: SftpFile, newName: String) {
        val srv = selectedServer
        viewModelScope.launch {
            try {
                val from = joinPath(sftpPath, file.name)
                val to = joinPath(sftpPath, newName)
                val err = if (sftpSudo && srv != null)
                    runSftpSudo(srv, "mv -- ${shellQuote(from)} ${shellQuote(to)}")
                else { sftpClientOrNull()?.rename(from, to); null }
                if (err != null) { sftpError = err; return@launch }
                sftpStatus = "Renamed to \"$newName\"${sudoTag()}"
                loadSftp(sftpPath)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = e.message ?: "Rename failed" }
        }
    }

    /** Open a file for editing: read its text and stash it on [edittingSftpFile]. */
    fun openSftpFileForEdit(file: SftpFile) {
        val srv = selectedServer
        viewModelScope.launch {
            sftpError = null
            try {
                val path = joinPath(sftpPath, file.name)
                val text = if (sftpSudo && srv != null) {
                    // SFTP can't elevate; read protected files with `sudo cat` over an exec channel.
                    val out = executeSshCommand(srv, RemoteCommands.sudoShWrap("cat -- ${shellQuote(path)}", srv.sudoPassword), stdin = RemoteCommands.sudoStdin(srv.sudoPassword))
                    sftpReadError(out)?.let { sftpError = it; return@launch }
                    out
                } else {
                    sftpClientOrNull()?.readText(path) ?: return@launch
                }
                edittingSftpFilePath = file.name
                edittingSftpFile = file.copy(content = text)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = e.message }
        }
    }

    // ── Multi-select + copy / cut / move ──
    fun sftpToggleSelect(name: String) {
        if (name in sftpSelected) sftpSelected.remove(name) else sftpSelected.add(name)
    }

    fun sftpSelectAll() {
        sftpSelected.clear()
        sftpSelected.addAll(sftpEntries.map { it.name })
    }

    fun sftpClearSelection() = sftpSelected.clear()

    /** Stage the current selection on the clipboard. [move] = cut (the originals are removed on paste). */
    fun sftpClipSelection(move: Boolean) {
        if (sftpSelected.isEmpty()) return
        val srv = selectedServer
        sftpClipboard = sftpSelected.map { joinPath(sftpPath, it) }
        sftpClipboardIsMove = move
        sftpClipboardServerId = srv?.id
        // Mirror the staging onto the cross-endpoint clipboard so the same copy/cut can be pasted
        // into a network share's browser or onto a different host, not just back on this server.
        if (srv != null) {
            val byName = sftpEntries.associateBy { it.name }
            crossClipboard = sftpSelected.mapNotNull { name ->
                byName[name]?.let { f ->
                    RemoteFileRef(
                        serverId = srv.id,
                        sourceLabel = srv.name,
                        dir = sftpPath.ifBlank { "/" },
                        name = f.name,
                        isDirectory = f.isDirectory,
                        size = f.size,
                    )
                }
            }
            crossClipboardIsMove = move
        }
        val verb = if (move) "Cut" else "Copied"
        sftpStatus = "$verb ${sftpClipboard.size} item(s) — paste in a folder here, on another host, or in a share"
        sftpSelected.clear()
    }

    fun sftpClearClipboard() {
        sftpClipboard = emptyList()
        sftpClipboardIsMove = false
        sftpClipboardServerId = null
        clearCrossClipboard()
    }

    /**
     * Paste the clipboard into the current directory. Done server-side via `cp -a` / `mv` over an
     * exec channel: directories are handled recursively and no bytes ever leave the host (far faster
     * than streaming a download+upload through the device, especially on high-latency links).
     */
    fun sftpPaste() {
        if (sftpClipboard.isEmpty() || sftpPasteRunning) return
        val srv = selectedServer ?: return
        val sources = sftpClipboard
        val isMove = sftpClipboardIsMove
        val destDir = sftpPath.ifBlank { "/" }
        val sudo = sftpSudo
        viewModelScope.launch {
            sftpPasteRunning = true
            sftpError = null
            try {
                val script = buildString {
                    val op = if (isMove) "mv -f --" else "cp -a --"
                    append("set -e; ")
                    sources.forEachIndexed { i, src ->
                        if (i > 0) append(" && ")
                        append("$op ${shellQuote(src)} ${shellQuote(destDir)}/")
                    }
                }
                // Same server-side cp/mv, optionally elevated so protected destinations work.
                val out = if (sudo)
                    executeSshCommand(srv, RemoteCommands.sudoShWrap(script, srv.sudoPassword), stdin = RemoteCommands.sudoStdin(srv.sudoPassword)).trim()
                else
                    executeSshCommand(srv, script).trim()
                val err = sftpExecError(out)
                if (err != null) {
                    sftpError = err
                } else {
                    sftpStatus = "${if (isMove) "Moved" else "Copied"} ${sources.size} item(s) here${sudoTag()}"
                    // A successful paste consumes the clipboard (copy included — re-copying is one tap).
                    sftpClearClipboard()
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = "Paste failed: ${e.message}" }
            finally { sftpPasteRunning = false }
            // Refresh the destination listing without clobbering the status/error set above.
            loadSftp(destDir, clearError = false)
        }
    }

    /** Delete every selected entry, then refresh. Reports how many succeeded. */
    fun sftpDeleteSelected() {
        if (sftpSelected.isEmpty()) return
        val srv = selectedServer
        val targets = sftpEntries.filter { it.name in sftpSelected }
        viewModelScope.launch {
            if (sftpSudo && srv != null) {
                // One elevated rm for the whole selection.
                val script = "rm -rf -- " + targets.joinToString(" ") { shellQuote(joinPath(sftpPath, it.name)) }
                val err = runSftpSudo(srv, script)
                sftpSelected.clear()
                sftpError = err
                sftpStatus = if (err == null) "Deleted ${targets.size} item(s) (sudo)" else "Delete failed (sudo) — see error"
                loadSftp(sftpPath, clearError = false)
                return@launch
            }
            val sftp = sftpClientOrNull() ?: return@launch
            var ok = 0
            var firstErr: String? = null
            for (f in targets) {
                try {
                    sftp.delete(joinPath(sftpPath, f.name), f.isDirectory)
                    ok++
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { if (firstErr == null) firstErr = e.message }
            }
            sftpSelected.clear()
            sftpError = firstErr
            sftpStatus = if (firstErr == null) "Deleted $ok item(s)" else "Deleted $ok of ${targets.size} — see error"
            // Refresh to reflect the removals while keeping the error/status banner intact.
            loadSftp(sftpPath, clearError = false)
        }
    }

    /** Quote a path for safe use inside the single-line shell command we build for paste. */
    private fun shellQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"

    private fun sudoTag(): String = if (sftpSudo) " (sudo)" else ""

    /** Run [script] as root over an exec channel; returns null on success or a one-line error. */
    private suspend fun runSftpSudo(srv: ServerEntity, script: String): String? =
        sftpExecError(executeSshCommand(srv, RemoteCommands.sudoShWrap(script, srv.sudoPassword), stdin = RemoteCommands.sudoStdin(srv.sudoPassword)))

    /** Substrings that mean a server-side cp/mv/rm/etc. (or the exec transport / sudo) failed. */
    private val SFTP_EXEC_ERROR_MARKERS = listOf(
        "cannot", "permission denied", "no such", "ssh error", "not a directory", "same file",
        "error:", "sudo:", "a password is required", "incorrect password", "try again",
        "not in the sudoers", "operation not permitted", "read-only file system",
    )

    /** Inspect exec output for a failure; returns the first offending line, or null if it looks OK. */
    private fun sftpExecError(out: String): String? {
        val t = out.trim()
        if (t.isEmpty()) return null
        return if (SFTP_EXEC_ERROR_MARKERS.any { t.contains(it, ignoreCase = true) })
            (t.lineSequence().firstOrNull { it.isNotBlank() } ?: t) else null
    }

    /**
     * Stricter check for reading a file via `sudo cat`: only the file's first line is inspected, and
     * only against privilege/missing-file markers — so a config file that legitimately contains a
     * word like "cannot" isn't mistaken for an error.
     */
    private fun sftpReadError(out: String): String? {
        val first = out.lineSequence().firstOrNull { it.isNotBlank() }?.trim() ?: return null
        val markers = listOf(
            "permission denied", "no such file", "sudo:", "a password is required",
            "incorrect password", "not in the sudoers", "operation not permitted",
        )
        return if (markers.any { first.contains(it, ignoreCase = true) }) first else null
    }

    /** Download [remoteName] from the current remote dir into the SAF-provided [uri]. */
    fun sftpDownload(remoteName: String, uri: android.net.Uri, context: android.content.Context) {
        viewModelScope.launch {
            val srv = selectedServer ?: return@launch
            val client = sftpClientFor(srv)
            val remoteDir = sftpPath
            val remotePath = joinPath(remoteDir, remoteName)
            val transferId = addSftpTransfer(srv, "Download", remoteName, remotePath)
            try {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri).use { output ->
                        output ?: throw java.io.IOException("Could not open destination.")
                        client.downloadTo(remotePath, output, transferProgress(transferId))
                    }
                }
                finishSftpTransfer(transferId, SftpTransferStatus.Success, bytes, bytes, "Downloaded $bytes bytes")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (selectedServerId == srv.id) sftpError = e.message
                finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = e.message ?: "Download failed")
            }
        }
    }

    /** Download multiple remote files into a user-picked SAF folder, one file per transfer row. */
    fun sftpDownloadFilesToFolder(
        remoteNames: List<String>,
        folderUri: android.net.Uri,
        context: android.content.Context,
    ) {
        val names = remoteNames.distinct().filter { it.isNotBlank() }
        if (names.isEmpty()) return
        viewModelScope.launch {
            val srv = selectedServer ?: return@launch
            val client = sftpClientFor(srv)
            val remoteDir = sftpPath
            var ok = 0
            var firstErr: String? = null
            sftpError = null
            val batchId = beginTransferBatch(names.size)
            try {
                for (name in names) {
                    val remotePath = joinPath(remoteDir, name)
                    val transferId = addSftpTransfer(srv, "Download", name, remotePath)
                    try {
                        val destUri = createDocumentInTree(context, folderUri, name)
                        val copied = withContext(Dispatchers.IO) {
                            context.contentResolver.openOutputStream(destUri).use { output ->
                                output ?: throw java.io.IOException("Could not open destination for $name.")
                                client.downloadTo(remotePath, output, transferProgress(transferId))
                            }
                        }
                        ok++
                        finishSftpTransfer(transferId, SftpTransferStatus.Success, copied, copied, "Downloaded $copied bytes")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        val msg = e.message ?: "Download failed"
                        if (firstErr == null) firstErr = "$name: $msg"
                        finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = msg)
                    }
                    advanceTransferBatch(batchId)
                }
            } finally {
                endTransferBatch(batchId)
            }
            sftpSelected.removeAll(names.toSet())
            sftpError = firstErr
            sftpStatus = if (firstErr == null) "Downloaded $ok file(s)" else "Downloaded $ok of ${names.size} file(s) — see error"
        }
    }

    /** Upload a local file (picked via the system file picker) into the current remote directory. */
    fun sftpUpload(uri: android.net.Uri, context: android.content.Context) {
        sftpUploadMany(listOf(uri), context)
    }

    /** Upload multiple local files into the current remote directory, streaming each file. */
    fun sftpUploadMany(uris: List<android.net.Uri>, context: android.content.Context) {
        val picked = uris.distinct()
        if (picked.isEmpty()) return
        viewModelScope.launch {
            val srv = selectedServer ?: run {
                sftpError = "Select a server before uploading."
                return@launch
            }
            val client = sftpClientFor(srv)
            sftpError = null
            val remoteDir = sftpPath.ifBlank { runCatching { client.home() }.getOrDefault("/") }
            var ok = 0
            var firstErr: String? = null
            val batchId = beginTransferBatch(picked.size)
            try {
                for ((index, uri) in picked.withIndex()) {
                    val name = queryDisplayName(context, uri)?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                        ?: "upload_${System.currentTimeMillis()}_${index + 1}"
                    val remotePath = joinPath(remoteDir, name)
                    val transferId = addSftpTransfer(srv, "Upload", name, remotePath, sourceUri = uri.toString())
                    try {
                        val totalBytes = queryOpenableSize(context, uri)
                        val uploaded = withContext(Dispatchers.IO) {
                            context.contentResolver.openInputStream(uri).use { input ->
                                input ?: throw java.io.IOException("Could not read the selected file from this device.")
                                client.uploadStream(remotePath, input, totalBytes, transferProgress(transferId))
                                totalBytes.coerceAtLeast(0L)
                            }
                        }
                        ok++
                        finishSftpTransfer(transferId, SftpTransferStatus.Success, uploaded, uploaded, if (uploaded > 0L) "Uploaded $uploaded bytes" else "Uploaded")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        val msg = e.message ?: "unknown error"
                        if (firstErr == null) firstErr = "$name: $msg"
                        finishSftpTransfer(transferId, SftpTransferStatus.Failure, message = msg)
                    }
                    advanceTransferBatch(batchId)
                }
            } finally {
                endTransferBatch(batchId)
            }
            if (selectedServerId == srv.id) sftpError = firstErr?.let { "Upload failed: $it" }
            sftpStatus = if (firstErr == null) "Uploaded $ok file(s)" else "Uploaded $ok of ${picked.size} file(s) — see error"
            refreshSftpIfStillViewing(srv.id, remoteDir)
        }
    }

    private fun createDocumentInTree(
        context: android.content.Context,
        treeUri: android.net.Uri,
        displayName: String,
    ): android.net.Uri = with(context.contentResolver) {
        val parent = android.provider.DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            android.provider.DocumentsContract.getTreeDocumentId(treeUri),
        )
        android.provider.DocumentsContract.createDocument(
            this,
            parent,
            "application/octet-stream",
            displayName.substringAfterLast('/').takeIf { it.isNotBlank() } ?: "download_${System.currentTimeMillis()}",
        ) ?: throw java.io.IOException("Could not create destination file.")
    }

    private fun addSftpTransfer(server: ServerEntity, direction: String, name: String, remotePath: String, sourceUri: String? = null): String =
        addTransfer(server.id, server.name, direction, name, remotePath, sourceUri)

    /**
     * Add a row to the shared transfer log. [endpointId] is a server id for SFTP transfers or the
     * negated share id for network-share transfers (the two id spaces never collide that way).
     */
    private fun addTransfer(endpointId: Int, endpointName: String, direction: String, name: String, remotePath: String, sourceUri: String? = null): String {
        val item = SftpTransferItem(serverId = endpointId, serverName = endpointName, direction = direction, name = name, remotePath = remotePath, sourceUri = sourceUri)
        sftpTransfers.add(0, item)
        // Trim the oldest finished entries so the log can't grow without bound across a session.
        for (i in sftpTransfers.indices.reversed()) {
            if (sftpTransfers.size <= SFTP_TRANSFER_LOG_MAX) break
            if (sftpTransfers[i].status != SftpTransferStatus.InProgress) sftpTransfers.removeAt(i)
        }
        return item.id
    }

    /**
     * Roll up the in-flight transfers into a single files-and-bytes summary. [endpointId] filters
     * to one endpoint (a server id, or the negated share id) for an inline browser banner; null
     * aggregates every running transfer for the Transfers tab. Returns null when nothing is running.
     */
    fun transferAggregate(endpointId: Int? = null): TransferAggregate? {
        val running = sftpTransfers.filter {
            it.status == SftpTransferStatus.InProgress && (endpointId == null || it.serverId == endpointId)
        }
        if (running.isEmpty()) return null
        val done = running.sumOf { it.bytesTransferred.coerceAtLeast(0L) }
        // Only rows with a known size contribute to the total, so an unknown-size row doesn't
        // drag the aggregate bar to 0%.
        val total = running.filter { it.totalBytes > 0 }.sumOf { it.totalBytes }
        val speed = running.sumOf { it.speedKbps.toDouble() }.toFloat()
        return TransferAggregate(running.size, done, total, speed)
    }

    private fun refreshSftpIfStillViewing(serverId: Int, remoteDir: String) {
        if (selectedServerId == serverId && sftpPath == remoteDir) {
            loadSftp(remoteDir)
        }
    }

    private fun updateSftpTransferProgress(id: String, bytesTransferred: Long, totalBytes: Long) {
        viewModelScope.launch(Dispatchers.Main.immediate) {
            val index = sftpTransfers.indexOfFirst { it.id == id }
            if (index >= 0) {
                val current = sftpTransfers[index]
                val elapsedSec = (System.currentTimeMillis() - current.startedAtMs) / 1000f
                val speed = if (elapsedSec > 0f) bytesTransferred / elapsedSec / 1024f else 0f
                val remaining = totalBytes - bytesTransferred
                val eta = if (speed > 0f) (remaining / (speed * 1024f)).toInt() else -1
                sftpTransfers[index] = current.copy(
                    bytesTransferred = bytesTransferred.coerceAtLeast(0L),
                    totalBytes = totalBytes.coerceAtLeast(0L),
                    speedKbps = speed,
                    etaSeconds = eta,
                )
            }
        }
    }

    private fun finishSftpTransfer(
        id: String,
        status: SftpTransferStatus,
        bytesTransferred: Long? = null,
        totalBytes: Long? = null,
        message: String = "",
    ) {
        // A cancelled row reports as Failure with a fixed message the UI renders as "Cancelled";
        // it is never retryable (the user just asked for it to stop).
        val wasCancelled = cancelledTransferIds.remove(id)
        val index = sftpTransfers.indexOfFirst { it.id == id }
        if (index >= 0) {
            val current = sftpTransfers[index]
            sftpTransfers[index] = current.copy(
                status = status,
                bytesTransferred = bytesTransferred ?: current.bytesTransferred,
                totalBytes = totalBytes ?: current.totalBytes,
                message = if (wasCancelled && status == SftpTransferStatus.Failure) TRANSFER_CANCELLED_MESSAGE else message,
                retryable = !wasCancelled && status == SftpTransferStatus.Failure && current.direction == "Upload" && current.sourceUri != null,
            )
        }
    }

    fun retrySftpTransfer(item: SftpTransferItem) {
        // Negative ids are network-share transfers; retry would re-upload to the selected SSH
        // host instead of the share, so those rows are never marked retryable (see below).
        if (!item.retryable || item.sourceUri == null || item.serverId < 0) return
        val uri = runCatching { android.net.Uri.parse(item.sourceUri) }.getOrNull() ?: return
        val context = getApplication<android.app.Application>()
        sftpUploadMany(listOf(uri), context)
    }

    private fun queryDisplayName(context: android.content.Context, uri: android.net.Uri): String? =
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        }.getOrNull()

    private fun queryOpenableSize(context: android.content.Context, uri: android.net.Uri): Long =
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (idx >= 0 && c.moveToFirst() && !c.isNull(idx)) c.getLong(idx).coerceAtLeast(0L) else 0L
            } ?: 0L
        }.getOrDefault(0L)

    /**
     * Save an edited file and confirm it persisted. We write the new content, then read the remote
     * file size back and compare it to the bytes we sent — only on a match do we report success and
     * close the editor. A mismatch (or transport error) keeps the editor open with an error so the
     * user never loses their edits to a silently-failed save.
     */
    fun sftpSaveText(file: SftpFile, content: String, onSaved: () -> Unit = {}) {
        val srv = selectedServer
        val sudo = sftpSudo
        viewModelScope.launch {
            val client = sftpClientOrNull() ?: return@launch
            sftpSaving = true
            sftpError = null
            try {
                val dest = joinPath(sftpPath, file.name)
                val expected = content.toByteArray(Charsets.UTF_8).size.toLong()
                val reported = if (sudo && srv != null) {
                    // SFTP put can't write a protected path. Put a temp copy in a writable dir, then
                    // sudo-copy it into place and read the size back as root to confirm persistence.
                    val tmp = "/tmp/.omniterm_save_${System.currentTimeMillis()}"
                    client.writeText(tmp, content)
                    val script = "cp -f -- ${shellQuote(tmp)} ${shellQuote(dest)} && wc -c < ${shellQuote(dest)}; rm -f -- ${shellQuote(tmp)}"
                    val out = executeSshCommand(srv, RemoteCommands.sudoShWrap(script, srv.sudoPassword), stdin = RemoteCommands.sudoStdin(srv.sudoPassword)).trim()
                    sftpExecError(out)?.let { throw java.io.IOException(it) }
                    out.lineSequence().lastOrNull { it.trim().toLongOrNull() != null }?.trim()?.toLongOrNull() ?: -1L
                } else {
                    client.writeText(dest, content)
                }
                val tag = sudoTag()
                if (reported < 0L) {
                    // Couldn't stat afterwards; the write itself didn't throw, so treat as saved but
                    // tell the user we couldn't independently confirm the byte count.
                    sftpStatus = "Saved \"${file.name}\"$tag (size unconfirmed)"
                    onSaved()
                } else if (reported == expected) {
                    sftpStatus = "Saved \"${file.name}\"$tag — $reported bytes confirmed on remote"
                    onSaved()
                } else {
                    sftpError = "Save not confirmed: remote shows $reported bytes, expected $expected. " +
                        "Your edits are kept here — try saving again."
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { sftpError = "Save failed: ${e.message}" }
            finally { sftpSaving = false }
            // Refresh sizes/mtimes without clearing the save confirmation (or the error) we just set.
            loadSftp(sftpPath, clearError = false)
        }
    }

    // MULTI-HOST FLEET BROADCAST CODE
    /**
     * Executes [command] on the broadcast targets. When [resolvedIds] is given (the list the user
     * just confirmed in the dialog), exactly those hosts are hit — group/online membership is NOT
     * re-evaluated here, so the set can't drift between confirmation and execution.
     */
    fun runFleetBroadcast(command: String, resolvedIds: List<Int>? = null) {
        if (command.isBlank()) return
        if (isBroadcastExecuting) return
        val cmd = command.trim()
        val targetIds = broadcastTargetServerIds.toList()
        val targetGroups = broadcastTargetGroups.toList()
        isBroadcastExecuting = true
        broadcastResults.clear()

        broadcastJob = viewModelScope.launch {
            val allServers = repository.getAllServers()
            val selected = when {
                resolvedIds != null -> allServers.filter { it.status == "online" && it.id in resolvedIds }
                broadcastTargetMode == FleetTargetMode.Servers -> allServers.filter { it.status == "online" && it.id in targetIds }
                else -> allServers.filter { it.status == "online" && it.groupName.orEmpty() in targetGroups }
            }
            if (selected.isEmpty()) {
                isBroadcastExecuting = false
                return@launch
            }
            broadcastResults.addAll(selected.map { BroadcastResultItem(serverId = it.id, serverName = it.name) })
            val limiter = Semaphore(6)
            try {
                withTimeout(BROADCAST_TIMEOUT_MS) {
                    selected.map { srv ->
                        async {
                            limiter.withPermit {
                                try {
                                    val output = sshTransport.execStream(buildCredentials(srv), cmd) { chunk ->
                                        appendBroadcastChunk(srv.id, chunk)
                                    }
                                    finishBroadcastResult(
                                        srv.id,
                                        if (output.startsWith("SSH Error")) BroadcastStatus.Failure else BroadcastStatus.Success,
                                        when {
                                            output.startsWith("SSH Error") -> output
                                            output.isBlank() -> "Done (no output)"
                                            else -> null
                                        },
                                    )
                                } catch (e: Exception) {
                                    if (e is CancellationException) throw e
                                    finishBroadcastResult(srv.id, BroadcastStatus.Failure, "SSH Error: ${e.message ?: "unknown error"}")
                                }
                            }
                        }
                    }.awaitAll()
                }
            } catch (e: TimeoutCancellationException) {
                markRunningBroadcastsFailed("Timed out after ${BROADCAST_TIMEOUT_MS / 60_000} minutes.")
            } catch (e: CancellationException) {
                markRunningBroadcastsFailed("Cancelled.")
            } finally {
                isBroadcastExecuting = false
                broadcastJob = null
            }
        }
    }

    fun stopFleetBroadcast() {
        broadcastJob?.cancel()
    }

    private fun appendBroadcastChunk(serverId: Int, chunk: String) {
        viewModelScope.launch(Dispatchers.Main.immediate) {
            val index = broadcastResults.indexOfFirst { it.serverId == serverId }
            if (index >= 0) {
                val current = broadcastResults[index]
                val appended = current.output + chunk
                val truncated = current.truncated || appended.length > BROADCAST_OUTPUT_MAX_CHARS
                broadcastResults[index] = current.copy(
                    output = if (truncated) appended.takeLast(BROADCAST_OUTPUT_MAX_CHARS) else appended,
                    truncated = truncated,
                )
            }
        }
    }

    private fun finishBroadcastResult(serverId: Int, status: BroadcastStatus, fallbackOutput: String? = null) {
        val index = broadcastResults.indexOfFirst { it.serverId == serverId }
        if (index >= 0) {
            val current = broadcastResults[index]
            broadcastResults[index] = current.copy(
                status = status,
                output = if (current.output.isBlank() && fallbackOutput != null) fallbackOutput else current.output,
            )
        }
    }

    private fun markRunningBroadcastsFailed(message: String) {
        for (i in broadcastResults.indices) {
            val current = broadcastResults[i]
            if (current.status == BroadcastStatus.Running) {
                broadcastResults[i] = current.copy(status = BroadcastStatus.Failure, output = current.output.ifBlank { message })
            }
        }
    }

    // PORT SCANNER MODULE
    fun runPortScanner() {
        val target = portScannerTarget.trim()
        if (target.isBlank()) return
        val ports = portScannerRange
            .split(",")
            .mapNotNull { it.trim().toIntOrNull() }
            .filter { it in 1..65535 }
            .distinct()
        if (ports.isEmpty()) return
        if (isPortScannerScanning) return
        isPortScannerScanning = true
        portScannerResults.clear()

        viewModelScope.launch {
            try {
                val results = withContext(Dispatchers.IO) {
                    val limiter = Semaphore(32)
                    ports.map { port ->
                        async {
                            limiter.withPermit {
                                val status = try {
                                    probePort(target, port)
                                } catch (_: Exception) {
                                    "Closed"
                                }
                                port to status
                            }
                        }
                    }.awaitAll().sortedBy { it.first }
                }
                portScannerResults.addAll(results)
            } finally {
                isPortScannerScanning = false
            }
        }
    }

    // DNS LOOKUP MODULE
    fun runDnsLookup() {
        val target = dnsLookupTarget.trim()
        if (target.isBlank()) return
        if (isDnsLookupRunning) return
        isDnsLookupRunning = true
        dnsLookupError = null
        dnsLookupResults.clear()

        viewModelScope.launch {
            try {
                val type = when (dnsLookupType.uppercase()) {
                    "A" -> 1
                    "NS" -> 2
                    "CNAME" -> 5
                    "MX" -> 15
                    "TXT" -> 16
                    "AAAA" -> 28
                    else -> 1
                }
                val queryBytes = serializeDnsQuery(target, type)
                val response = resolveDnsRaw(queryBytes)
                val results = parseDnsResponse(response, response.size)
                dnsLookupResults.addAll(results)
                if (results.isEmpty()) {
                    dnsLookupError = "No records found."
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                dnsLookupError = "DNS Lookup failed: ${e.message}"
            } finally {
                isDnsLookupRunning = false
            }
        }
    }

    /**
     * Send a raw DNS query and return the raw response. The system resolver (DnsResolver, API 29+)
     * goes first: it uses whatever DNS the current network actually provides — including Private
     * DNS — so it works on networks that block or intercept third-party resolvers, which is why a
     * hardcoded 8.8.8.8 UDP query "did nothing" on many phone networks. Direct UDP against public
     * resolvers, then TCP 53 (for networks that drop UDP DNS), remain as fallbacks.
     */
    private suspend fun resolveDnsRaw(query: ByteArray): ByteArray {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                return systemDnsRawQuery(query)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Fall through to direct queries.
            }
        }
        var lastError: Exception? = null
        return withContext(Dispatchers.IO) {
            for (server in listOf("8.8.8.8", "1.1.1.1")) {
                try {
                    return@withContext udpDnsQuery(server, query)
                } catch (e: Exception) {
                    lastError = e
                }
                try {
                    return@withContext tcpDnsQuery(server, query)
                } catch (e: Exception) {
                    lastError = e
                }
            }
            throw lastError ?: java.io.IOException("no resolver reachable")
        }
    }

    @androidx.annotation.RequiresApi(29)
    private suspend fun systemDnsRawQuery(query: ByteArray): ByteArray =
        suspendCancellableCoroutine { cont ->
            val signal = android.os.CancellationSignal()
            cont.invokeOnCancellation { signal.cancel() }
            android.net.DnsResolver.getInstance().rawQuery(
                null, // default network
                query,
                android.net.DnsResolver.FLAG_EMPTY,
                Dispatchers.IO.asExecutor(),
                signal,
                object : android.net.DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (cont.isActive) cont.resumeWith(Result.success(answer))
                    }

                    override fun onError(error: android.net.DnsResolver.DnsException) {
                        if (cont.isActive) cont.resumeWith(Result.failure(error))
                    }
                },
            )
        }

    private fun udpDnsQuery(server: String, query: ByteArray): ByteArray =
        java.net.DatagramSocket().use { socket ->
            socket.soTimeout = 4000
            socket.send(java.net.DatagramPacket(query, query.size, java.net.InetAddress.getByName(server), 53))
            val buf = ByteArray(4096)
            val packet = java.net.DatagramPacket(buf, buf.size)
            socket.receive(packet)
            packet.data.copyOf(packet.length)
        }

    private fun tcpDnsQuery(server: String, query: ByteArray): ByteArray =
        java.net.Socket().use { socket ->
            socket.connect(java.net.InetSocketAddress(server, 53), 4000)
            socket.soTimeout = 4000
            val out = java.io.DataOutputStream(socket.getOutputStream())
            out.writeShort(query.size)
            out.write(query)
            out.flush()
            val input = java.io.DataInputStream(socket.getInputStream())
            val len = input.readUnsignedShort()
            val buf = ByteArray(len)
            input.readFully(buf)
            buf
        }

    // WHOIS MODULE
    fun runWhois() {
        val target = whoisTarget.trim()
        if (target.isBlank()) return
        if (isWhoisRunning) return
        isWhoisRunning = true
        whoisError = null
        whoisResult = ""

        viewModelScope.launch {
            try {
                val initialServer = if (isIpAddress(target)) "whois.arin.net" else "whois.iana.org"
                val firstResponse = withContext(Dispatchers.IO) {
                    queryWhoisServer(initialServer, target)
                }
                val referral = extractReferralServer(firstResponse)

                val finalResponse = if (referral != null) {
                    try {
                        withContext(Dispatchers.IO) {
                            queryWhoisServer(referral, target)
                        }
                    } catch (e: Exception) {
                        firstResponse + "\n\n[Warning: Failed to query referred server '$referral': ${e.message}]"
                    }
                } else {
                    firstResponse
                }

                whoisResult = finalResponse
                if (finalResponse.isBlank()) {
                    whoisError = "No registration records returned."
                }
            } catch (e: Exception) {
                whoisError = "WHOIS lookup failed: ${e.message}"
            } finally {
                isWhoisRunning = false
            }
        }
    }

    // SPEED TEST MODULE
    fun cancelSpeedTest() {
        speedTestJob?.cancel()
        speedTestJob = null
        isSpeedTestRunning = false
    }

    /**
     * HTTP download throughput test: stream [speedTestUrl] for up to ~15s (or until it ends),
     * reporting live Mbps as bytes arrive. TTFB is captured as a rough latency figure. Runs on IO;
     * cancellable. No SSH host required — this measures the phone's own link to the endpoint.
     */
    fun runSpeedTest() {
        if (isSpeedTestRunning) return
        val url = speedTestUrl.trim()
        if (url.isBlank()) { speedTestError = "Enter a download URL."; return }
        speedTestJob?.cancel()
        isSpeedTestRunning = true
        speedTestError = null
        speedTestMbps = null
        speedTestBytes = 0L
        speedTestLatencyMs = null
        speedTestJob = viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val parsed = java.net.URL(url)
                    val conn = (parsed.openConnection() as java.net.HttpURLConnection).apply {
                        connectTimeout = 8000
                        readTimeout = 8000
                        requestMethod = "GET"
                        setRequestProperty("User-Agent", "OmniTerm-SpeedTest")
                        instanceFollowRedirects = true
                    }
                    val startedAt = System.nanoTime()
                    conn.connect()
                    val ttfb = (System.nanoTime() - startedAt) / 1_000_000
                    withContext(Dispatchers.Main) { speedTestLatencyMs = ttfb }
                    val code = conn.responseCode
                    if (code !in 200..299) {
                        throw java.io.IOException("HTTP $code from server")
                    }
                    conn.inputStream.use { input ->
                        val buf = ByteArray(64 * 1024)
                        var total = 0L
                        val downloadStart = System.nanoTime()
                        val deadline = downloadStart + 15_000_000_000L  // 15s cap
                        var lastEmit = downloadStart
                        while (isActive) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            val now = System.nanoTime()
                            // Throttle UI updates to ~10/s.
                            if (now - lastEmit > 100_000_000L) {
                                lastEmit = now
                                val secs = (now - downloadStart) / 1e9
                                val mbps = if (secs > 0) (total * 8.0) / 1e6 / secs else 0.0
                                val snapshotTotal = total
                                withContext(Dispatchers.Main) {
                                    speedTestBytes = snapshotTotal
                                    speedTestMbps = mbps
                                }
                            }
                            if (now > deadline) break
                        }
                        val secs = (System.nanoTime() - downloadStart) / 1e9
                        val mbps = if (secs > 0) (total * 8.0) / 1e6 / secs else 0.0
                        val finalTotal = total
                        withContext(Dispatchers.Main) {
                            speedTestBytes = finalTotal
                            speedTestMbps = mbps
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                speedTestError = "Speed test failed: ${e.message}"
            } finally {
                isSpeedTestRunning = false
            }
        }
    }

    // APPS SETTINGS ENGINE SAVE
    fun saveThemeOption(isDark: Boolean) {
        viewModelScope.launch {
            repository.insertSetting("theme_dark", isDark.toString())
        }
    }

    fun savePinConfiguration(pin: String) {
        val stored = hashPinForStorage(pin)
        savedPin = stored
        isAppLockEnabled = true
        resetPinThrottle()
        viewModelScope.launch {
            repository.insertSetting("app_pin", stored)
            repository.insertSetting("app_lock_enabled", "true")
        }
    }

    fun saveAppLockToggle(enabled: Boolean) {
        isAppLockEnabled = enabled
        if (!enabled) {
            useBiometrics = false
            isAppLocked = false
        }
        viewModelScope.launch {
            repository.insertSetting("app_lock_enabled", enabled.toString())
            if (!enabled) {
                repository.insertSetting("biometrics_enabled", "false")
            }
        }
    }

    fun saveBiometricsToggle(enabled: Boolean) {
        viewModelScope.launch {
            val next = enabled && isAppLockEnabled && !savedPin.isNullOrBlank()
            repository.insertSetting("biometrics_enabled", next.toString())
            useBiometrics = next
        }
    }

    /** Persist and apply the auto-refresh interval (seconds, clamped 5..300). */
    fun saveTelemetryInterval(seconds: Int) {
        val s = seconds.coerceIn(5, 300)
        viewModelScope.launch {
            repository.insertSetting("telemetry_interval", s.toString())
            telemetryIntervalMs = s * 1000L
        }
    }

    fun saveRetentionSetting(days: Int) {
        viewModelScope.launch {
            repository.insertSetting("metrics_retention", days.toString())
            metricsRetentionDays = days
        }
    }

    fun saveAlertHistoryLimit(limit: Int) {
        val next = limit.coerceIn(10, 100)
        viewModelScope.launch {
            repository.insertSetting("alert_history_limit", next.toString())
            alertHistoryLimit = next
            repository.pruneAlertHistoryPerServer(next)
        }
    }

    fun saveAlertsEnabled(enabled: Boolean) {
        alertsEnabled = enabled
        viewModelScope.launch {
            repository.insertSetting("alerts_enabled", enabled.toString())
        }
    }

    fun saveFlagSecureToggle(enabled: Boolean) {
        viewModelScope.launch {
            repository.insertSetting("flag_secure", enabled.toString())
            isFlagSecureEnabled = enabled
        }
    }

    fun saveKeepScreenOnToggle(enabled: Boolean) {
        viewModelScope.launch {
            repository.insertSetting("keep_screen_on", enabled.toString())
            defaultKeepScreenOn = enabled
            isKeepScreenOnEnabled = enabled
        }
    }

    // ── Battery saver ─────────────────────────────────────────────────────────
    // When enabled and the battery drains to the threshold while unplugged, shed the app's main
    // battery costs without any new permissions: keep-screen-on released, telemetry polling paused,
    // persistent (tmux) terminals parked in their resumable state. Battery level comes from the
    // sticky ACTION_BATTERY_CHANGED broadcast, which needs no permission.
    // (State vars live above the main init block with the other settings-backed properties —
    // loadSecuritySettings() writes them synchronously during construction.)

    fun saveBatterySaverEnabled(on: Boolean) {
        batterySaverEnabled = on
        if (!on && batterySaverActive) resumeFromBatterySaver()
        viewModelScope.launch { repository.insertSetting("battery_saver_enabled", on.toString()) }
    }

    fun saveBatterySaverThreshold(pct: Int) {
        batterySaverThresholdPct = pct.coerceIn(5, 50)
        viewModelScope.launch { repository.insertSetting("battery_saver_threshold", batterySaverThresholdPct.toString()) }
    }

    private val batteryReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            val level = intent?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: return
            if (level < 0) return
            val scale = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
            val status = intent.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
            val charging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                status == android.os.BatteryManager.BATTERY_STATUS_FULL
            onBatterySample(level * 100 / scale, charging)
        }
    }

    // Registered in a late init block (below the property) so the receiver exists by then;
    // unregistered in onCleared. ACTION_BATTERY_CHANGED is a protected system broadcast, so a
    // NOT_EXPORTED context receiver still gets it.
    init {
        ContextCompat.registerReceiver(
            getApplication<Application>(),
            batteryReceiver,
            android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun onBatterySample(pct: Int, charging: Boolean) {
        if (!batterySaverEnabled) return
        if (batterySaverActive) {
            // Recover automatically once plugged in or comfortably above the threshold (+5 of
            // hysteresis so the boundary doesn't flap the saver on/off).
            if (charging || pct >= batterySaverThresholdPct + 5) resumeFromBatterySaver()
        } else if (!charging && pct <= batterySaverThresholdPct) {
            activateBatterySaver(pct)
        }
    }

    private fun activateBatterySaver(pct: Int) {
        batterySaverActive = true
        batterySaverEngagedAtPct = pct
        isKeepScreenOnEnabled = false
        // Pause the auto-refresh loop and any probes in flight.
        pollingJob?.cancel()
        activeProbes.values.forEach { it.cancel() }
        activeProbes.clear()
        // Park persistent (tmux) terminals in their resumable state — the remote session keeps
        // running and reattaches on the next connect. Non-persistent shells are left alone:
        // closing them would kill the remote shell, which is the opposite of resumable.
        activeSessions.filter { it.persistent }.map { it.id }.forEach { leaveSessionResumable(it) }
        showBatterySaverDialog = true
        postBatterySaverNotification(pct)
    }

    /** Manual or automatic exit from battery saver: restart the paused auto-refresh loop. */
    fun resumeFromBatterySaver() {
        batterySaverActive = false
        showBatterySaverDialog = false
        startTelemetryPolling()
    }

    /** Surfaces the saver engaging as a system notification, mirroring postAlertNotification. */
    private fun postBatterySaverNotification(pct: Int) {
        val app = getApplication<Application>()
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(app, android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        val nm = app.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(BATTERY_SAVER_CHANNEL_ID, "Battery saver", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val n = NotificationCompat.Builder(app, BATTERY_SAVER_CHANNEL_ID)
            .setContentTitle("OmniTerm battery saver on")
            .setContentText("Battery at $pct% — keep-screen-on released, auto-refresh paused, tmux terminals parked.")
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .build()
        nm.notify(BATTERY_SAVER_CHANNEL_ID.hashCode(), n)
    }

    fun requestKeepScreenOnToggle() {
        if (isKeepScreenOnEnabled) {
            isKeepScreenOnEnabled = false
        } else {
            showKeepScreenOnBatteryWarning = true
        }
    }

    /**
     * Toggle keep-screen-on for this session without the battery-warning follow-up. Used by the
     * terminal long-press popup, where the user has already chosen the option from an explicit menu
     * and a second confirmation dialog is redundant friction.
     */
    fun toggleKeepScreenOnDirect() {
        isKeepScreenOnEnabled = !isKeepScreenOnEnabled
    }

    fun saveDarkModeToggle(enabled: Boolean?) {
        viewModelScope.launch {
            repository.insertSetting("dark_mode", enabled?.toString() ?: "")
            isDarkModeEnabled = enabled
        }
    }

    fun saveAmoledToggle(enabled: Boolean) {
        viewModelScope.launch {
            repository.insertSetting("amoled", enabled.toString())
            isAmoledEnabled = enabled
        }
    }

    fun saveEditorHighlightLimit(limit: Int) {
        val clamped = clampHighlightLimit(limit)
        editorHighlightLimit = clamped
        viewModelScope.launch { repository.insertSetting("editor_highlight_limit", clamped.toString()) }
    }

    fun saveBackgroundKeepAliveToggle(enabled: Boolean) {
        viewModelScope.launch {
            repository.insertSetting("background_keep_alive", enabled.toString())
            isBackgroundKeepAlive = enabled
            TerminalSessionManager.isBackgroundKeepAlive = enabled
            if (enabled && activeKeepaliveSessionsCount > 0) {
                startKeepAliveService()
            } else if (!enabled) {
                stopKeepAliveService()
            }
        }
    }

    fun saveSftpLargeBatchThresholds(fileCount: Int, bytes: Long) {
        val count = fileCount.coerceIn(1, 10_000)
        val size = bytes.coerceAtLeast(1_000_000_000L)
        viewModelScope.launch {
            repository.insertSetting("sftp_large_batch_file_threshold", count.toString())
            repository.insertSetting("sftp_large_batch_bytes_threshold", size.toString())
            sftpLargeBatchFileThreshold = count
            sftpLargeBatchBytesThreshold = size
        }
    }

    fun removeSecurityPin() {
        viewModelScope.launch {
            repository.deleteSetting("app_pin")
            repository.deleteSetting("app_lock_enabled")
            repository.deleteSetting("biometrics_enabled")
            repository.deleteSetting("pin_failed_attempts")
            repository.deleteSetting("pin_locked_until")
            savedPin = null
            isAppLockEnabled = false
            useBiometrics = false
            isAppLocked = false
            failedPinAttempts = 0
            pinLockedUntilMs = 0L
        }
    }

    /** Recent real CPU% samples for the server's sparkline (collected by telemetry polling). */
    fun fetchCachedSparkline(serverId: Int): List<Float> = sparklineCache[serverId] ?: emptyList()

    // ACTIVE ALERTS CONFLICT CORRECTION
    fun acknowledgeAlert(alertId: Int) {
        viewModelScope.launch {
            repository.getActiveAlerts().find { it.id == alertId }?.let { recordAlertHistory(it, "acknowledged") }
            repository.setAcknowledged(alertId, true)
        }
    }

    fun acknowledgeAllAlerts() {
        viewModelScope.launch {
            repository.getActiveAlerts()
                .filter { !it.acknowledged && it.mutedUntil < System.currentTimeMillis() }
                .forEach { recordAlertHistory(it, "acknowledged") }
            repository.acknowledgeAll()
        }
    }

    fun muteAlertForOneHour(alertId: Int) {
        viewModelScope.launch {
            val mutedUntil = System.currentTimeMillis() + 60 * 60 * 1000
            repository.getActiveAlerts().find { it.id == alertId }?.let { recordAlertHistory(it, "muted") }
            repository.muteAlert(alertId, mutedUntil)
        }
    }

    private suspend fun recordAlertHistory(alert: ActiveAlertEntity, status: String, knownServerName: String? = null) {
        val serverName = knownServerName ?: repository.getServerById(alert.serverId)?.name ?: "server"
        repository.insertAlertHistory(
            AlertHistoryEntity(
                activeAlertId = alert.id,
                serverId = alert.serverId,
                serverName = serverName,
                metricName = alert.metricName,
                currentValue = alert.currentValue,
                thresholdValue = alert.thresholdValue,
                severity = alert.severity,
                triggeredTime = alert.triggeredTime,
                historyTime = System.currentTimeMillis(),
                status = status,
            )
        )
        repository.pruneAlertHistoryForServer(alert.serverId, alertHistoryLimit)
    }

    fun clearAlertHistory() {
        viewModelScope.launch {
            repository.clearAlertHistory()
        }
    }

    fun updateAlertRule(rule: AlertRuleEntity) {
        viewModelScope.launch {
            repository.insertRule(rule)
        }
    }

    fun deleteAlertRule(rule: AlertRuleEntity) {
        viewModelScope.launch {
            repository.deleteRule(rule)
        }
    }

    fun deleteKey(key: SshKeyEntity) {
        viewModelScope.launch {
            repository.deleteKey(key)
        }
    }

    fun deleteProfile(profile: CredentialProfileEntity) {
        viewModelScope.launch {
            repository.deleteProfile(profile)
        }
    }

    // ── ENCRYPTED BACKUP (AES-256-GCM, key derived from passphrase via PBKDF2) ──
    // Wire format (a small JSON envelope written to the chosen file):
    //   { "v":2, "compression":"gzip", "salt":..., "iv":..., "data":<ciphertext> } (all Base64).
    // Restore requires the same passphrase; a wrong passphrase fails the GCM tag check and is
    // reported honestly instead of the old always-"success".

    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int = 600_000): javax.crypto.spec.SecretKeySpec {
        val factory = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = javax.crypto.spec.PBEKeySpec(passphrase.toCharArray(), salt, iterations, 256)
        return javax.crypto.spec.SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }

    private fun buildBackupJson(
        srvs: List<ServerEntity>,
        keys: List<SshKeyEntity>,
        profiles: List<CredentialProfileEntity>,
        scripts: List<QuickScriptEntity>,
        rules: List<AlertRuleEntity>,
        alertHistories: List<AlertHistoryEntity>,
        wolTargets: List<WolTargetEntity>,
        networkShares: List<NetworkShareEntity>,
        portForwards: List<PortForwardEntity>,
        activeAlerts: List<ActiveAlertEntity>,
        settings: List<AppSettingEntity>,
        selection: BackupSelection = BackupSelection(),
    ): String {
        val closedSelection = selection.withReferentialClosure()
        val serverArr = org.json.JSONArray()
        for (s in if (closedSelection.servers) srvs else emptyList()) {
            serverArr.put(org.json.JSONObject().apply {
                // The id is exported so server-scoped records (alert rules) can be
                // re-pointed to the restored server on import.
                put("id", s.id)
                put("name", s.name); put("host", s.host); put("port", s.port)
                put("username", s.username); put("groupName", s.groupName)
                put("serverColor", s.serverColor); put("authType", s.authType)
                put("authKeyAlias", s.authKeyAlias); put("authPassword", s.authPassword)
                put("sudoPassword", s.sudoPassword)
                put("authProfileId", s.authProfileId)
                put("notes", s.notes)
                put("keepAlive", s.keepAlive); put("sshCompression", s.sshCompression)
                put("persistentSession", s.persistentSession)
                put("agentForwarding", s.agentForwarding)
                put("proxyCommand", s.proxyCommand)
                put("proxyType", s.proxyType)
                put("proxyHost", s.proxyHost)
                put("proxyPort", s.proxyPort)
                put("proxyUser", s.proxyUser)
                put("proxyPassword", s.proxyPassword)
                put("proxyKeyAlias", s.proxyKeyAlias ?: "")
            })
        }
        val keyArr = org.json.JSONArray()
        for (k in if (closedSelection.sshKeys) keys else emptyList()) {
            keyArr.put(org.json.JSONObject().apply {
                put("alias", k.alias)
                put("keyType", k.keyType)
                put("privateKey", k.privateKey)
                put("publicKey", k.publicKey)
                put("fingerprint", k.fingerprint)
            })
        }
        val profileArr = org.json.JSONArray()
        for (p in if (closedSelection.credentialProfiles) profiles else emptyList()) {
            profileArr.put(org.json.JSONObject().apply {
                put("id", p.id)
                put("profileName", p.profileName)
                put("username", p.username)
                put("authType", p.authType)
                put("password", p.password)
                put("keyAlias", p.keyAlias)
                put("groupName", p.groupName)
            })
        }
        val scriptArr = org.json.JSONArray()
        // Back up only user-created or user-edited scripts. Pristine seeded presets (built-in Fleet
        // presets, homelab presets that still match their original command) are skipped — a fresh
        // install re-seeds those on its own, so exporting them would just duplicate defaults on restore.
        val scriptsForBackup = if (closedSelection.scripts) customScriptsOnly(scripts) else emptyList()
        for (q in scriptsForBackup) {
            scriptArr.put(org.json.JSONObject().apply {
                put("emoji", q.emoji); put("name", q.name); put("command", q.command)
                put("color", q.color); put("longRunning", q.longRunning)
                put("category", q.category); put("sortOrder", q.sortOrder)
                put("availableForQuick", q.availableForQuick)
                put("availableForFleet", q.availableForFleet)
                put("targetOs", q.targetOs)
                put("targetSystem", q.targetSystem)
                put("notes", q.notes)
            })
        }
        val ruleArr = org.json.JSONArray()
        // Skip the pristine fleet-wide default alert presets (CPU/Mem/Disk/Latency); keep custom and
        // edited rules. A pristine default referenced by an exported active alert is the exception:
        // include it so the alert's old rule id can be mapped to the seeded/restored rule on import.
        val customRules = customRulesOnly(rules)
        val exportedServerIds = srvs.mapTo(mutableSetOf()) { it.id }
        val ruleIdsForBackup = backupRuleIdsForSelection(
            customRuleIds = customRules.mapTo(mutableSetOf()) { it.id },
            activeAlertRuleIds = activeAlerts
                .filter { it.serverId == 0 || it.serverId in exportedServerIds }
                .mapTo(mutableSetOf()) { it.ruleId },
            selection = closedSelection,
        )
        val rulesForBackup = rules.filter {
            it.id in ruleIdsForBackup && (it.serverId == 0 || it.serverId in exportedServerIds)
        }
        val exportedRuleIds = rulesForBackup.mapTo(mutableSetOf()) { it.id }
        for (r in rulesForBackup) {
            ruleArr.put(org.json.JSONObject().apply {
                put("id", r.id); put("serverId", r.serverId); put("metricName", r.metricName)
                put("mountPoint", r.mountPoint); put("thresholdValue", r.thresholdValue.toDouble())
                put("severity", r.severity); put("triggerWindow", r.triggerWindow); put("enabled", r.enabled)
                put("notes", r.notes)
            })
        }
        val historyArr = org.json.JSONArray()
        val historyForBackup = if (closedSelection.alertHistory) {
            alertHistories.filter { it.serverId == 0 || it.serverId in exportedServerIds }
        } else emptyList()
        for (h in historyForBackup) {
            historyArr.put(org.json.JSONObject().apply {
                put("activeAlertId", h.activeAlertId)
                put("serverId", h.serverId)
                put("serverName", h.serverName)
                put("metricName", h.metricName)
                put("currentValue", h.currentValue.toDouble())
                put("thresholdValue", h.thresholdValue.toDouble())
                put("severity", h.severity)
                put("triggeredTime", h.triggeredTime)
                put("historyTime", h.historyTime)
                put("status", h.status)
            })
        }
        val wolArr = org.json.JSONArray()
        for (w in if (closedSelection.wolTargets) wolTargets else emptyList()) {
            wolArr.put(org.json.JSONObject().apply {
                put("name", w.name); put("macAddress", w.macAddress); put("broadcastIp", w.broadcastIp)
                put("ipAddress", w.ipAddress)
                put("port", w.port); put("notes", w.notes)
                put("lastWokenTime", w.lastWokenTime)
            })
        }
        val networkShareArr = org.json.JSONArray()
        for (share in if (closedSelection.networkShares) networkShares else emptyList()) {
            networkShareArr.put(org.json.JSONObject().apply {
                // The id is only used at restore time to re-point per-share settings
                // (share_bookmarks_{id}) at the newly inserted row.
                put("id", share.id)
                put("name", share.name)
                put("protocol", share.protocol)
                put("address", share.address)
                put("port", share.port)
                put("sharePath", share.sharePath)
                put("workgroup", share.workgroup)
                put("username", share.username)
                put("password", share.password)
                put("authProfileId", share.authProfileId)
                put("anonymous", share.anonymous)
                put("useHttps", share.useHttps)
                put("notes", share.notes)
                put("lastChecked", share.lastChecked)
                put("lastStatus", share.lastStatus)
            })
        }
        val activeAlertArr = org.json.JSONArray()
        val activeAlertsForBackup = if (closedSelection.activeAlerts) {
            activeAlerts.filter { alert ->
                alert.ruleId in exportedRuleIds && (alert.serverId == 0 || alert.serverId in exportedServerIds)
            }
        } else emptyList()
        for (a in activeAlertsForBackup) {
            activeAlertArr.put(org.json.JSONObject().apply {
                put("id", a.id)
                put("ruleId", a.ruleId); put("serverId", a.serverId); put("metricName", a.metricName)
                put("currentValue", a.currentValue.toDouble()); put("thresholdValue", a.thresholdValue.toDouble())
                put("severity", a.severity); put("triggeredTime", a.triggeredTime)
                put("acknowledged", a.acknowledged); put("mutedUntil", a.mutedUntil)
            })
        }
        val portForwardArr = org.json.JSONArray()
        val portForwardsForBackup = if (closedSelection.portForwards) {
            portForwards.filter { it.serverId in exportedServerIds }
        } else emptyList()
        for (tunnel in portForwardsForBackup) {
            portForwardArr.put(org.json.JSONObject().apply {
                put("id", tunnel.id)
                put("serverId", tunnel.serverId)
                put("name", tunnel.name)
                put("kind", tunnel.kind)
                put("bindHost", tunnel.bindHost)
                put("bindPort", tunnel.bindPort)
                put("destHost", tunnel.destHost)
                put("destPort", tunnel.destPort)
                put("autoStart", tunnel.autoStart)
            })
        }
        val settingsObj = org.json.JSONObject()
        // Never back up device-local security settings (PIN, lock, biometrics) — they shouldn't
        // travel between devices. Everything else (theme, retention, scoring, interval, …) is kept.
        val securityKeys = setOf(
            "app_pin", "app_lock_enabled", "biometrics_enabled",
            "pin_failed_attempts", "pin_locked_until",
        )
        if (closedSelection.settings) {
            for (st in settings) {
                if (st.key in securityKeys || st.key.startsWith("sftp_last_path_")) continue
                settingsObj.put(st.key, st.value)
            }
        }

        // Pinned SSH host keys ride along with the servers they belong to, so a restored fleet
        // keeps its verified trust store instead of re-prompting TOFU for every host.
        val knownHostsObj = org.json.JSONObject()
        if (closedSelection.servers) {
            SshHostKeyTrust.exportEntries().forEach { (key, value) -> knownHostsObj.put(key, value) }
        }

        // Opt-in crash logs (device/build-specific diagnostics). Preserved across a same-device
        // reinstall when the user explicitly selects them.
        val crashArr = org.json.JSONArray()
        if (closedSelection.crashLogs) {
            CrashLog.all(getApplication()).forEach { entry ->
                crashArr.put(org.json.JSONObject().put("t", entry.timeMs).put("r", entry.report))
            }
        }

        return org.json.JSONObject()
            .put("format", "omniterm-backup")
            .put("schema", BACKUP_SCHEMA_VERSION)
            .put("knownHosts", knownHostsObj)
            .put("servers", serverArr)
            .put("sshKeys", keyArr)
            .put("credentialProfiles", profileArr)
            .put("quickScripts", scriptArr)
            .put("alertRules", ruleArr)
            .put("activeAlerts", activeAlertArr)
            .put("alertHistory", historyArr)
            .put("wolTargets", wolArr)
            .put("networkShares", networkShareArr)
            .put("portForwards", portForwardArr)
            .put("settings", settingsObj)
            .put("crashLogs", crashArr)
            .toString()
    }

    private fun backupSettingsSnapshot(existing: List<AppSettingEntity>): List<AppSettingEntity> {
        val merged = existing.associateBy { it.key }.toMutableMap()
        fun put(key: String, value: String) {
            merged[key] = AppSettingEntity(key, value)
        }

        put("alerts_enabled", alertsEnabled.toString())
        put("alert_presets", alertPresetsEnabled.toString())
        put("alert_history_limit", alertHistoryLimit.toString())
        put("homelab_presets", homelabPresetsEnabled.toString())
        put("fleet_presets", fleetPresetsEnabled.toString())
        put("backup_export_selection", backupExportSelection.encode())
        put("terminal_font_size", terminalFontSize.toString())
        put("terminal_theme", terminalTheme)
        put("terminal_scrollback_limit", terminalScrollbackLimit.toString())
        put("terminal_smart_swipe", smartSwipeInput.toString())
        put("terminal_link_detection", terminalLinkDetection.toString())
        put("link_open_in_app", linkOpenInApp.toString())
        put("tmux_control_mode", tmuxControlMode.toString())
        put("text_scale", textScale)
        put("accessibility", isAccessibilityEnabled.toString())
        put("amoled", isAmoledEnabled.toString())
        put("sftp_sort", sftpSortOption.name)
        put("editor_highlight_limit", editorHighlightLimit.toString())
        put("health_scoring", healthConfig.encode())
        put("telemetry_interval", (telemetryIntervalMs / 1000L).coerceIn(5L, 300L).toString())
        put("metrics_retention", metricsRetentionDays.toString())
        put("keep_screen_on", defaultKeepScreenOn.toString())
        put("dark_mode", isDarkModeEnabled?.toString() ?: "")
        put("background_keep_alive", isBackgroundKeepAlive.toString())
        put("battery_saver_enabled", batterySaverEnabled.toString())
        put("battery_saver_threshold", batterySaverThresholdPct.toString())
        // The lock grace is a preference, not a secret: it travels, but the PIN/lock/biometric
        // keys stay device-local, so a restored grace sits unread until a lock is set up here.
        put("app_lock_grace_ms", appLockGraceMs.toString())
        put("sftp_large_batch_file_threshold", sftpLargeBatchFileThreshold.toString())
        put("sftp_large_batch_bytes_threshold", sftpLargeBatchBytesThreshold.toString())
        put("backup_last_export_time", lastBackupExportTime.toString())

        return merged.values.sortedBy { it.key }
    }

    private fun gzip(bytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        java.util.zip.GZIPOutputStream(out).use { it.write(bytes) }
        return out.toByteArray()
    }

    private fun gunzip(bytes: ByteArray): ByteArray {
        return gunzipBackupBounded(bytes)
    }

    private fun encryptBackupJson(json: String, passphrase: String): String {
        val plain = gzip(json.toByteArray(Charsets.UTF_8))
        val salt = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, deriveKey(passphrase, salt, 600_000), javax.crypto.spec.GCMParameterSpec(128, iv))
        val ct = cipher.doFinal(plain)
        val b64 = android.util.Base64.NO_WRAP
        return org.json.JSONObject().apply {
            put("v", 2)
            put("compression", "gzip")
            put("kdf", "PBKDF2WithHmacSHA256")
            put("iterations", 600_000)
            put("salt", android.util.Base64.encodeToString(salt, b64))
            put("iv", android.util.Base64.encodeToString(iv, b64))
            put("data", android.util.Base64.encodeToString(ct, b64))
        }.toString()
    }

    private fun decryptBackupToJson(backupText: String, passphrase: String): String {
        require(backupText.length <= BACKUP_MAX_INPUT_CHARS) { "Backup file is too large." }
        validateBackupJsonNesting(backupText)
        val env = org.json.JSONObject(backupText)
        val envelopeFields = listOf("salt", "iv", "data")
        val envelopeFieldCount = envelopeFields.count(env::has)
        if (envelopeFieldCount == 0) return backupText
        require(envelopeFieldCount == envelopeFields.size) { "Encrypted backup envelope is incomplete." }
        require(env.optInt("v", -1) == 2) { "Unsupported encrypted backup version." }
        require(env.optString("kdf") == "PBKDF2WithHmacSHA256") { "Unsupported backup key derivation." }
        require(env.optString("compression") == "gzip") { "Unsupported backup compression." }
        require(env.getString("data").length <= BACKUP_MAX_INPUT_CHARS) { "Encrypted backup data is too large." }
        val b64 = android.util.Base64.NO_WRAP
        val salt = android.util.Base64.decode(env.getString("salt"), b64)
        val iv = android.util.Base64.decode(env.getString("iv"), b64)
        val ct = android.util.Base64.decode(env.getString("data"), b64)
        val iterations = env.optInt("iterations", -1)
        validateBackupCryptoParameters(iterations, salt.size, iv.size, ct.size)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, deriveKey(passphrase, salt, iterations), javax.crypto.spec.GCMParameterSpec(128, iv))
        val decrypted = cipher.doFinal(ct)
        return String(gunzip(decrypted), Charsets.UTF_8).also(::validateBackupJsonNesting)
    }

    private fun validateBackupRoot(root: org.json.JSONObject) {
        require(root.optString("format") == "omniterm-backup") { "Not an OmniTerm backup file." }
        val schema = root.optInt("schema", -1)
        require(schema in 1..BACKUP_SCHEMA_VERSION) {
            if (schema > BACKUP_SCHEMA_VERSION) "Backup schema is newer than this app supports."
            else "Backup schema is missing or invalid."
        }
        val arrays = listOf(
            "servers", "sshKeys", "credentialProfiles", "quickScripts", "alertRules",
            "activeAlerts", "alertHistory", "wolTargets", "networkShares", "portForwards",
            "crashLogs",
        )
        arrays.forEach { name ->
            require((root.optJSONArray(name)?.length() ?: 0) <= BACKUP_MAX_COLLECTION_ITEMS) {
                "Backup contains too many $name entries."
            }
        }
        require((root.optJSONObject("settings")?.length() ?: 0) <= BACKUP_MAX_COLLECTION_ITEMS) {
            "Backup contains too many settings."
        }
        validateBackupJsonValues(root)
    }

    private fun validateBackupJsonValues(value: Any?, depth: Int = 0) {
        require(depth <= BACKUP_MAX_JSON_DEPTH) { "Backup JSON is nested too deeply." }
        when (value) {
            is org.json.JSONObject -> value.keys().forEach { key ->
                require(key.length <= BACKUP_MAX_KEY_CHARS) { "Backup contains an oversized field name." }
                validateBackupJsonValues(value.opt(key), depth + 1)
            }
            is org.json.JSONArray -> {
                require(value.length() <= BACKUP_MAX_COLLECTION_ITEMS) { "Backup contains an oversized array." }
                for (index in 0 until value.length()) validateBackupJsonValues(value.opt(index), depth + 1)
            }
            is String -> require(value.length <= BACKUP_MAX_FIELD_CHARS) { "Backup contains an oversized text field." }
        }
    }

    fun backupNeedsPassword(backupText: String): Boolean = try {
        val root = org.json.JSONObject(backupText)
        root.has("salt") && root.has("iv") && root.has("data")
    } catch (_: Exception) {
        false
    }

    private fun backupContents(root: org.json.JSONObject): BackupContents {
        val settingsObj = root.optJSONObject("settings")
        return BackupContents(
            servers = root.optJSONArray("servers")?.length() ?: 0,
            sshKeys = root.optJSONArray("sshKeys")?.length() ?: 0,
            credentialProfiles = root.optJSONArray("credentialProfiles")?.length() ?: 0,
            scripts = root.optJSONArray("quickScripts")?.length() ?: 0,
            alertRules = root.optJSONArray("alertRules")?.length() ?: 0,
            activeAlerts = root.optJSONArray("activeAlerts")?.length() ?: 0,
            alertHistory = root.optJSONArray("alertHistory")?.length() ?: 0,
            wolTargets = root.optJSONArray("wolTargets")?.length() ?: 0,
            networkShares = root.optJSONArray("networkShares")?.length() ?: 0,
            portForwards = root.optJSONArray("portForwards")?.length() ?: 0,
            settings = settingsObj?.length() ?: 0,
            crashLogs = root.optJSONArray("crashLogs")?.length() ?: 0,
        )
    }

    private fun backupHosts(root: org.json.JSONObject): List<BackupHostOption> {
        val arr = root.optJSONArray("servers") ?: return emptyList()
        return buildList {
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                add(
                    BackupHostOption(
                        oldId = o.optInt("id", 0).takeIf { it != 0 } ?: (i + 1),
                        name = o.optString("name", "Host ${i + 1}"),
                        host = o.optString("host"),
                        port = o.optInt("port", 22),
                    )
                )
            }
        }
    }

    fun inspectBackupContents(backupText: String, passphrase: String, onResult: (Boolean, BackupContents?, String) -> Unit) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val plain = decryptBackupToJson(backupText, passphrase)
                    val root = org.json.JSONObject(plain)
                    validateBackupRoot(root)
                    Triple(true, backupContents(root), "")
                } catch (e: javax.crypto.AEADBadTagException) {
                    Triple(false, null, "Wrong passphrase or corrupted backup.")
                } catch (e: Exception) {
                    Triple(false, null, e.message ?: "Could not read backup.")
                }
            }
            onResult(result.first, result.second, result.third)
        }
    }

    fun inspectBackupHosts(backupText: String, passphrase: String, onResult: (Boolean, List<BackupHostOption>, String) -> Unit) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val plain = decryptBackupToJson(backupText, passphrase)
                    val root = org.json.JSONObject(plain)
                    validateBackupRoot(root)
                    Triple(true, backupHosts(root), "")
                } catch (e: javax.crypto.AEADBadTagException) {
                    Triple(false, emptyList<BackupHostOption>(), "Wrong passphrase or corrupted backup.")
                } catch (e: Exception) {
                    Triple(false, emptyList<BackupHostOption>(), e.message ?: "Could not read backup.")
                }
            }
            onResult(result.first, result.second, result.third)
        }
    }

    /** Export a selective backup. Sensitive selections are always encrypted. */
    fun exportBackup(uri: android.net.Uri, passphrase: String, context: android.content.Context, selection: BackupSelection, onResult: (Boolean, String) -> Unit) {
        val closedSelection = selection.withReferentialClosure()
        if (closedSelection.hasSensitiveData() && passphrase.length < 12) { onResult(false, "Passphrase must be at least 12 characters for backups."); return }
        viewModelScope.launch {
            val srvs = repository.getAllServers()
            val keys = repository.getAllKeys()
            val profiles = repository.getAllProfiles()
            val scripts = repository.getAllScripts()
            val rules = repository.getAllRules()
            val alertHistories = repository.getAlertHistory()
            val wolTargets = repository.getAllWolTargets()
            val networkShares = repository.getAllNetworkShares()
            val portForwards = repository.getAllPortForwards()
            val activeAlerts = repository.getActiveAlerts()
            val settings = backupSettingsSnapshot(repository.getAllSettings())
            // Counts shown in the result toast must match what buildBackupJson actually writes.
            // Pristine default rules are filtered unless a selected active alert references them.
            val scriptsForCount = customScriptsOnly(scripts)
            val customRules = customRulesOnly(rules)
            val serverIdsForCount = srvs.mapTo(mutableSetOf()) { it.id }
            val ruleIdsForCount = backupRuleIdsForSelection(
                customRuleIds = customRules.mapTo(mutableSetOf()) { it.id },
                activeAlertRuleIds = activeAlerts
                    .filter { it.serverId == 0 || it.serverId in serverIdsForCount }
                    .mapTo(mutableSetOf()) { it.ruleId },
                selection = closedSelection,
            )
            val rulesForCount = rules.count {
                it.id in ruleIdsForCount && (it.serverId == 0 || it.serverId in serverIdsForCount)
            }
            val historyForCount = alertHistories.count {
                it.serverId == 0 || it.serverId in serverIdsForCount
            }
            val portForwardsForCount = portForwards.count { it.serverId in serverIdsForCount }
            val encrypted = closedSelection.hasSensitiveData()
            val ok = withContext(Dispatchers.IO) {
                try {
                    val json = buildBackupJson(
                        srvs, keys, profiles, scripts, rules, alertHistories, wolTargets,
                        networkShares, portForwards, activeAlerts, settings, closedSelection
                    )
                    val payload = if (encrypted) encryptBackupJson(json, passphrase) else json
                    context.contentResolver.openOutputStream(uri)?.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                        ?: return@withContext false
                    true
                } catch (e: Exception) {
                    android.util.Log.w("AppViewModel", "Backup export failed", e)
                    false
                }
            }
            val mode = if (encrypted) "Encrypted" else "Plain"
            if (ok) {
                val now = System.currentTimeMillis()
                lastBackupExportTime = now
                repository.insertSetting("backup_last_export_time", now.toString())
            }
            onResult(ok, if (ok) "$mode backup written: ${if (closedSelection.servers) srvs.size else 0} servers, ${if (closedSelection.sshKeys) keys.size else 0} keys, ${if (closedSelection.credentialProfiles) profiles.size else 0} profiles, ${if (closedSelection.scripts) scriptsForCount.size else 0} scripts, ${if (closedSelection.alertRules) rulesForCount else 0} rules, ${if (closedSelection.alertHistory) historyForCount else 0} alert history, ${if (closedSelection.wolTargets) wolTargets.size else 0} WoL, ${if (closedSelection.networkShares) networkShares.size else 0} shares, ${if (closedSelection.portForwards) portForwardsForCount else 0} tunnels, ${if (closedSelection.settings) settings.size else 0} settings." else "Export failed.")
        }
    }

    /** Export an encrypted backup to [uri]. [onResult] gets (success, message). */
    fun exportEncryptedBackup(uri: android.net.Uri, passphrase: String, context: android.content.Context, onResult: (Boolean, String) -> Unit) {
        exportBackup(uri, passphrase, context, BackupSelection(), onResult)
    }

    /** Restore from encrypted backup text. [onResult] gets (success, message). */
    fun restoreEncryptedBackup(
        envelopeText: String,
        passphrase: String,
        selection: BackupSelection = BackupSelection(),
        selectedBackupServerIds: Set<Int>? = null,
        onResult: (Boolean, String) -> Unit,
    ) {
        val closedSelection = selection.withReferentialClosure()
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                backupRestoreMutex.withLock {
                try {
                    val plain = decryptBackupToJson(envelopeText, passphrase)
                    val root = org.json.JSONObject(plain)
                    validateBackupRoot(root)
                    val knownHostsBefore = SshHostKeyTrust.exportEntries()
                    val crashLogsBefore = CrashLog.all(getApplication())
                    try {
                    repository.inTransaction {
                    fun serverSelected(o: org.json.JSONObject, index: Int): Boolean {
                        if (selectedBackupServerIds == null) return true
                        val oldId = o.optInt("id", 0).takeIf { it != 0 } ?: (index + 1)
                        return oldId in selectedBackupServerIds
                    }
                    fun sameServerEndpoint(existing: ServerEntity, backup: org.json.JSONObject): Boolean =
                        existing.host.equals(backup.optString("host"), ignoreCase = true) &&
                            existing.port == backup.optInt("port", 22) &&
                            existing.username == backup.optString("username")

                    val allowedKeyAliases = mutableSetOf<String>()
                    val allowedProfileOldIds = mutableSetOf<Int>()
                    if (closedSelection.servers) {
                        val arr = root.optJSONArray("servers") ?: org.json.JSONArray()
                        var availableHostSlots = (hostLimit - repository.getAllServers().size).coerceAtLeast(0)
                        for (i in 0 until arr.length()) {
                            val o = arr.getJSONObject(i)
                            if (!serverSelected(o, i)) continue
                            val nm = o.getString("name")
                            val existingNamedServer = repository.getServerByName(nm)
                            if (existingNamedServer != null) {
                                require(sameServerEndpoint(existingNamedServer, o)) {
                                    "Host name '$nm' already belongs to a different endpoint; rename one host before restoring."
                                }
                                allowedKeyAliases.add(o.optString("authKeyAlias"))
                                allowedKeyAliases.add(o.optString("proxyKeyAlias"))
                                allowedProfileOldIds.add(o.optInt("authProfileId", 0))
                                continue
                            }
                            if (availableHostSlots > 0) {
                                availableHostSlots--
                                allowedKeyAliases.add(o.optString("authKeyAlias"))
                                allowedKeyAliases.add(o.optString("proxyKeyAlias"))
                                allowedProfileOldIds.add(o.optInt("authProfileId", 0))
                            }
                        }
                    }
                    if (closedSelection.networkShares) {
                        val shareArr = root.optJSONArray("networkShares") ?: org.json.JSONArray()
                        for (i in 0 until shareArr.length()) {
                            val profileId = shareArr.getJSONObject(i).optInt("authProfileId", 0)
                            if (profileId != 0) allowedProfileOldIds.add(profileId)
                        }
                    }
                    val profileArr = root.optJSONArray("credentialProfiles") ?: org.json.JSONArray()
                    for (i in 0 until profileArr.length()) {
                        val profile = profileArr.getJSONObject(i)
                        val oldId = profile.optInt("id", 0)
                        if ((closedSelection.servers || closedSelection.networkShares) && oldId !in allowedProfileOldIds) continue
                        allowedKeyAliases.add(profile.optString("keyAlias"))
                    }
                    allowedKeyAliases.remove("")

                    val existingKeys = repository.getAllKeys().map { it.alias }.toMutableSet()
                    val existingProfiles = repository.getAllProfiles().associateBy { it.profileName }.toMutableMap()
                    var availableCredSlots = (credentialProfileLimit - existingProfiles.size - existingKeys.size).coerceAtLeast(0)

                    val keyArr = root.optJSONArray("sshKeys") ?: org.json.JSONArray()
                    var importedKeys = 0
                    var skippedKeysByLimit = 0
                    for (i in 0 until if (closedSelection.sshKeys) keyArr.length() else 0) {
                        val o = keyArr.getJSONObject(i)
                        val alias = o.getString("alias")
                        if ((closedSelection.servers || closedSelection.networkShares) && alias !in allowedKeyAliases) continue
                        if (alias in existingKeys) continue
                        if (availableCredSlots <= 0) {
                            skippedKeysByLimit++
                            continue
                        }
                        repository.insertKey(
                            SshKeyEntity(
                                alias = alias,
                                keyType = o.optString("keyType", "RSA"),
                                privateKey = o.optString("privateKey"),
                                publicKey = o.optString("publicKey"),
                                fingerprint = o.optString("fingerprint").ifBlank {
                                    o.optString("publicKey").takeIf { it.startsWith("ssh-") }?.let { sshPublicKeyFingerprint(it) }
                                        ?: keyMaterialFingerprint(o.optString("privateKey"))
                                },
                            )
                        )
                        existingKeys.add(alias)
                        importedKeys++
                        availableCredSlots--
                    }

                    val profileIdMap = mutableMapOf<Int, Int>()
                    var importedProfiles = 0
                    var skippedProfilesByLimit = 0
                    for (i in 0 until if (closedSelection.credentialProfiles) profileArr.length() else 0) {
                        val o = profileArr.getJSONObject(i)
                        val name = o.getString("profileName")
                        val oldId = o.optInt("id", 0)
                        if ((closedSelection.servers || closedSelection.networkShares) && oldId != 0 && !allowedProfileOldIds.contains(oldId)) continue
                        val existing = existingProfiles[name]
                        if (existing != null) {
                            require(
                                existing.username == o.optString("username") &&
                                    existing.authType == o.optString("authType", "password") &&
                                    existing.keyAlias == jsonNullableString(o, "keyAlias") &&
                                    existing.password == jsonNullableString(o, "password")
                            ) {
                                "Credential profile '$name' already exists with different credentials."
                            }
                            if (oldId != 0) profileIdMap[oldId] = existing.id
                            continue
                        }
                        if (availableCredSlots <= 0) {
                            skippedProfilesByLimit++
                            continue
                        }
                        val profile = CredentialProfileEntity(
                            profileName = name,
                            username = o.optString("username"),
                            authType = o.optString("authType", "password"),
                            password = jsonNullableString(o, "password"),
                            keyAlias = jsonNullableString(o, "keyAlias"),
                            groupName = o.optString("groupName", "General").ifBlank { "General" },
                        )
                        val newId = repository.insertProfile(
                            profile
                        ).toInt()
                        if (oldId != 0) profileIdMap[oldId] = newId
                        existingProfiles[name] = profile.copy(id = newId)
                        importedProfiles++
                        availableCredSlots--
                    }

                    val arr = root.optJSONArray("servers") ?: org.json.JSONArray()
                    // Maps backup server ids to restored ids so server-scoped records (alert rules,
                    // backup jobs) can be re-pointed even when the local ids differ.
                    val serverIdMap = mutableMapOf<Int, Int>()
                    // Hosts whose servers were actually restored or already present locally — their
                    // pinned trust keys may be imported. Hosts skipped by the limit are excluded so
                    // restore never leaves orphaned trust entries for servers that don't exist.
                    val restoredHosts = mutableSetOf<Pair<String, Int>>()
                    var imported = 0
                    var skippedServersByLimit = 0
                    var availableHostSlots = (hostLimit - repository.getAllServers().size).coerceAtLeast(0)
                    for (i in 0 until arr.length()) {
                        val o = arr.getJSONObject(i)
                        if (!serverSelected(o, i)) continue
                        val nm = o.getString("name")
                        val oldId = o.optInt("id", 0)
                        val existing = repository.getServerByName(nm)
                        if (existing != null) {
                            require(sameServerEndpoint(existing, o)) {
                                "Host name '$nm' already belongs to a different endpoint; rename one host before restoring."
                            }
                            if (oldId != 0) serverIdMap[oldId] = existing.id
                            restoredHosts.add(existing.host to existing.port)
                            continue
                        }
                        if (!closedSelection.servers) continue
                        if (availableHostSlots <= 0) {
                            skippedServersByLimit++
                            continue
                        }
                        val oldProfileId = if (o.has("authProfileId") && !o.isNull("authProfileId")) o.optInt("authProfileId") else 0
                        val newId = repository.insertServer(
                            ServerEntity(
                                name = nm, host = o.getString("host"), port = o.optInt("port", 22),
                                username = o.optString("username"), groupName = o.optString("groupName", "Default"),
                                serverColor = o.optString("serverColor", "Default"), authType = o.optString("authType", "password"),
                                authKeyAlias = jsonNullableString(o, "authKeyAlias"),
                                authPassword = jsonNullableString(o, "authPassword"),
                                sudoPassword = o.optString("sudoPassword", ""),
                                authProfileId = profileIdMap[oldProfileId],
                                notes = o.optString("notes", ""), keepAlive = o.optInt("keepAlive", 30),
                                sshCompression = o.optBoolean("sshCompression", false),
                                persistentSession = o.optBoolean("persistentSession", false),
                                agentForwarding = o.optBoolean("agentForwarding", false),
                                proxyCommand = o.optString("proxyCommand", ""),
                                proxyType = o.optString("proxyType", "none"),
                                proxyHost = o.optString("proxyHost", ""),
                                proxyPort = o.optInt("proxyPort", 0),
                                proxyUser = o.optString("proxyUser", ""),
                                proxyPassword = o.optString("proxyPassword", ""),
                                proxyKeyAlias = o.optString("proxyKeyAlias", "").takeIf { it.isNotBlank() },
                                status = "offline",
                            )
                        ).toInt()
                        if (oldId != 0) serverIdMap[oldId] = newId
                        restoredHosts.add(o.getString("host") to o.optInt("port", 22))
                        imported++
                        availableHostSlots--
                    }

                    // Pinned host keys travel with the servers (schema 3+). Only import keys for
                    // hosts actually restored (or already present) so a limited restore doesn't
                    // leave orphaned trust entries for skipped hosts. Existing pins still win, so a
                    // backup can never overwrite a key this device already verified.
                    var skippedHostKeysByLimit = 0
                    if (closedSelection.servers) {
                        root.optJSONObject("knownHosts")?.let { kh ->
                            val entries = mutableMapOf<String, String>()
                            kh.keys().forEach { k -> entries[k] = kh.optString(k) }
                            val kept = SshHostKeyTrust.filterEntriesForHosts(entries, restoredHosts)
                            skippedHostKeysByLimit = entries.size - kept.size
                            SshHostKeyTrust.importEntries(kept)
                        }
                    }

                    // Quick scripts (dedup by category + name).
                    val existingScripts = repository.getAllScripts()
                        .map { it.category to it.name }
                        .toMutableSet()
                    val scriptArr = root.optJSONArray("quickScripts") ?: org.json.JSONArray()
                    var importedScripts = 0
                    for (i in 0 until if (closedSelection.scripts) scriptArr.length() else 0) {
                        val o = scriptArr.getJSONObject(i)
                        val name = o.optString("name")
                        val category = o.optString("category", "General").ifBlank { "General" }
                        val scriptKey = category to name
                        if (name.isBlank() || scriptKey in existingScripts) continue
                        repository.insertScript(
                            QuickScriptEntity(
                                emoji = o.optString("emoji", "LIN"), name = name, command = o.optString("command"),
                                color = o.optString("color", "cyan"), longRunning = o.optBoolean("longRunning", false),
                                category = category, sortOrder = o.optInt("sortOrder", 0),
                                availableForQuick = o.optBoolean("availableForQuick", category != "Fleet"),
                                availableForFleet = o.optBoolean("availableForFleet", category == "Fleet"),
                                targetOs = o.optString("targetOs", "Any").ifBlank { "Any" },
                                targetSystem = o.optString("targetSystem", "Any").ifBlank { "Any" },
                                notes = o.optString("notes", ""),
                            )
                        )
                        existingScripts.add(scriptKey)
                        importedScripts++
                    }

                    // Alert rules (re-point serverId; dedup by server+metric+threshold+window).
                    val existingRuleKeys = repository.getAllRules()
                        .map { "${it.serverId}|${it.metricName}|${it.thresholdValue}|${it.triggerWindow}" }.toMutableSet()
                    val ruleArr = root.optJSONArray("alertRules") ?: org.json.JSONArray()
                    val ruleIdMap = mutableMapOf<Int, Int>()
                    var importedRules = 0
                    for (i in 0 until if (closedSelection.alertRules) ruleArr.length() else 0) {
                        val o = ruleArr.getJSONObject(i)
                        val oldRuleId = o.optInt("id", 0)
                        val oldServerId = o.optInt("serverId", 0)
                        val mappedServerId = remapBackupServerId(oldServerId, serverIdMap) ?: continue
                        val threshold = o.optDouble("thresholdValue", 0.0).toFloat()
                        val window = o.optString("triggerWindow", "5m")
                        val metric = o.optString("metricName")
                        val key = "$mappedServerId|$metric|$threshold|$window"
                        if (key in existingRuleKeys) {
                            if (oldRuleId != 0) {
                                repository.getAllRules().find {
                                    it.serverId == mappedServerId && it.metricName == metric && it.thresholdValue == threshold && it.triggerWindow == window
                                }?.let { ruleIdMap[oldRuleId] = it.id }
                            }
                            continue
                        }
                        repository.insertRule(
                            AlertRuleEntity(
                                serverId = mappedServerId, metricName = metric,
                                mountPoint = o.optString("mountPoint", "/"), thresholdValue = threshold,
                                severity = o.optString("severity", "WARNING"), triggerWindow = window,
                                enabled = o.optBoolean("enabled", true),
                                notes = o.optString("notes", ""),
                            )
                        )
                        repository.getAllRules().find {
                            it.serverId == mappedServerId && it.metricName == metric && it.thresholdValue == threshold && it.triggerWindow == window
                        }?.let { restoredRule ->
                            if (oldRuleId != 0) ruleIdMap[oldRuleId] = restoredRule.id
                        }
                        existingRuleKeys.add(key)
                        importedRules++
                    }

                    val existingActiveAlertsByKey = repository.getActiveAlerts()
                        .associateBy { "${it.ruleId}|${it.serverId}|${it.metricName}" }.toMutableMap()
                    val activeAlertIdMap = mutableMapOf<Int, Int>()
                    val activeAlertArr = root.optJSONArray("activeAlerts") ?: org.json.JSONArray()
                    var importedActiveAlerts = 0
                    for (i in 0 until if (closedSelection.activeAlerts) activeAlertArr.length() else 0) {
                        val o = activeAlertArr.getJSONObject(i)
                        val oldActiveAlertId = o.optInt("id", 0)
                        val oldServerId = o.optInt("serverId", 0)
                        val mappedServerId = remapBackupServerId(oldServerId, serverIdMap) ?: continue
                        val mappedRuleId = ruleIdMap[o.optInt("ruleId", 0)] ?: continue
                        val metric = o.optString("metricName")
                        val key = "$mappedRuleId|$mappedServerId|$metric"
                        val existingAlert = existingActiveAlertsByKey[key]
                        if (existingAlert != null) {
                            if (oldActiveAlertId > 0) activeAlertIdMap[oldActiveAlertId] = existingAlert.id
                            continue
                        }
                        val restoredAlert = ActiveAlertEntity(
                                ruleId = mappedRuleId, serverId = mappedServerId, metricName = metric,
                                currentValue = o.optDouble("currentValue", 0.0).toFloat(),
                                thresholdValue = o.optDouble("thresholdValue", 0.0).toFloat(),
                                severity = o.optString("severity", "WARNING"),
                                triggeredTime = o.optLong("triggeredTime", System.currentTimeMillis()),
                                acknowledged = o.optBoolean("acknowledged", false),
                                mutedUntil = o.optLong("mutedUntil", 0L),
                            )
                        val newAlertId = repository.insertAlert(restoredAlert).toInt()
                        if (oldActiveAlertId > 0) activeAlertIdMap[oldActiveAlertId] = newAlertId
                        existingActiveAlertsByKey[key] = restoredAlert.copy(id = newAlertId)
                        importedActiveAlerts++
                    }

                    // Alert history (re-point serverId; keep newest N after import).
                    val historyArr = root.optJSONArray("alertHistory") ?: org.json.JSONArray()
                    val existingHistory = repository.getAlertHistory()
                    val usedHistoryActiveIds = existingHistory.mapTo(mutableSetOf()) { it.activeAlertId }
                    val existingHistoryKeys = existingHistory.mapTo(mutableSetOf()) {
                        "${it.serverId}|${it.metricName}|${it.triggeredTime}|${it.historyTime}|${it.status}"
                    }
                    var nextSyntheticActiveId = -1
                    fun allocateHistoryActiveId(preferred: Int?): Int {
                        if (preferred != null && preferred !in usedHistoryActiveIds) {
                            usedHistoryActiveIds.add(preferred)
                            return preferred
                        }
                        while (nextSyntheticActiveId in usedHistoryActiveIds) nextSyntheticActiveId--
                        return nextSyntheticActiveId.also { usedHistoryActiveIds.add(it); nextSyntheticActiveId-- }
                    }
                    var importedHistory = 0
                    for (i in 0 until if (closedSelection.alertHistory) historyArr.length() else 0) {
                        val o = historyArr.getJSONObject(i)
                        val mappedServerId = remapBackupServerId(o.optInt("serverId", 0), serverIdMap) ?: continue
                        val historyTime = o.optLong("historyTime", System.currentTimeMillis())
                        val triggeredTime = o.optLong("triggeredTime", historyTime)
                        val metricName = o.optString("metricName")
                        val status = o.optString("status", "acknowledged")
                        val historyKey = "$mappedServerId|$metricName|$triggeredTime|$historyTime|$status"
                        if (historyKey in existingHistoryKeys) continue
                        val sourceActiveId = o.optInt("activeAlertId", 0)
                        repository.insertAlertHistory(
                            AlertHistoryEntity(
                                activeAlertId = allocateHistoryActiveId(activeAlertIdMap[sourceActiveId]),
                                serverId = mappedServerId,
                                serverName = repository.getServerById(mappedServerId)?.name ?: o.optString("serverName", "server"),
                                metricName = metricName,
                                currentValue = o.optDouble("currentValue", 0.0).toFloat(),
                                thresholdValue = o.optDouble("thresholdValue", 0.0).toFloat(),
                                severity = o.optString("severity", "WARNING"),
                                triggeredTime = triggeredTime,
                                historyTime = historyTime,
                                status = status,
                            )
                        )
                        existingHistoryKeys.add(historyKey)
                        importedHistory++
                    }
                    if (closedSelection.alertHistory) repository.pruneAlertHistoryPerServer(alertHistoryLimit)

                    // Wake-on-LAN targets (dedup by MAC).
                    val existingWol = repository.getAllWolTargets().map { it.macAddress.lowercase() }.toMutableSet()
                    val wolArr = root.optJSONArray("wolTargets") ?: org.json.JSONArray()
                    var importedWol = 0
                    for (i in 0 until if (closedSelection.wolTargets) wolArr.length() else 0) {
                        val o = wolArr.getJSONObject(i)
                        val mac = o.optString("macAddress")
                        if (mac.isBlank() || mac.lowercase() in existingWol) continue
                        repository.insertWolTarget(
                            WolTargetEntity(
                                name = o.optString("name", "Target"), macAddress = mac,
                                broadcastIp = o.optString("broadcastIp", "192.168.1.255"),
                                ipAddress = o.optString("ipAddress", ""),
                                port = o.optInt("port", 9), notes = o.optString("notes", ""),
                                lastWokenTime = o.optLong("lastWokenTime", 0L),
                            )
                        )
                        existingWol.add(mac.lowercase())
                        importedWol++
                    }

                    // Network shares (dedup by endpoint + path; auth profile ids are re-pointed).
                    // shareIdMap tracks old id → restored/existing id so per-share settings
                    // (share_bookmarks_{id}) can follow their share, mirroring serverIdMap.
                    val existingSharesByKey = repository.getAllNetworkShares()
                        .associateBy { "${it.protocol.uppercase(Locale.ROOT)}|${it.address.lowercase(Locale.ROOT)}|${it.port}|${it.sharePath.trim('/')}" }
                        .toMutableMap()
                    val existingShareKeys = existingSharesByKey.keys.toMutableSet()
                    val shareIdMap = mutableMapOf<Int, Int>()
                    val shareArr = root.optJSONArray("networkShares") ?: org.json.JSONArray()
                    var importedNetworkShares = 0
                    for (i in 0 until if (closedSelection.networkShares) shareArr.length() else 0) {
                        val o = shareArr.getJSONObject(i)
                        val protocol = o.optString("protocol", "SMB").uppercase(Locale.ROOT)
                        val address = o.optString("address")
                        val port = o.optInt("port", defaultNetworkSharePort(protocol))
                        val sharePath = o.optString("sharePath", "").trim('/')
                        if (address.isBlank()) continue
                        val oldShareId = o.optInt("id", 0)
                        val key = "$protocol|${address.lowercase(Locale.ROOT)}|$port|$sharePath"
                        if (key in existingShareKeys) {
                            // Duplicate of a share we already have — its bookmarks re-point there.
                            existingSharesByKey[key]?.let { if (oldShareId != 0) shareIdMap[oldShareId] = it.id }
                            continue
                        }
                        val oldProfileId = o.optInt("authProfileId", 0)
                        val newShareId = repository.insertNetworkShare(
                            NetworkShareEntity(
                                name = o.optString("name", "$protocol $address"),
                                protocol = protocol,
                                address = address,
                                port = port,
                                sharePath = sharePath,
                                workgroup = o.optString("workgroup", ""),
                                username = o.optString("username", ""),
                                password = o.optString("password", ""),
                                authProfileId = profileIdMap[oldProfileId],
                                anonymous = o.optBoolean("anonymous", true),
                                // Old backups predate the flag; default from the same port
                                // heuristic the DB migration uses so behavior doesn't change.
                                useHttps = o.optBoolean("useHttps", protocol == "WEBDAV" && (port == 443 || port == 8443)),
                                notes = o.optString("notes", ""),
                                lastChecked = o.optLong("lastChecked", 0L),
                                lastStatus = o.optString("lastStatus", "unknown"),
                            )
                        )
                        if (oldShareId != 0) shareIdMap[oldShareId] = newShareId.toInt()
                        existingShareKeys.add(key)
                        importedNetworkShares++
                    }

                    // Port-forward definitions follow their restored SSH host. They are never
                    // auto-started as part of restore: importing data must not open listeners or
                    // create remote forwards without a fresh user action on this device.
                    val existingTunnelKeys = repository.getAllPortForwards().mapTo(mutableSetOf()) {
                        "${it.serverId}|${it.kind}|${it.bindHost}|${it.bindPort}|${it.destHost}|${it.destPort}"
                    }
                    val portForwardArr = root.optJSONArray("portForwards") ?: org.json.JSONArray()
                    var importedPortForwards = 0
                    for (i in 0 until if (closedSelection.portForwards) portForwardArr.length() else 0) {
                        val o = portForwardArr.getJSONObject(i)
                        val serverId = serverIdMap[o.optInt("serverId", 0)] ?: continue
                        val kind = o.optString("kind", "local")
                        if (kind !in setOf("local", "remote", "dynamic")) continue
                        val bindHost = o.optString("bindHost", "127.0.0.1").ifBlank { "127.0.0.1" }
                        val bindPort = o.optInt("bindPort", 0)
                        val destHost = o.optString("destHost", "")
                        val destPort = o.optInt("destPort", 0)
                        if (bindPort !in 1..65_535) continue
                        if (kind != "dynamic" && (destHost.isBlank() || destPort !in 1..65_535)) continue
                        val normalizedDestHost = if (kind == "dynamic") "" else destHost
                        val normalizedDestPort = if (kind == "dynamic") 0 else destPort
                        val key = "$serverId|$kind|$bindHost|$bindPort|$normalizedDestHost|$normalizedDestPort"
                        if (key in existingTunnelKeys) continue
                        repository.insertPortForward(
                            PortForwardEntity(
                                serverId = serverId,
                                name = o.optString("name", "Restored tunnel").take(120),
                                kind = kind,
                                bindHost = bindHost.take(255),
                                bindPort = bindPort,
                                destHost = normalizedDestHost.take(255),
                                destPort = normalizedDestPort,
                                autoStart = false,
                            )
                        )
                        existingTunnelKeys.add(key)
                        importedPortForwards++
                    }

                    // App settings / config (overwrite by key — full restore of preferences).
                    val settingsObj = root.optJSONObject("settings")
                    var importedSettings = 0
                    if (settingsObj != null && closedSelection.settings) {
                        // Defensive: never restore device-local security keys even if an old backup carried them.
                        val securityKeys = setOf(
                            "app_pin", "app_lock_enabled", "biometrics_enabled",
                            "pin_failed_attempts", "pin_locked_until",
                        )
                        val it = settingsObj.keys()
                        // Per-endpoint settings are keyed by the OLD server/share id; re-point them
                        // to the restored id. If the owning endpoint wasn't restored, skip the
                        // setting entirely so we don't leave orphaned rows pointing at nothing.
                        val perServerPrefixes = listOf("sftp_bookmarks_")
                        val perSharePrefixes = listOf("share_bookmarks_")
                        while (it.hasNext()) {
                            val originalKey = it.next()
                            if (originalKey in securityKeys) continue
                            var newKey = originalKey
                            val prefix = perServerPrefixes.firstOrNull { p -> originalKey.startsWith(p) }
                            if (prefix != null) {
                                val oldSrvId = originalKey.removePrefix(prefix).toIntOrNull() ?: 0
                                val mapped = serverIdMap[oldSrvId]
                                if (oldSrvId != 0 && mapped == null) continue // owning server not restored
                                if (mapped != null) newKey = "$prefix$mapped"
                            }
                            val sharePrefix = perSharePrefixes.firstOrNull { p -> originalKey.startsWith(p) }
                            if (sharePrefix != null) {
                                val oldShareId = originalKey.removePrefix(sharePrefix).toIntOrNull() ?: 0
                                val mapped = shareIdMap[oldShareId]
                                if (mapped == null) continue // owning share not restored (or pre-id backup)
                                newKey = "$sharePrefix$mapped"
                            }
                            repository.insertSetting(newKey, settingsObj.getString(originalKey))
                            importedSettings++
                        }
                    }

                    // Crash logs (opt-in). Merge into the on-device history newest-first; deduped by
                    // timestamp so re-importing the same backup doesn't pile up duplicates.
                    val crashArr = root.optJSONArray("crashLogs") ?: org.json.JSONArray()
                    var importedCrashLogs = 0
                    if (closedSelection.crashLogs) {
                        val restored = (0 until crashArr.length()).mapNotNull { i ->
                            val o = crashArr.optJSONObject(i) ?: return@mapNotNull null
                            CrashLog.Entry(o.optLong("t"), o.optString("r"))
                        }
                        importedCrashLogs = CrashLog.merge(getApplication(), restored)
                    }

                    // Report any partial restore explicitly with its reason, so a backup that
                    // exceeds the free Play Store limit never silently drops servers, credentials,
                    // or pinned host keys without telling the user why.
                    val skippedParts = buildList {
                        if (skippedServersByLimit > 0) add("$skippedServersByLimit server(s)")
                        if (skippedKeysByLimit > 0) add("$skippedKeysByLimit key(s)")
                        if (skippedProfilesByLimit > 0) add("$skippedProfilesByLimit profile(s)")
                        if (skippedHostKeysByLimit > 0) add("$skippedHostKeysByLimit pinned host key(s)")
                    }
                    val skippedSuffix = if (skippedParts.isNotEmpty()) {
                        " Skipped ${skippedParts.joinToString(", ")} because the free Play Store build is " +
                            "limited to $freePlayStoreLimit item(s). Unlock OmniTerm to restore everything."
                    } else {
                        ""
                    }
                    Pair(
                        true,
                        "Restored $imported server(s), $importedKeys key(s), $importedProfiles profile(s), " +
                            "$importedScripts script(s), $importedRules rule(s), $importedActiveAlerts active alert(s), $importedHistory alert history, $importedWol WoL, " +
                            "$importedNetworkShares share(s), $importedPortForwards tunnel(s), $importedSettings setting(s), $importedCrashLogs crash log(s)." + skippedSuffix,
                    )
                    }
                    } catch (e: Throwable) {
                        // Room rolls its database transaction back. Compensate the two external
                        // stores touched by restore so a reported failure never leaves partial data.
                        SshHostKeyTrust.replaceEntries(knownHostsBefore)
                        CrashLog.replace(getApplication(), crashLogsBefore)
                        throw e
                    }
                } catch (e: javax.crypto.AEADBadTagException) {
                    Pair(false, "Wrong passphrase or corrupted backup.")
                } catch (e: org.json.JSONException) {
                    Pair(false, "Not a valid OmniTerm backup file.")
                } catch (e: Exception) {
                    Pair(false, e.message ?: "Restore failed.")
                }
                }
            }
            reconcileHostLimit("Restored data exceeds the free Play Store host limit. Choose the one host to keep.")
            onResult(result.first, result.second)
        }
    }

    private fun jsonNullableString(obj: org.json.JSONObject, key: String): String? =
        if (!obj.has(key) || obj.isNull(key)) null else obj.optString(key)
}

internal fun activeHttpProbe(target: String, port: Int): String {
    return try {
        java.net.Socket().use { socket ->
            socket.connect(java.net.InetSocketAddress(target, port), 1000)
            socket.soTimeout = 1500
            val out = socket.getOutputStream()
            val request = "GET / HTTP/1.1\r\nHost: $target\r\nConnection: close\r\n\r\n"
            out.write(request.toByteArray(Charsets.UTF_8))
            out.flush()

            val reader = socket.getInputStream().bufferedReader(Charsets.UTF_8)
            val statusLine = reader.readLine()
            var serverHeader: String? = null
            if (statusLine != null) {
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    val l = line ?: break
                    if (l.isBlank()) break
                    if (l.startsWith("Server:", ignoreCase = true)) {
                        serverHeader = l.substring("Server:".length).trim()
                    }
                }
                buildString {
                    append("Open (HTTP: ${statusLine.trim()}")
                    if (serverHeader != null) {
                        append("; Server: $serverHeader")
                    }
                    append(")")
                }
            } else {
                "Open"
            }
        }
    } catch (e: Exception) {
        "Open"
    }
}

internal fun probePort(target: String, port: Int): String {
    val isHttpPort = port in listOf(80, 443, 8080, 3000, 8000)
    if (isHttpPort) {
        return activeHttpProbe(target, port)
    }

    // A successful connect() means the port is open, full stop. The banner grab below is
    // enrichment only — many services stay silent until the client speaks (they send no banner),
    // and a read timeout or reset AFTER connecting must never downgrade the result to "Closed".
    return try {
        java.net.Socket().use { socket ->
            socket.connect(java.net.InetSocketAddress(target, port), 800)
            socket.soTimeout = 1000
            val banner = try {
                socket.getInputStream().bufferedReader(Charsets.UTF_8).readLine()
            } catch (_: Exception) {
                null
            }
            if (!banner.isNullOrBlank()) "Open (Banner: ${banner.trim()})" else "Open"
        }
    } catch (_: Exception) {
        "Closed"
    }
}


data class DnsRecord(val name: String, val type: String, val value: String, val ttl: Long)

internal fun isIpAddress(target: String): Boolean {
    val trimmed = target.trim()
    val ipv4Parts = trimmed.split(".")
    if (ipv4Parts.size == 4 && ipv4Parts.all { it.isNotEmpty() && it.all(Char::isDigit) }) {
        return ipv4Parts.all { it.toIntOrNull() in 0..255 }
    }
    if (!trimmed.contains(":")) return false
    return try {
        java.net.InetAddress.getByName(trimmed) is java.net.Inet6Address
    } catch (_: Exception) {
        false
    }
}

internal fun queryWhoisServer(server: String, target: String): String {
    return java.net.Socket(cleanWhoisServerUri(server), 43).use { socket ->
        socket.soTimeout = 5000
        socket.getOutputStream().write(("$target\r\n").toByteArray(Charsets.US_ASCII))
        socket.getInputStream().bufferedReader().readText()
    }
}

internal fun cleanWhoisServerUri(server: String): String =
    server.trim()
        .removePrefix("whois://")
        .substringBefore("/")
        .substringBefore(":")
        .trim()

internal fun extractReferralServer(response: String): String? {
    val keys = listOf("refer", "ReferralServer", "whois", "whois server", "Registrar WHOIS Server")
    for (key in keys) {
        val line = response.lineSequence().firstOrNull {
            val trimmed = it.trim()
            trimmed.startsWith("$key:", ignoreCase = true)
        } ?: continue
        val value = line.substringAfter(":").trim()
        if (value.isNotBlank()) return cleanWhoisServerUri(value)
    }
    return null
}

/** One parsed hop of the TTL-stepped ping traceroute (see AppViewModel.pingSteppedTraceroute). */
internal data class TracerouteHop(val line: String, val reachedDestination: Boolean)

// IP captures must end on an alphanumeric so IPv6's own colons stay in the capture while the
// delimiter (":" after an IPv4, or the space in "From 10.0.0.1 icmp_seq=…") stays out.
private val TRACE_HOP_IP = Regex("""[Ff]rom ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s]""")
private val TRACE_ECHO_REPLY = Regex("""bytes from ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s].*time=([\d.]+)""")

internal fun parseTracerouteHop(ttl: Int, pingOutput: String, elapsedMs: Double): TracerouteHop {
    val reply = TRACE_ECHO_REPLY.find(pingOutput)
    if (reply != null) {
        return TracerouteHop("%2d  %s  %s ms".format(ttl, reply.groupValues[1], reply.groupValues[2]), true)
    }
    val hop = TRACE_HOP_IP.find(pingOutput)?.groupValues?.get(1)
    return if (hop != null) {
        TracerouteHop("%2d  %s  ~%.0f ms".format(ttl, hop, elapsedMs), false)
    } else {
        TracerouteHop("%2d  *".format(ttl), false)
    }
}

internal fun serializeDnsQuery(target: String, type: Int): ByteArray {
    val baos = java.io.ByteArrayOutputStream()
    val dos = java.io.DataOutputStream(baos)
    dos.writeShort(0x1234)
    dos.writeShort(0x0100)
    dos.writeShort(1)
    dos.writeShort(0)
    dos.writeShort(0)
    dos.writeShort(0)
    for (part in target.trim().trimEnd('.').split(".")) {
        require(part.length <= 63) { "DNS label too long" }
        dos.writeByte(part.length)
        dos.write(part.toByteArray(Charsets.US_ASCII))
    }
    dos.writeByte(0)
    dos.writeShort(type)
    dos.writeShort(1)
    return baos.toByteArray()
}

internal fun readName(data: ByteArray, startOffset: Int, packetLength: Int = data.size): Pair<String, Int> {
    val labels = mutableListOf<String>()
    var offset = startOffset
    var nextOffset = startOffset
    var jumped = false
    var jumps = 0

    while (offset in 0 until packetLength) {
        val len = data[offset].toInt() and 0xFF
        when {
            len == 0 -> {
                if (!jumped) nextOffset = offset + 1
                return labels.joinToString(".") to nextOffset
            }
            (len and 0xC0) == 0xC0 -> {
                if (offset + 1 >= packetLength) throw IllegalArgumentException("Truncated DNS pointer")
                val pointer = ((len and 0x3F) shl 8) or (data[offset + 1].toInt() and 0xFF)
                if (pointer >= packetLength || jumps++ > 16) throw IllegalArgumentException("Invalid DNS pointer")
                if (!jumped) nextOffset = offset + 2
                offset = pointer
                jumped = true
            }
            (len and 0xC0) != 0 -> throw IllegalArgumentException("Unsupported DNS label")
            else -> {
                val labelStart = offset + 1
                val labelEnd = labelStart + len
                if (labelEnd > packetLength) throw IllegalArgumentException("Truncated DNS label")
                labels += String(data, labelStart, len, Charsets.US_ASCII)
                offset = labelEnd
                if (!jumped) nextOffset = offset
            }
        }
    }
    throw IllegalArgumentException("Unterminated DNS name")
}

internal fun parseDnsResponse(data: ByteArray, length: Int): List<DnsRecord> {
    val records = mutableListOf<DnsRecord>()
    try {
        fun u16(offset: Int): Int {
            if (offset + 1 >= length) throw IllegalArgumentException("Truncated DNS field")
            return ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
        }

        fun u32(offset: Int): Long {
            if (offset + 3 >= length) throw IllegalArgumentException("Truncated DNS field")
            return ((data[offset].toLong() and 0xFF) shl 24) or
                ((data[offset + 1].toLong() and 0xFF) shl 16) or
                ((data[offset + 2].toLong() and 0xFF) shl 8) or
                (data[offset + 3].toLong() and 0xFF)
        }

        if (length < 12) throw IllegalArgumentException("Truncated DNS header")
        val qdcount = u16(4)
        val ancount = u16(6)

        var offset = 12
        repeat(qdcount) {
            offset = readName(data, offset, length).second
            if (offset + 4 > length) throw IllegalArgumentException("Truncated DNS question")
            offset += 4
        }

        repeat(ancount) {
            val (name, afterName) = readName(data, offset, length)
            offset = afterName
            if (offset + 10 > length) throw IllegalArgumentException("Truncated DNS answer")
            val type = u16(offset)
            offset += 2
            offset += 2 // class
            val ttl = u32(offset)
            offset += 4
            val rdlength = u16(offset)
            offset += 2
            val rdataOffset = offset
            val rdataEnd = rdataOffset + rdlength
            if (rdataEnd > length) throw IllegalArgumentException("Truncated DNS record data")

            val typeName = when (type) {
                1 -> "A"
                2 -> "NS"
                5 -> "CNAME"
                15 -> "MX"
                16 -> "TXT"
                28 -> "AAAA"
                else -> "TYPE$type"
            }

            val value = when (type) {
                1 -> if (rdlength == 4) {
                    "${data[rdataOffset].toInt() and 0xFF}.${data[rdataOffset + 1].toInt() and 0xFF}.${data[rdataOffset + 2].toInt() and 0xFF}.${data[rdataOffset + 3].toInt() and 0xFF}"
                } else {
                    "Invalid A record length: $rdlength"
                }
                2, 5 -> readName(data, rdataOffset, length).first
                15 -> {
                    if (rdlength < 3) {
                        "Invalid MX record length: $rdlength"
                    } else {
                        val preference = u16(rdataOffset)
                        val exchange = readName(data, rdataOffset + 2, length).first
                        "$preference $exchange"
                    }
                }
                16 -> {
                    val parts = mutableListOf<String>()
                    var txtOffset = rdataOffset
                    while (txtOffset < rdataEnd) {
                        val txtLength = data[txtOffset].toInt() and 0xFF
                        txtOffset += 1
                        if (txtOffset + txtLength > rdataEnd) throw IllegalArgumentException("Truncated TXT record")
                        parts += String(data, txtOffset, txtLength, Charsets.UTF_8)
                        txtOffset += txtLength
                    }
                    parts.joinToString("")
                }
                28 -> if (rdlength == 16) {
                    java.net.InetAddress.getByAddress(data.copyOfRange(rdataOffset, rdataEnd)).hostAddress ?: ""
                } else {
                    "Invalid AAAA record length: $rdlength"
                }
                else -> "Data length: $rdlength"
            }

            records.add(DnsRecord(name, typeName, value, ttl))
            offset += rdlength
        }
    } catch (e: Exception) {
        records.add(DnsRecord("Error", "ERR", "Parse error: ${e.message}", 0))
    }
    return records
}
