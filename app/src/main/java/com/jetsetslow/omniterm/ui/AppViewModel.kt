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
import androidx.compose.runtime.mutableStateMapOf
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.Locale
import java.util.UUID

/** Notification channel for fired monitoring alerts (distinct from the session-service channel). */
private const val ALERT_CHANNEL_ID = "monitoring_alerts"

/** Cap on the live action panel text: long-running streams keep only the most recent output. */
private const val ACTION_STREAM_MAX_CHARS = 200_000

/** Cap on the SFTP transfer log; finished entries beyond this are dropped, in-flight ones never. */
private const val SFTP_TRANSFER_LOG_MAX = 50

/** Cap on recursive SFTP search hits so a broad pattern can't flood the UI. */
private const val SFTP_SEARCH_MAX_HITS = 200

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
    HOME, END, PAGE_UP, PAGE_DOWN,
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

enum class BroadcastStatus { Running, Success, Failure }

enum class FleetTargetMode { Servers, Groups }

data class BroadcastResultItem(
    val serverId: Int,
    val serverName: String,
    val output: String = "",
    val status: BroadcastStatus = BroadcastStatus.Running,
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
    val settings: Boolean = true,
    // Opt-in (off by default): crash logs are device/build-specific diagnostics that can contain
    // sensitive details (hostnames, paths, command fragments), so they're never included unless the
    // user explicitly selects them — and when selected, [hasSensitiveData] forces encryption.
    val crashLogs: Boolean = false,
)

data class BackupContents(
    val servers: Int = 0,
    val sshKeys: Int = 0,
    val credentialProfiles: Int = 0,
    val scripts: Int = 0,
    val alertRules: Int = 0,
    val activeAlerts: Int = 0,
    val alertHistory: Int = 0,
    val wolTargets: Int = 0,
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
        alertHistory || wolTargets || settings || crashLogs

fun BackupSelection.encode(): String = listOf(
    "servers" to servers,
    "sshKeys" to sshKeys,
    "credentialProfiles" to credentialProfiles,
    "scripts" to scripts,
    "alertRules" to alertRules,
    "activeAlerts" to activeAlerts,
    "alertHistory" to alertHistory,
    "wolTargets" to wolTargets,
    "settings" to settings,
    "crashLogs" to crashLogs,
).filter { it.second }.joinToString(",") { it.first }

fun decodeBackupSelection(value: String?): BackupSelection {
    if (value.isNullOrBlank()) return BackupSelection()
    val keys = value.split(",").map { it.trim() }.filter { it.isNotBlank() }.toSet()
    return BackupSelection(
        servers = "servers" in keys,
        sshKeys = "sshKeys" in keys,
        credentialProfiles = "credentialProfiles" in keys,
        scripts = "scripts" in keys,
        alertRules = "alertRules" in keys,
        activeAlerts = "activeAlerts" in keys,
        alertHistory = "alertHistory" in keys,
        wolTargets = "wolTargets" in keys,
        settings = "settings" in keys,
        crashLogs = "crashLogs" in keys,
    )
}

private const val PIN_HASH_PREFIX = "pin:v1:"

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
    val digest = java.security.MessageDigest.getInstance("SHA-256")
    val hash = digest.digest(salt + pin.toByteArray(Charsets.UTF_8))
    val b64 = android.util.Base64.NO_WRAP
    return listOf(
        PIN_HASH_PREFIX.removeSuffix(":"),
        android.util.Base64.encodeToString(salt, b64),
        android.util.Base64.encodeToString(hash, b64),
        pin.length.toString(),
    ).joinToString(":")
}

internal fun storedPinLength(stored: String?): Int? =
    stored?.takeIf { it.startsWith(PIN_HASH_PREFIX) }?.substringAfterLast(':')?.toIntOrNull()

internal fun verifyStoredPin(stored: String?, pin: String): Boolean {
    if (stored.isNullOrBlank() || pin.isBlank()) return false
    if (!stored.startsWith(PIN_HASH_PREFIX)) return stored == pin
    val parts = stored.split(":")
    if (parts.size != 5) return false
    return runCatching {
        val b64 = android.util.Base64.NO_WRAP
        val salt = android.util.Base64.decode(parts[2], b64)
        val expected = android.util.Base64.decode(parts[3], b64)
        val actual = java.security.MessageDigest.getInstance("SHA-256")
            .digest(salt + pin.toByteArray(Charsets.UTF_8))
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
    /** Blocks screenshots and the task-switcher preview (FLAG_SECURE). Defaults on with app lock. */
    var isFlagSecureEnabled by mutableStateOf(false)
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
                SshHostKeyTrust.removeHost(removed.host, removed.port)
                activeSessions.filter { it.serverId == removed.id }.toList().forEach { cleanupSession(it) }
            }
            repository.keepOnlyServers(setOf(keep.id))
            
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
    var activeSftpTab by mutableStateOf(0) // 0: Files, 1: Transfers, 2: Bookmarks
    val sftpTransfers = mutableStateListOf<SftpTransferItem>()
    var edittingSftpFile by mutableStateOf<SftpFile?>(null)
    var edittingSftpFilePath by mutableStateOf("")

    // ── LIVE REMOTE DATA (real SSH; replaces the old in-memory simulator) ──
    var dockerContainers by mutableStateOf<List<SimContainer>>(emptyList()); private set
    var dockerImages by mutableStateOf<List<SimDockerImage>>(emptyList()); private set
    var dockerVolumes by mutableStateOf<List<SimDockerVolume>>(emptyList()); private set
    var dockerNetworks by mutableStateOf<List<SimDockerNetwork>>(emptyList()); private set
    var dockerLoading by mutableStateOf(false); private set
    var dockerError by mutableStateOf<String?>(null); private set
    
    var activeInfraTab by mutableStateOf(0)
    // Network Tools subtab (0: Host Scan, 1: Wake-on-LAN, 2: Ping, 3: Traceroute, 4: Port Scan). Held
    // in the VM (not local screen state) so the global horizontal swipe gesture can page between them.
    var activeNetworkTab by mutableStateOf(0)
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

    val isTerminalConnected: Boolean get() = currentSession?.isConnected == true
    var isTerminalConnecting by mutableStateOf(false)
    // Error from an initial connect that never produced a session (bad creds, host down, …). Unlike
    // [terminalDisconnectError] this isn't tied to a session, so it can surface on the connect prompt.
    var terminalConnectError by mutableStateOf<String?>(null)
    val terminalDisconnectError: String? get() = currentSession?.disconnectError ?: terminalConnectError
    var hostKeyChangedServer by mutableStateOf<com.jetsetslow.omniterm.data.ServerEntity?>(null)
    // Set when the user asks to connect to a host whose last probe found the SSH port unreachable.
    // The status can be stale, so we warn-and-confirm rather than hard-block; null = no prompt.
    var offlineConnectPromptServer by mutableStateOf<com.jetsetslow.omniterm.data.ServerEntity?>(null)
    var pendingHostKeyApproval by mutableStateOf<com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest?>(null)
    // Approvals beyond the one on screen wait here (first fleet probe can surface several at
    // once); approveHostKey() pops the next so every blocked JSch thread eventually gets an answer.
    private val hostKeyApprovalQueue = ArrayDeque<com.jetsetslow.omniterm.data.ssh.HostKeyApprovalRequest>()
    var terminalConnectionPhase by mutableStateOf("Connecting…")
    private var terminalConnectJob: kotlinx.coroutines.Job? = null
    // True only between a user tapping cancel and the connect coroutine observing the cancellation,
    // so the catch can tell a deliberate cancel (show nothing) from any other interruption (show why).
    private var userCancelledConnect = false

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
    var terminalTheme by mutableStateOf("omni_dark")
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
        val next = if (theme in setOf("omni_dark", "solarized_dark", "matrix", "light")) theme else "omni_dark"
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
        SshHostKeyTrust.approvalHandler = { req ->
            viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                if (pendingHostKeyApproval == null) pendingHostKeyApproval = req
                else hostKeyApprovalQueue.addLast(req)
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

        viewModelScope.launch {
            restorablePersistentSessions = withContext(Dispatchers.IO) {
                repository.getPersistentSessions()
            }
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
        super.onCleared()
        stopPing()
        stopTraceroute()
        // Release pooled SSH sessions held by the transport when the ViewModel goes away.
        sshTransport.shutdown()
        // Release the warm SFTP sessions too (separate pool from the exec/stream transport).
        JschSftp.shutdownPool()
    }

    // Ensures the cold-start lock is evaluated once, not on every settings write.
    private var coldStartLockEvaluated = false
    private fun loadSecuritySettings() {
        viewModelScope.launch {
            isFirstRun = repository.getSetting("first_run_complete") != "true"
        }
        viewModelScope.launch {
            allSettings.collect { list ->
                val pinVal = list.find { it.key == "app_pin" }?.value
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
                    ?.takeIf { it in setOf("omni_dark", "solarized_dark", "matrix", "light") }
                    ?: "omni_dark"
                list.find { it.key == "terminal_scrollback_limit" }?.value?.toIntOrNull()?.let {
                    terminalScrollbackLimit = it.coerceIn(1_000, 50_000)
                }
                list.find { it.key == "terminal_smart_swipe" }?.value?.let {
                    smartSwipeInput = it == "true"
                }
                alertHistoryLimit = list.find { it.key == "alert_history_limit" }?.value
                    ?.toIntOrNull()?.coerceIn(10, 1000) ?: 100
                list.find { it.key == "text_scale" }?.value?.let { textScale = it }
                list.find { it.key == "accessibility" }?.value?.let { isAccessibilityEnabled = it == "true" }
                list.find { it.key == "amoled" }?.value?.let { isAmoledEnabled = it == "true" }
                list.find { it.key == "sftp_sort" }?.value?.let { v ->
                    SftpSortOption.entries.firstOrNull { it.name == v }?.let { sftpSortOption = it }
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
                // Screenshot blocking defaults to following the app lock until explicitly set.
                isFlagSecureEnabled = list.find { it.key == "flag_secure" }?.value
                    ?.toBooleanStrictOrNull() ?: hasPinLock
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
        backupExportSelection = selection
        viewModelScope.launch { repository.insertSetting("backup_export_selection", selection.encode()) }
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
        Screen.SFTP -> 3
        Screen.Network -> 5
        else -> 0
    }

    private fun currentSubtab(screen: Screen): Int = when (screen) {
        Screen.Monitor -> activeMonitorTab
        Screen.Infra -> activeInfraTab
        Screen.Fleet -> fleetTabIndex
        Screen.SFTP -> activeSftpTab
        Screen.Network -> activeNetworkTab
        else -> 0
    }

    private fun setSubtab(screen: Screen, index: Int) {
        when (screen) {
            Screen.Monitor -> activeMonitorTab = index
            Screen.Infra -> activeInfraTab = index
            Screen.Fleet -> fleetTabIndex = index
            Screen.SFTP -> activeSftpTab = index
            Screen.Network -> activeNetworkTab = index
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
            Screen.SFTP -> pullSpin { loadSftp(clearError = true) } // re-list the current folder
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
        }
    }

    // PIN LOCK & SECURITY LOGIC
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
            // Unlock app successfully
            isAppLocked = false
            currentPinInput = ""
            lockScreenError = null
            failedPinAttempts = 0
        } else {
            failedPinAttempts += 1
            pinLockoutAfterFailure(failedPinAttempts, System.currentTimeMillis())
                .takeIf { it > 0L }?.let { pinLockedUntilMs = it }
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
    fun addServer(name: String, host: String, port: Int, username: String, group: String?, authType: String, notes: String, keepAlive: Int, compression: Boolean, proxy: String, password: String? = null, keyAlias: String? = null, profileId: Int? = null, createProfile: Boolean = false, serverColor: String = "Default", sudoPassword: String = "", proxyType: String = "none", proxyHost: String = "", proxyPort: Int = 0, proxyUser: String = "", proxyPassword: String = "", proxyKeyAlias: String? = null, persistentSession: Boolean = false, onResult: (String?) -> Unit) {
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
            repository.updateServer(server)
        }
    }

    fun deleteServer(server: ServerEntity) {
        viewModelScope.launch {
            repository.deleteServer(server)
            repository.deletePersistentSessionsForServer(server.id)
            restorablePersistentSessions = restorablePersistentSessions.filter { it.serverId != server.id }
            SshHostKeyTrust.removeHost(server.host, server.port)
            if (selectedServerId == server.id) {
                selectedServerId = null
            }
        }
    }

    fun dismissHostKeyChangedDialog() { hostKeyChangedServer = null }

    fun approveHostKey(approved: Boolean) {
        val req = pendingHostKeyApproval ?: return
        pendingHostKeyApproval = hostKeyApprovalQueue.removeFirstOrNull()
        req.deferred.complete(approved)
        if (!approved) {
            isTerminalConnecting = false
            terminalConnectError = "Host key rejected by user."
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
        )
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
        userCancelledConnect = true
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

    /** Proceed with a connect the user confirmed despite an offline status (dismisses the warning). */
    fun connectTerminalConfirmedOffline() {
        val srv = offlineConnectPromptServer ?: return
        offlineConnectPromptServer = null
        connectTerminal(srv, forceDisablePersistence = false)
    }

    fun dismissOfflineConnectPrompt() { offlineConnectPromptServer = null }

    private fun connectTerminal(srv: ServerEntity, forceDisablePersistence: Boolean) {
        if (isTerminalConnecting) return
        isTerminalConnecting = true
        terminalConnectError = null
        terminalConnectionPhase = "Connecting…"

        terminalConnectJob = viewModelScope.launch {
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
                    viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) { terminalConnectionPhase = phase }
                }
                val shellSession = ShellSession(srv.id, srv.name, session, emulator)
                // Keep what auto-reconnect needs to reopen this exact shell without the UI.
                shellSession.creds = creds
                shellSession.lastCols = termCols
                shellSession.lastRows = termRows
                shellSession.persistent = usePersistence
                if (usePersistence) {
                    shellSession.tmuxName = nextTmuxSessionNameForServer(srv.id)
                }

                // Persistent session: enter a tmux session unique to this shell so a reconnect
                // re-attaches the SAME session (and any running command keeps going server-side),
                // and multiple persistent shells to one host don't collide on a shared name.
                if (usePersistence) {
                    emulator.setCaptureAlternateScreenScrollback(true)
                    session.write(RemoteCommands.tmuxAttachCommand(shellSession.tmuxName, terminalScrollbackLimit).toByteArray())
                    rememberRestorablePersistentSession(shellSession)
                }

                activeSessions.add(shellSession)
                withContext(Dispatchers.Main) {
                    currentSessionId = shellSession.id
                }
                isTerminalConnecting = false
                noteSuccessfulSshSession()
                TerminalSessionManager.updateKeepaliveCount()
                startKeepAliveService()

                wireSessionIo(shellSession)
            } catch (e: kotlinx.coroutines.CancellationException) {
                // Only an explicit user cancel (cancelConnect) should leave the screen with no error.
                // Any other cancellation means the attempt died without reaching the catch below, which
                // previously looked like a silent bounce back to the prompt — surface a reason instead.
                isTerminalConnecting = false
                if (!userCancelledConnect) {
                    terminalConnectError = "Connection attempt was interrupted before it completed."
                }
                userCancelledConnect = false
                throw e
            } catch (e: Exception) {
                isTerminalConnecting = false
                val msg = e.message ?: "Connection failed."
                if (msg.contains("reject HostKey", ignoreCase = true) ||
                    msg.contains("HostKey has been changed", ignoreCase = true)) {
                    hostKeyChangedServer = srv
                } else {
                    terminalConnectError = cleanSshError(msg)
                }
            }
        }
    }

    fun resumePersistentSession(tmuxName: String) {
        val existingSession = activeSessions.find { it.tmuxName == tmuxName }
        if (existingSession != null) {
            attachSession(existingSession.id)
            return
        }
        val sessionEntity = restorablePersistentSessions.find { it.tmuxName == tmuxName } ?: return
        val srv = servers.value.find { it.id == sessionEntity.serverId } ?: return

        if (isTerminalConnecting) return
        isTerminalConnecting = true
        terminalConnectError = null
        terminalConnectionPhase = "Connecting…"

        terminalConnectJob = viewModelScope.launch {
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
                    viewModelScope.launch(kotlinx.coroutines.Dispatchers.Main) { terminalConnectionPhase = phase }
                }
                val shellSession = ShellSession(srv.id, srv.name, session, emulator)
                shellSession.creds = creds
                shellSession.lastCols = termCols
                shellSession.lastRows = termRows
                shellSession.persistent = true
                shellSession.tmuxName = tmuxName
                emulator.setCaptureAlternateScreenScrollback(true)

                session.write(com.jetsetslow.omniterm.data.RemoteCommands.tmuxAttachCommand(tmuxName, terminalScrollbackLimit).toByteArray())

                activeSessions.add(shellSession)
                withContext(kotlinx.coroutines.Dispatchers.Main) {
                    currentSessionId = shellSession.id
                }
                isTerminalConnecting = false
                noteSuccessfulSshSession()
                TerminalSessionManager.updateKeepaliveCount()
                startKeepAliveService()

                wireSessionIo(shellSession)
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                isTerminalConnecting = false
                val msg = e.message ?: "Connection failed."
                if (msg.contains("reject HostKey", ignoreCase = true) ||
                    msg.contains("HostKey has been changed", ignoreCase = true)) {
                    hostKeyChangedServer = srv
                } else {
                    terminalConnectError = cleanSshError(msg)
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
        shellSession.terminalInputChannel?.close()

        // Serialize keystrokes through a single channel so writes never reorder. UNLIMITED capacity
        // guarantees trySend always succeeds in call order. Recreated per (re)connect so it always
        // targets the current live channel.
        val inCh = Channel<ByteArray>(Channel.UNLIMITED)
        shellSession.terminalInputChannel = inCh
        shellSession.terminalInputJob = TerminalSessionManager.scope.launch(Dispatchers.IO) {
            for (bytes in inCh) {
                try { shellSession.session.write(bytes) } catch (_: Exception) {}
            }
        }

        shellSession.terminalOutputJob = TerminalSessionManager.scope.launch(Dispatchers.Default) {
            var cleanExit = false
            var lastSnapshotMs = 0L
            var pendingSnapshotJob: Job? = null
            try {
                session.output.collect { bytes ->
                    synchronized(emulator) { emulator.feed(bytes) }
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
                pendingSnapshotJob?.cancel()
                TerminalSessionManager.publishTerminalSnapshot(shellSession)
                // remoteExited is the authoritative "the user ended the shell/tmux" signal (genuine
                // remote channel-EOF). It's only ever true for a deliberate exit, never a socket drop.
                cleanExit = session.remoteExited.value || isCleanShellExit(session.exitStatus.value)
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
                    TerminalSessionManager.cleanupSession(shellSession)
                } else {
                    shellSession.disconnectError = "Connection lost."
                    rememberRestorablePersistentSession(shellSession)
                    TerminalSessionManager.startKeepAliveService()
                }
            }
        }
    }

    private fun rememberRestorablePersistentSession(shellSession: ShellSession) {
        if (!shellSession.persistent) return
        if (restorablePersistentSessions.none { it.tmuxName == shellSession.tmuxName }) {
            restorablePersistentSessions = restorablePersistentSessions +
                PersistentSessionEntity(shellSession.tmuxName, shellSession.serverId, shellSession.serverName)
        }
        viewModelScope.launch {
            repository.upsertPersistentSession(
                PersistentSessionEntity(shellSession.tmuxName, shellSession.serverId, shellSession.serverName)
            )
        }
    }

    private fun nextTmuxSessionNameForServer(serverId: Int): String {
        val existingNames = buildSet {
            activeSessions.filter { it.serverId == serverId }.forEach { add(it.tmuxName) }
            restorablePersistentSessions.filter { it.serverId == serverId }.forEach { add(it.tmuxName) }
        }
        return generateUniqueTmuxSessionName(existingNames)
    }

    private fun forgetPersistentSession(tmuxName: String) {
        restorablePersistentSessions = restorablePersistentSessions.filter { it.tmuxName != tmuxName }
        viewModelScope.launch { repository.deletePersistentSession(tmuxName) }
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

                if (shellSession.userClosed) { runCatching { newSession.close() }; return@launch }
                if (shellSession.persistent) {
                    val tmuxAvailable = when (remoteTmuxSessionExists(creds, shellSession.tmuxName)) {
                        false -> {
                            runCatching { newSession.close() }
                            withContext(Dispatchers.Main) {
                                shellSession.reconnecting = false
                                shellSession.disconnectError = "Server disconnected; tmux session is no longer running."
                                forgetPersistentSession(shellSession.tmuxName)
                                TerminalSessionManager.cleanupSession(shellSession)
                                terminalConnectError = "Server disconnected; tmux session is no longer running."
                            }
                            return@launch
                        }
                        null -> {
                            runCatching { newSession.close() }
                            false
                        }
                        true -> true
                    }
                    if (!tmuxAvailable) continue
                }
                shellSession.session = newSession
                if (shellSession.persistent) {
                    synchronized(shellSession.emulator) {
                        shellSession.emulator.setCaptureAlternateScreenScrollback(true)
                    }
                    runCatching {
                        newSession.write(RemoteCommands.tmuxAttachCommand(shellSession.tmuxName, terminalScrollbackLimit).toByteArray())
                    }
                }
                // Visible marker in the kept scrollback so the user knows the stream resumed.
                synchronized(shellSession.emulator) {
                    shellSession.emulator.feed("\r\n\u001B[32m-- reconnected --\u001B[0m\r\n".toByteArray())
                }
                withContext(Dispatchers.Main) {
                    shellSession.isConnected = true
                    shellSession.reconnecting = false
                    shellSession.disconnectError = null
                    TerminalSessionManager.updateKeepaliveCount()
                    TerminalSessionManager.startKeepAliveService()
                }
                wireSessionIo(shellSession)
                return@launch
            }
            // Exhausted attempts.
            withContext(Dispatchers.Main) {
                shellSession.reconnecting = false
                shellSession.disconnectError = "Connection lost — reconnect failed."
                rememberRestorablePersistentSession(shellSession)
                if (shellSession.persistent) {
                    TerminalSessionManager.cleanupSession(shellSession)
                    if (currentSessionId == shellSession.id) currentSessionId = null
                } else {
                    TerminalSessionManager.startKeepAliveService()
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
    fun resizeTerminal(cols: Int, rows: Int) {
        if (cols < 1 || rows < 1) return
        if (cols == termCols && rows == termRows) return
        termCols = cols; termRows = rows
        val s = currentSession ?: return
        synchronized(s.emulator) {
            s.emulator.resize(cols, rows)
        }
        TerminalSessionManager.publishTerminalSnapshot(s)
        viewModelScope.launch { s.session.resize(cols, rows) }
    }

    fun updateTerminalViewport(firstRow: Int, rowCount: Int, followTail: Boolean) {
        val s = currentSession ?: return
        val count = rowCount.coerceIn(1, 300)
        val changed = s.viewportFirstRow != firstRow || s.viewportRowCount != count || s.followTail != followTail
        s.viewportFirstRow = firstRow.coerceAtLeast(0)
        s.viewportRowCount = count
        s.followTail = followTail
        if (changed) TerminalSessionManager.publishTerminalSnapshot(s)
    }

    fun terminalBufferText(full: Boolean, firstRow: Int = 0, rowCount: Int = Int.MAX_VALUE): String {
        val s = currentSession ?: return ""
        val scrollbackRows: Int
        val rows = synchronized(s.emulator) {
            scrollbackRows = s.emulator.scrollbackRowCount()
            if (full) s.emulator.snapshot().rows
            else s.emulator.snapshotRange(firstRow, rowCount).rows
        }
        var lines = rows.map { row -> row.spans.joinToString("") { it.text }.trimEnd() }
        if (full) {
            // tmux (and other full-screen apps we capture scrollback from) often replays the visible
            // pane right after a scroll, so the tail of captured scrollback repeats the head of the
            // live screen verbatim. That overlap is why "Full buffer" showed duplicated content. Drop
            // the longest exact run where scrollback's tail equals the screen's head — a conservative
            // collapse at just the scrollback↔screen boundary, so genuinely repeated output elsewhere
            // in the buffer is left intact.
            lines = dropBoundaryDuplication(lines, scrollbackRows)
        }
        return lines.joinToString("\n").trimEnd()
    }

    fun clearTerminalScrollback() {
        val s = currentSession ?: return
        synchronized(s.emulator) {
            s.emulator.clearScrollback()
        }
        s.viewportFirstRow = 0
        s.followTail = true
        TerminalSessionManager.publishTerminalSnapshot(s)
    }

    private fun sendBytes(bytes: ByteArray) {
        // The channel is Channel.UNLIMITED, so trySend always succeeds in call order unless the
        // channel is closed (session torn down) — in which case dropping is correct. Do NOT add an
        // async send fallback here: a coroutine-per-call fallback races and reorders bytes, which
        // is what jumbled large pastes.
        currentSession?.terminalInputChannel?.trySend(bytes)
    }

    /** Printable text typed by the user (soft or hardware keyboard). Applies sticky Ctrl/Alt. */
    fun typeText(text: String) {
        val session = currentSession ?: return
        if (text.isEmpty() || !session.isConnected) return
        pendingSwipeFlush?.invoke()
        var t = text
        if (isShiftPressed && t.length == 1) {
            t = t.uppercase()
        }
        if (isCtrlPressed || isAltPressed) {
            val out = ArrayList<Byte>()
            val first = t.first()
            if (isAltPressed) out.add(0x1B)
            if (isCtrlPressed) out.add(controlByte(first))
            else out.addAll(first.toString().toByteArray().toList())
            if (t.length > 1) out.addAll(t.substring(1).toByteArray().toList())
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
        val session = currentSession ?: return
        if (text.isEmpty() || !session.isConnected) return
        val normalized = text.replace("\r\n", "\n").replace('\n', '\r')
        sendBytes(normalized.toByteArray())
    }

    /** Map a character to its Ctrl-modified control byte (Ctrl-C → 0x03, etc.). */
    private fun controlByte(c: Char): Byte = (c.uppercaseChar().code and 0x1F).toByte()

    /**
     * Apply an editor-style line edit from the swipe input field: [backspaces] DEL bytes (0x7F) to
     * erase the changed tail, then the [insert] text. Sent as one ordered write and deliberately does
     * NOT trigger pendingSwipeFlush — it IS the field mirroring its own edit, not a shell-owned key.
     */
    fun applyLineEdit(backspaces: Int, insert: String) {
        val session = currentSession ?: return
        if (!session.isConnected) return
        if (backspaces <= 0 && insert.isEmpty()) return
        val out = ArrayList<Byte>(backspaces + insert.length)
        repeat(backspaces) { out.add(0x7F) }
        out.addAll(insert.toByteArray().toList())
        sendBytes(out.toByteArray())
    }

    fun sendKey(key: TermKey) {
        val session = currentSession ?: return
        if (!session.isConnected) return
        pendingSwipeFlush?.invoke()
        val app = synchronized(session.emulator) { session.emulator.applicationCursorKeys }
        // Shift+Tab is back-tab (CSI Z) — reverse tab-completion in many shells/TUIs. Without this,
        // an armed SHFT modifier was silently dropped on Tab. Other Shift combos fall through.
        val shiftTab = key == TermKey.TAB && isShiftPressed
        // xterm modifier parameter: 1 + Shift(1) + Alt(2) + Ctrl(4). >1 means a modifier is armed,
        // in which case cursor/Home/End use the CSI 1;<mod><letter> form (Ctrl+→ word-jump,
        // Shift+→ select, etc.) instead of the plain sequence — otherwise the modifier was dropped.
        val cursorMod = 1 + (if (isShiftPressed) 1 else 0) + (if (isAltPressed) 2 else 0) + (if (isCtrlPressed) 4 else 0)
        fun modCursor(letter: Char): ByteArray =
            if (cursorMod > 1) ("[1;$cursorMod$letter").toByteArray()
            else if (app) escO(letter) else escBracket(letter)
        val seq: ByteArray = when {
            shiftTab -> byteArrayOf(0x1B, '['.code.toByte(), 'Z'.code.toByte())
            else -> when (key) {
            TermKey.ENTER -> byteArrayOf(0x0D)
            TermKey.BACKSPACE -> byteArrayOf(0x7F)
            TermKey.TAB -> byteArrayOf(0x09)
            TermKey.ESC -> byteArrayOf(0x1B)
            TermKey.UP -> modCursor('A')
            TermKey.DOWN -> modCursor('B')
            TermKey.RIGHT -> modCursor('C')
            TermKey.LEFT -> modCursor('D')
            TermKey.HOME -> if (cursorMod > 1) "[1;${cursorMod}H".toByteArray() else escBracket('H')
            TermKey.END -> if (cursorMod > 1) "[1;${cursorMod}F".toByteArray() else escBracket('F')
            TermKey.PAGE_UP -> byteArrayOf(0x1B, '['.code.toByte(), '5'.code.toByte(), '~'.code.toByte())
            TermKey.PAGE_DOWN -> byteArrayOf(0x1B, '['.code.toByte(), '6'.code.toByte(), '~'.code.toByte())
            TermKey.F1 -> escO('P')
            TermKey.F2 -> escO('Q')
            TermKey.F3 -> escO('R')
            TermKey.F4 -> escO('S')
            TermKey.F5 -> escTilde("15")
            TermKey.F6 -> escTilde("17")
            TermKey.F7 -> escTilde("18")
            TermKey.F8 -> escTilde("19")
            TermKey.F9 -> escTilde("20")
            TermKey.F10 -> escTilde("21")
            TermKey.F11 -> escTilde("23")
            TermKey.F12 -> escTilde("24")
            }
        }
        sendBytes(seq)
        isCtrlPressed = false
        isAltPressed = false
        isShiftPressed = false
    }

    private fun escBracket(c: Char) = byteArrayOf(0x1B, '['.code.toByte(), c.code.toByte())
    private fun escO(c: Char) = byteArrayOf(0x1B, 'O'.code.toByte(), c.code.toByte())
    private fun escTilde(code: String) = (byteArrayOf(0x1B, '['.code.toByte()) + code.toByteArray() + byteArrayOf('~'.code.toByte()))

    /**
     * True when a scroll gesture should be forwarded to the remote as mouse-wheel events rather than
     * scrolling the local viewport. Persistent sessions run inside tmux with `mouse on`, so wheel
     * events drive tmux's own copy-mode and expose its full server-side scrollback — the history the
     * local emulator can't reconstruct (tmux repaints by cursor addressing, not by scrolling lines
     * through our scroll region). Normal shells keep local viewport scroll over our own scrollback.
     */
    fun terminalScrollForwardsToRemote(): Boolean = currentSession?.persistent == true

    /**
     * Forward a vertical scroll gesture to the remote as SGR (1006) mouse-wheel events. [wheelUp]
     * picks wheel-up (button 64, scroll back into history) vs wheel-down (button 65). [ticks] is how
     * many discrete wheel notches the gesture covered. Coordinates are 1-based; we report the gesture
     * at the top-left cell, which is sufficient for tmux copy-mode scrolling (it scrolls the pane the
     * pointer is over, and a single pane fills the view). No-ops for a non-tmux/disconnected session.
     */
    fun terminalMouseWheel(wheelUp: Boolean, ticks: Int = 1) {
        val session = currentSession ?: return
        if (!session.isConnected || !session.persistent) return
        val button = if (wheelUp) 64 else 65
        val out = ArrayList<Byte>(ticks.coerceIn(1, 10) * 8)
        // SGR mouse: ESC [ < button ; col ; row M   (M = press; wheel has no release).
        val seq = "[<$button;1;1M".toByteArray()
        repeat(ticks.coerceIn(1, 10)) { seq.forEach { out.add(it) } }
        sendBytes(out.toByteArray())
    }

    fun disconnectTerminal() {
        val s = currentSession ?: return
        disconnectSession(s.id)
    }

    fun sendToBackground() {
        val s = currentSession
        if (s?.persistent == true) {
            leaveSessionResumable(s.id)
            return
        }
        currentSessionId = null
        // Stay on Shell — ShellScreen shows SessionPicker when currentSession==null && activeSessions.isNotEmpty()
        // Always start the service so per-session notifications with Disconnect buttons appear
        val connected = activeSessions.filter { it.isConnected }
        if (connected.isNotEmpty()) {
            val context = getApplication<android.app.Application>()
            val sessionData = ArrayList(connected.map { "${it.id}|${it.serverName}" })
            val svcIntent = android.content.Intent(context, com.jetsetslow.omniterm.SessionService::class.java).apply {
                action = com.jetsetslow.omniterm.SessionService.ACTION_UPDATE_SESSIONS
                putStringArrayListExtra(com.jetsetslow.omniterm.SessionService.EXTRA_SESSIONS, sessionData)
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
            s.creds?.let { c ->
                viewModelScope.launch(Dispatchers.IO) {
                    runCatching { sshTransport.exec(c, RemoteCommands.tmuxKillCommand(s.tmuxName)) }
                }
            }
            forgetPersistentSession(s.tmuxName)
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
        rememberRestorablePersistentSession(s)
        // cleanupSession closes the socket off the main thread (see disconnectSession).
        cleanupSession(s)
        if (currentSessionId == sessionId) currentSessionId = null
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

                    val out = outAsync.await()
                    if (srv.id != selectedServerId) return@coroutineScope
                    if (out.startsWith("SSH Error")) {
                        dockerError = out
                        dockerContainers = emptyList()
                        dockerImages = emptyList()
                        dockerVolumes = emptyList()
                        dockerNetworks = emptyList()
                    } else {
                        val restarts = runCatching { RemoteParsers.parseDockerRestartCounts(restartsAsync.await()) }.getOrDefault(emptyMap())
                        if (srv.id != selectedServerId) return@coroutineScope

                        val parsedContainers = RemoteParsers.parseDockerPs(out).map {
                            it.copy(host = srv.name, restartCount = restarts[it.id] ?: it.restartCount)
                        }
                        dockerContainers = parsedContainers

                        val imgOut = imagesAsync.await()
                        dockerImages = RemoteParsers.parseDockerImages(imgOut).map { img ->
                            val inUse = parsedContainers.any { c ->
                                c.image == img.repository || c.image == "${img.repository}:${img.tag}" || c.image.contains(img.id.take(12))
                            }
                            img.copy(inUse = inUse)
                        }

                        val volOut = volumesAsync.await()
                        dockerVolumes = RemoteParsers.parseDockerVolumes(volOut)

                        val netOut = networksAsync.await()
                        dockerNetworks = RemoteParsers.parseDockerNetworks(netOut)
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
                }
            } finally {
                if (srv.id == selectedServerId) dockerLoading = false
            }
        }
    }

    fun dockerAction(containerId: String, action: String) {
        runStreamingAction("container $action", RemoteCommands.dockerAction(containerId, action)) { loadDocker() }
    }

    fun dockerImageAction(imageId: String, action: String) {
        runStreamingAction("image $action", RemoteCommands.dockerImageAction(imageId, action)) { loadDocker() }
    }

    fun dockerVolumeAction(volumeName: String, action: String) {
        runStreamingAction("volume $action", RemoteCommands.dockerVolumeAction(volumeName, action)) { loadDocker() }
    }

    fun dockerNetworkAction(networkId: String, action: String) {
        runStreamingAction("network $action", RemoteCommands.dockerNetworkAction(networkId, action)) { loadDocker() }
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
    fun dockerContainerLogs(containerId: String, name: String) {
        runStreamingAction("logs · $name", RemoteCommands.dockerLogs(containerId))
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

    fun dockerStackAction(project: String, workingDir: String, configFiles: String, action: String, removeOrphans: Boolean = false) {
        if (project == "standalone" || workingDir.isBlank()) {
            showActionMessage(project, "This stack does not expose compose working directory labels, so OmniTerm cannot run compose actions for it.")
            return
        }
        runStreamingAction("$project · $action", RemoteCommands.dockerComposeAction(project, workingDir, configFiles, action, removeOrphans = removeOrphans)) { loadDocker() }
    }

    fun dockerStackUpdate(project: String, workingDir: String, configFiles: String) {
        dockerStackAction(project, workingDir, configFiles, "update")
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
        onResult: (Boolean, String) -> Unit,
    ) {
        val srv = selectedServer ?: return onResult(false, "No host selected.")
        viewModelScope.launch {
            val b64 = android.util.Base64.encodeToString(yaml.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
            val cmd = RemoteCommands.composeDeploy(composeFilePath, project, b64, workingDir, configFiles)
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

    fun dockerStackServiceAction(project: String, workingDir: String, configFiles: String, service: String, action: String, replicas: Int? = null) {
        if (project == "standalone" || workingDir.isBlank() || service.isBlank()) {
            showActionMessage("$project · $service", "This service does not expose enough compose metadata for service-level actions.")
            return
        }
        runStreamingAction(
            "$project/$service · $action",
            RemoteCommands.dockerComposeAction(project, workingDir, configFiles, action, service, replicas),
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
                    typeText(RemoteCommands.dockerComposeExecShellCommand(containerId) + "\r")
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
                    add("ping")
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
                // Prefer numeric, capped hops; fall back to a bare invocation if flags aren't supported.
                val process = try {
                    ProcessBuilder(listOf("traceroute", "-n", "-m", "30", target)).redirectErrorStream(true).start()
                } catch (_: java.io.IOException) {
                    ProcessBuilder(listOf("traceroute", target)).redirectErrorStream(true).start()
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

    // ── SFTP (real ChannelSftp) ──
    private suspend fun sftpClientOrNull(): JschSftp? =
        selectedServer?.let { JschSftp(buildCredentials(it)) }

    private suspend fun sftpClientFor(server: ServerEntity): JschSftp =
        JschSftp(buildCredentials(server))

    private fun joinPath(base: String, name: String): String =
        if (base == "/" || base.isEmpty()) "/$name" else "$base/$name"

    private val sftpSessionPaths = mutableMapOf<Int, String>()

    private fun sortSftpEntries(entries: List<SftpFile>): List<SftpFile> {
        val nameComparator = compareBy<SftpFile> { it.name.lowercase(Locale.ROOT) }
            .thenBy { it.name }
        val base = when (sftpSortOption) {
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
        sftpClipboard = sftpSelected.map { joinPath(sftpPath, it) }
        sftpClipboardIsMove = move
        val verb = if (move) "Cut" else "Copied"
        sftpStatus = "$verb ${sftpClipboard.size} item(s) — open a folder and Paste"
        sftpSelected.clear()
    }

    fun sftpClearClipboard() { sftpClipboard = emptyList(); sftpClipboardIsMove = false }

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
                    if (isMove) sftpClearClipboard()
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
                val output = withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)
                        ?: throw java.io.IOException("Could not open destination.")
                }
                val bytes = try {
                    client.downloadTo(remotePath, output) { done, total ->
                        updateSftpTransferProgress(transferId, done, total)
                    }
                } finally {
                    withContext(Dispatchers.IO) { output.close() }
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
            for (name in names) {
                val remotePath = joinPath(remoteDir, name)
                val transferId = addSftpTransfer(srv, "Download", name, remotePath)
                try {
                    val destUri = createDocumentInTree(context, folderUri, name)
                    val output = withContext(Dispatchers.IO) {
                        context.contentResolver.openOutputStream(destUri)
                            ?: throw java.io.IOException("Could not open destination for $name.")
                    }
                    val copied = try {
                        client.downloadTo(remotePath, output) { done, total ->
                            updateSftpTransferProgress(transferId, done, total)
                        }
                    } finally {
                        withContext(Dispatchers.IO) { output.close() }
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
            for ((index, uri) in picked.withIndex()) {
                val name = queryDisplayName(context, uri)?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                    ?: "upload_${System.currentTimeMillis()}_${index + 1}"
                val remotePath = joinPath(remoteDir, name)
                val transferId = addSftpTransfer(srv, "Upload", name, remotePath, sourceUri = uri.toString())
                try {
                    val totalBytes = queryOpenableSize(context, uri)
                    val input = withContext(Dispatchers.IO) {
                        context.contentResolver.openInputStream(uri)
                            ?: throw java.io.IOException("Could not read the selected file from this device.")
                    }
                    val uploaded = try {
                        client.uploadStream(remotePath, input, totalBytes) { done, total ->
                            updateSftpTransferProgress(transferId, done, total)
                        }
                        totalBytes.coerceAtLeast(0L)
                    } finally {
                        withContext(Dispatchers.IO) { input.close() }
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

    private fun addSftpTransfer(server: ServerEntity, direction: String, name: String, remotePath: String, sourceUri: String? = null): String {
        val item = SftpTransferItem(serverId = server.id, serverName = server.name, direction = direction, name = name, remotePath = remotePath, sourceUri = sourceUri)
        sftpTransfers.add(0, item)
        // Trim the oldest finished entries so the log can't grow without bound across a session.
        for (i in sftpTransfers.indices.reversed()) {
            if (sftpTransfers.size <= SFTP_TRANSFER_LOG_MAX) break
            if (sftpTransfers[i].status != SftpTransferStatus.InProgress) sftpTransfers.removeAt(i)
        }
        return item.id
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
        val index = sftpTransfers.indexOfFirst { it.id == id }
        if (index >= 0) {
            val current = sftpTransfers[index]
            sftpTransfers[index] = current.copy(
                status = status,
                bytesTransferred = bytesTransferred ?: current.bytesTransferred,
                totalBytes = totalBytes ?: current.totalBytes,
                message = message,
                retryable = status == SftpTransferStatus.Failure && current.direction == "Upload" && current.sourceUri != null,
            )
        }
    }

    fun retrySftpTransfer(item: SftpTransferItem) {
        if (!item.retryable || item.sourceUri == null) return
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

        viewModelScope.launch {
            val allServers = repository.getAllServers()
            val selected = when {
                resolvedIds != null -> allServers.filter { it.id in resolvedIds }
                broadcastTargetMode == FleetTargetMode.Servers -> allServers.filter { it.id in targetIds }
                else -> allServers.filter { it.status == "online" && it.groupName.orEmpty() in targetGroups }
            }
            if (selected.isEmpty()) {
                isBroadcastExecuting = false
                return@launch
            }
            broadcastResults.addAll(selected.map { BroadcastResultItem(serverId = it.id, serverName = it.name) })
            val limiter = Semaphore(6)
            try {
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
            } finally {
                isBroadcastExecuting = false
            }
        }
    }

    private fun appendBroadcastChunk(serverId: Int, chunk: String) {
        viewModelScope.launch(Dispatchers.Main.immediate) {
            val index = broadcastResults.indexOfFirst { it.serverId == serverId }
            if (index >= 0) {
                val current = broadcastResults[index]
                broadcastResults[index] = current.copy(output = current.output + chunk)
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
                                    java.net.Socket().use { socket ->
                                        socket.connect(java.net.InetSocketAddress(target, port), 800)
                                    }
                                    "Open"
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
        val next = limit.coerceIn(10, 1000)
        viewModelScope.launch {
            repository.insertSetting("alert_history_limit", next.toString())
            alertHistoryLimit = next
            repository.pruneAlertHistory(next)
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
            savedPin = null
            isAppLockEnabled = false
            useBiometrics = false
            isAppLocked = false
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
        repository.pruneAlertHistory(alertHistoryLimit)
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
        activeAlerts: List<ActiveAlertEntity>,
        settings: List<AppSettingEntity>,
        selection: BackupSelection = BackupSelection(),
    ): String {
        val serverArr = org.json.JSONArray()
        for (s in if (selection.servers) srvs else emptyList()) {
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
        for (k in if (selection.sshKeys) keys else emptyList()) {
            keyArr.put(org.json.JSONObject().apply {
                put("alias", k.alias)
                put("keyType", k.keyType)
                put("privateKey", k.privateKey)
                put("publicKey", k.publicKey)
                put("fingerprint", k.fingerprint)
            })
        }
        val profileArr = org.json.JSONArray()
        for (p in if (selection.credentialProfiles) profiles else emptyList()) {
            profileArr.put(org.json.JSONObject().apply {
                put("id", p.id)
                put("profileName", p.profileName)
                put("username", p.username)
                put("authType", p.authType)
                put("password", p.password)
                put("keyAlias", p.keyAlias)
            })
        }
        val scriptArr = org.json.JSONArray()
        // Back up only user-created or user-edited scripts. Pristine seeded presets (built-in Fleet
        // presets, homelab presets that still match their original command) are skipped — a fresh
        // install re-seeds those on its own, so exporting them would just duplicate defaults on restore.
        val scriptsForBackup = if (selection.scripts) customScriptsOnly(scripts) else emptyList()
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
        // edited rules. Defaults are re-applied automatically, so they don't belong in a backup.
        for (r in if (selection.alertRules) customRulesOnly(rules) else emptyList()) {
            ruleArr.put(org.json.JSONObject().apply {
                put("id", r.id); put("serverId", r.serverId); put("metricName", r.metricName)
                put("mountPoint", r.mountPoint); put("thresholdValue", r.thresholdValue.toDouble())
                put("severity", r.severity); put("triggerWindow", r.triggerWindow); put("enabled", r.enabled)
                put("notes", r.notes)
            })
        }
        val historyArr = org.json.JSONArray()
        for (h in if (selection.alertHistory) alertHistories else emptyList()) {
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
        for (w in if (selection.wolTargets) wolTargets else emptyList()) {
            wolArr.put(org.json.JSONObject().apply {
                put("name", w.name); put("macAddress", w.macAddress); put("broadcastIp", w.broadcastIp)
                put("ipAddress", w.ipAddress)
                put("port", w.port); put("notes", w.notes)
                put("lastWokenTime", w.lastWokenTime)
            })
        }
        val activeAlertArr = org.json.JSONArray()
        for (a in if (selection.activeAlerts) activeAlerts else emptyList()) {
            activeAlertArr.put(org.json.JSONObject().apply {
                put("ruleId", a.ruleId); put("serverId", a.serverId); put("metricName", a.metricName)
                put("currentValue", a.currentValue.toDouble()); put("thresholdValue", a.thresholdValue.toDouble())
                put("severity", a.severity); put("triggeredTime", a.triggeredTime)
                put("acknowledged", a.acknowledged); put("mutedUntil", a.mutedUntil)
            })
        }
        val settingsObj = org.json.JSONObject()
        // Never back up device-local security settings (PIN, lock, biometrics) — they shouldn't
        // travel between devices. Everything else (theme, retention, scoring, interval, …) is kept.
        val securityKeys = setOf("app_pin", "app_lock_enabled", "biometrics_enabled")
        if (selection.settings) {
            for (st in settings) {
                if (st.key in securityKeys || st.key.startsWith("sftp_last_path_")) continue
                settingsObj.put(st.key, st.value)
            }
        }

        // Pinned SSH host keys ride along with the servers they belong to, so a restored fleet
        // keeps its verified trust store instead of re-prompting TOFU for every host.
        val knownHostsObj = org.json.JSONObject()
        if (selection.servers) {
            SshHostKeyTrust.exportEntries().forEach { (key, value) -> knownHostsObj.put(key, value) }
        }

        // Opt-in crash logs (device/build-specific diagnostics). Preserved across a same-device
        // reinstall when the user explicitly selects them.
        val crashArr = org.json.JSONArray()
        if (selection.crashLogs) {
            CrashLog.all(getApplication()).forEach { entry ->
                crashArr.put(org.json.JSONObject().put("t", entry.timeMs).put("r", entry.report))
            }
        }

        return org.json.JSONObject()
            .put("format", "omniterm-backup")
            .put("schema", 4)
            .put("knownHosts", knownHostsObj)
            .put("servers", serverArr)
            .put("sshKeys", keyArr)
            .put("credentialProfiles", profileArr)
            .put("quickScripts", scriptArr)
            .put("alertRules", ruleArr)
            .put("activeAlerts", activeAlertArr)
            .put("alertHistory", historyArr)
            .put("wolTargets", wolArr)
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

    private fun gunzip(bytes: ByteArray): ByteArray =
        java.util.zip.GZIPInputStream(bytes.inputStream()).use { it.readBytes() }

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
        val env = org.json.JSONObject(backupText)
        if (!env.has("salt") || !env.has("iv") || !env.has("data")) return backupText
        val b64 = android.util.Base64.NO_WRAP
        val salt = android.util.Base64.decode(env.getString("salt"), b64)
        val iv = android.util.Base64.decode(env.getString("iv"), b64)
        val ct = android.util.Base64.decode(env.getString("data"), b64)
        val iterations = env.optInt("iterations", 120_000)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, deriveKey(passphrase, salt, iterations), javax.crypto.spec.GCMParameterSpec(128, iv))
        val decrypted = cipher.doFinal(ct)
        return String(if (env.optString("compression") == "gzip") gunzip(decrypted) else decrypted, Charsets.UTF_8)
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
        if (selection.hasSensitiveData() && passphrase.length < 12) { onResult(false, "Passphrase must be at least 12 characters for backups."); return }
        viewModelScope.launch {
            val srvs = repository.getAllServers()
            val keys = repository.getAllKeys()
            val profiles = repository.getAllProfiles()
            val scripts = repository.getAllScripts()
            val rules = repository.getAllRules()
            val alertHistories = repository.getAlertHistory()
            val wolTargets = repository.getAllWolTargets()
            val activeAlerts = repository.getActiveAlerts()
            val settings = backupSettingsSnapshot(repository.getAllSettings())
            // Counts shown in the result toast must match what buildBackupJson actually writes:
            // custom/edited scripts and rules only, with pristine defaults filtered out.
            val scriptsForCount = customScriptsOnly(scripts)
            val rulesForCount = customRulesOnly(rules)
            val encrypted = selection.hasSensitiveData()
            val ok = withContext(Dispatchers.IO) {
                try {
                    val json = buildBackupJson(
                        srvs, keys, profiles, scripts, rules, alertHistories, wolTargets,
                        activeAlerts, settings, selection
                    )
                    val payload = if (encrypted) encryptBackupJson(json, passphrase) else json
                    context.contentResolver.openOutputStream(uri)?.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                        ?: return@withContext false
                    true
                } catch (e: Exception) { e.printStackTrace(); false }
            }
            val mode = if (encrypted) "Encrypted" else "Plain"
            if (ok) {
                val now = System.currentTimeMillis()
                lastBackupExportTime = now
                repository.insertSetting("backup_last_export_time", now.toString())
            }
            onResult(ok, if (ok) "$mode backup written: ${if (selection.servers) srvs.size else 0} servers, ${if (selection.sshKeys) keys.size else 0} keys, ${if (selection.credentialProfiles) profiles.size else 0} profiles, ${if (selection.scripts) scriptsForCount.size else 0} scripts, ${if (selection.alertRules) rulesForCount.size else 0} rules, ${if (selection.alertHistory) alertHistories.size else 0} alert history, ${if (selection.wolTargets) wolTargets.size else 0} WoL, ${if (selection.settings) settings.size else 0} settings." else "Export failed.")
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
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val plain = decryptBackupToJson(envelopeText, passphrase)
                    val root = org.json.JSONObject(plain)
                    fun serverSelected(o: org.json.JSONObject, index: Int): Boolean {
                        if (selectedBackupServerIds == null) return true
                        val oldId = o.optInt("id", 0).takeIf { it != 0 } ?: (index + 1)
                        return oldId in selectedBackupServerIds
                    }
                    
                    val allowedKeyAliases = mutableSetOf<String>()
                    val allowedProfileOldIds = mutableSetOf<Int>()
                    if (selection.servers) {
                        val arr = root.optJSONArray("servers") ?: org.json.JSONArray()
                        var availableHostSlots = (hostLimit - repository.getAllServers().size).coerceAtLeast(0)
                        for (i in 0 until arr.length()) {
                            val o = arr.getJSONObject(i)
                            if (!serverSelected(o, i)) continue
                            val nm = o.getString("name")
                            if (repository.getServerByName(nm) != null) {
                                allowedKeyAliases.add(o.optString("authKeyAlias"))
                                allowedProfileOldIds.add(o.optInt("authProfileId", 0))
                                continue
                            }
                            if (availableHostSlots > 0) {
                                availableHostSlots--
                                allowedKeyAliases.add(o.optString("authKeyAlias"))
                                allowedProfileOldIds.add(o.optInt("authProfileId", 0))
                            }
                        }
                    }

                    val existingKeys = repository.getAllKeys().map { it.alias }.toMutableSet()
                    val existingProfiles = repository.getAllProfiles().associateBy { it.profileName }.toMutableMap()
                    var availableCredSlots = (credentialProfileLimit - existingProfiles.size - existingKeys.size).coerceAtLeast(0)

                    val keyArr = root.optJSONArray("sshKeys") ?: org.json.JSONArray()
                    var importedKeys = 0
                    var skippedKeysByLimit = 0
                    for (i in 0 until if (selection.sshKeys) keyArr.length() else 0) {
                        val o = keyArr.getJSONObject(i)
                        val alias = o.getString("alias")
                        if (selection.servers && !allowedKeyAliases.contains(alias)) continue
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
                    val profileArr = root.optJSONArray("credentialProfiles") ?: org.json.JSONArray()
                    var importedProfiles = 0
                    var skippedProfilesByLimit = 0
                    for (i in 0 until if (selection.credentialProfiles) profileArr.length() else 0) {
                        val o = profileArr.getJSONObject(i)
                        val name = o.getString("profileName")
                        val oldId = o.optInt("id", 0)
                        if (selection.servers && oldId != 0 && !allowedProfileOldIds.contains(oldId)) continue
                        val existing = existingProfiles[name]
                        if (existing != null) {
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
                            if (oldId != 0) serverIdMap[oldId] = existing.id
                            restoredHosts.add(existing.host to existing.port)
                            continue
                        }
                        if (!selection.servers) continue
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
                    if (selection.servers) {
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
                    for (i in 0 until if (selection.scripts) scriptArr.length() else 0) {
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
                    for (i in 0 until if (selection.alertRules) ruleArr.length() else 0) {
                        val o = ruleArr.getJSONObject(i)
                        val oldRuleId = o.optInt("id", 0)
                        val oldServerId = o.optInt("serverId", 0)
                        val mappedServerId = if (oldServerId == 0) 0 else serverIdMap[oldServerId] ?: continue
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

                    val existingActiveAlertKeys = repository.getActiveAlerts()
                        .map { "${it.ruleId}|${it.serverId}|${it.metricName}" }.toMutableSet()
                    val activeAlertArr = root.optJSONArray("activeAlerts") ?: org.json.JSONArray()
                    var importedActiveAlerts = 0
                    for (i in 0 until if (selection.activeAlerts) activeAlertArr.length() else 0) {
                        val o = activeAlertArr.getJSONObject(i)
                        val oldServerId = o.optInt("serverId", 0)
                        val mappedServerId = if (oldServerId == 0) 0 else serverIdMap[oldServerId] ?: continue
                        val mappedRuleId = ruleIdMap[o.optInt("ruleId", 0)] ?: o.optInt("ruleId", 0)
                        val metric = o.optString("metricName")
                        val key = "$mappedRuleId|$mappedServerId|$metric"
                        if (mappedRuleId <= 0 || key in existingActiveAlertKeys) continue
                        repository.insertAlert(
                            ActiveAlertEntity(
                                ruleId = mappedRuleId, serverId = mappedServerId, metricName = metric,
                                currentValue = o.optDouble("currentValue", 0.0).toFloat(),
                                thresholdValue = o.optDouble("thresholdValue", 0.0).toFloat(),
                                severity = o.optString("severity", "WARNING"),
                                triggeredTime = o.optLong("triggeredTime", System.currentTimeMillis()),
                                acknowledged = o.optBoolean("acknowledged", false),
                                mutedUntil = o.optLong("mutedUntil", 0L),
                            )
                        )
                        existingActiveAlertKeys.add(key)
                        importedActiveAlerts++
                    }

                    // Alert history (re-point serverId; keep newest N after import).
                    val historyArr = root.optJSONArray("alertHistory") ?: org.json.JSONArray()
                    var importedHistory = 0
                    for (i in 0 until if (selection.alertHistory) historyArr.length() else 0) {
                        val o = historyArr.getJSONObject(i)
                        val mappedServerId = serverIdMap[o.optInt("serverId", 0)] ?: continue
                        val historyTime = o.optLong("historyTime", System.currentTimeMillis())
                        repository.insertAlertHistory(
                            AlertHistoryEntity(
                                activeAlertId = o.optInt("activeAlertId", 0).takeIf { it > 0 } ?: (-(historyTime % Int.MAX_VALUE).toInt()).coerceAtMost(-1),
                                serverId = mappedServerId,
                                serverName = repository.getServerById(mappedServerId)?.name ?: o.optString("serverName", "server"),
                                metricName = o.optString("metricName"),
                                currentValue = o.optDouble("currentValue", 0.0).toFloat(),
                                thresholdValue = o.optDouble("thresholdValue", 0.0).toFloat(),
                                severity = o.optString("severity", "WARNING"),
                                triggeredTime = o.optLong("triggeredTime", historyTime),
                                historyTime = historyTime,
                                status = o.optString("status", "acknowledged"),
                            )
                        )
                        importedHistory++
                    }
                    if (selection.alertHistory) repository.pruneAlertHistory(alertHistoryLimit)

                    // Wake-on-LAN targets (dedup by MAC).
                    val existingWol = repository.getAllWolTargets().map { it.macAddress.lowercase() }.toMutableSet()
                    val wolArr = root.optJSONArray("wolTargets") ?: org.json.JSONArray()
                    var importedWol = 0
                    for (i in 0 until if (selection.wolTargets) wolArr.length() else 0) {
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

                    // App settings / config (overwrite by key — full restore of preferences).
                    val settingsObj = root.optJSONObject("settings")
                    var importedSettings = 0
                    if (settingsObj != null && selection.settings) {
                        // Defensive: never restore device-local security keys even if an old backup carried them.
                        val securityKeys = setOf("app_pin", "app_lock_enabled", "biometrics_enabled")
                        val it = settingsObj.keys()
                        // Per-server settings are keyed by the OLD server id; re-point them to the
                        // restored id. If the owning server wasn't restored, skip the setting entirely
                        // so we don't leave orphaned per-server rows pointing at a nonexistent server.
                        val perServerPrefixes = listOf("sftp_bookmarks_")
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
                            repository.insertSetting(newKey, settingsObj.getString(originalKey))
                            importedSettings++
                        }
                    }

                    // Crash logs (opt-in). Merge into the on-device history newest-first; deduped by
                    // timestamp so re-importing the same backup doesn't pile up duplicates.
                    val crashArr = root.optJSONArray("crashLogs") ?: org.json.JSONArray()
                    var importedCrashLogs = 0
                    if (selection.crashLogs) {
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
                            "$importedSettings setting(s), $importedCrashLogs crash log(s)." + skippedSuffix,
                    )
                } catch (e: javax.crypto.AEADBadTagException) {
                    Pair(false, "Wrong passphrase or corrupted backup.")
                } catch (e: org.json.JSONException) {
                    Pair(false, "Not a valid OmniTerm backup file.")
                } catch (e: Exception) {
                    Pair(false, e.message ?: "Restore failed.")
                }
            }
            reconcileHostLimit("Restored data exceeds the free Play Store host limit. Choose the one host to keep.")
            onResult(result.first, result.second)
        }
    }

    private fun jsonNullableString(obj: org.json.JSONObject, key: String): String? =
        if (!obj.has(key) || obj.isNull(key)) null else obj.optString(key)
}
