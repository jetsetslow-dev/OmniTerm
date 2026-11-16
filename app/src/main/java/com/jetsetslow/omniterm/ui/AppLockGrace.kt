package com.jetsetslow.omniterm.ui

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import androidx.annotation.RequiresApi
import androidx.annotation.VisibleForTesting

/**
 * Time since boot that keeps counting while the phone sleeps, and which boot it belongs to. Neither
 * moves when the phone's clock is changed, so App Lock's window cannot be stretched by setting it.
 */
internal interface AppLockClock {
    /** [SystemClock.elapsedRealtime]: CLOCK_BOOTTIME, which keeps counting through deep sleep. */
    fun elapsedRealtimeMs(): Long

    /** [Settings.Global.BOOT_COUNT], or null when the phone does not report one. */
    fun bootCount(): Int?
}

internal class SystemAppLockClock(context: Context) : AppLockClock {
    private val resolver = context.applicationContext.contentResolver

    override fun elapsedRealtimeMs(): Long = SystemClock.elapsedRealtime()

    override fun bootCount(): Int? = runCatching {
        Settings.Global.getInt(resolver, Settings.Global.BOOT_COUNT, -1)
    }.getOrNull()?.takeIf { it >= 0 }
}

/**
 * Written when OmniTerm stops being visible while it is unlocked, so a window can outlive the
 * process the system closes. It holds no secret: which boot, the time since boot, the process and
 * when the installed build was installed ([installStamp], PackageInfo.lastUpdateTime, compared
 * only for equality, so an update or a reinstall locks). It lives in its own private SharedPreferences file, which Android backup excludes
 * (`data_extraction_rules.xml`, `backup_rules.xml`) and the in-app backup never reads.
 */
internal data class AppLockAwayRecord(
    val bootCount: Int,
    val leftAtMs: Long,
    val pid: Int,
    val installStamp: Long,
)

internal interface AppLockAwayStore {
    fun read(): AppLockAwayRecord?
    fun write(record: AppLockAwayRecord)
    fun clear()
}

internal class PrefsAppLockAwayStore(context: Context) : AppLockAwayStore {
    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(): AppLockAwayRecord? = runCatching {
        if (!prefs.contains(KEY_LEFT_AT)) return null
        AppLockAwayRecord(
            bootCount = prefs.getInt(KEY_BOOT, -1),
            leftAtMs = prefs.getLong(KEY_LEFT_AT, -1L),
            pid = prefs.getInt(KEY_PID, -1),
            installStamp = prefs.getLong(KEY_INSTALL, -1L),
        ).takeIf { it.bootCount >= 0 && it.leftAtMs >= 0L && it.pid > 0 }
    }.getOrNull()

    // commit, not apply: the next thing that happens to a stopped app may be the system ending its
    // process, and the record must already be on disk by then.
    @android.annotation.SuppressLint("ApplySharedPref")
    override fun write(record: AppLockAwayRecord) {
        prefs.edit()
            .putInt(KEY_BOOT, record.bootCount)
            .putLong(KEY_LEFT_AT, record.leftAtMs)
            .putInt(KEY_PID, record.pid)
            .putLong(KEY_INSTALL, record.installStamp)
            .commit()
    }

    @android.annotation.SuppressLint("ApplySharedPref")
    override fun clear() {
        if (prefs.all.isNotEmpty()) prefs.edit().clear().commit()
    }

    companion object {
        const val PREFS_NAME = "app_lock_away"
        private const val KEY_BOOT = "boot_count"
        private const val KEY_LEFT_AT = "left_at_elapsed_ms"
        private const val KEY_PID = "pid"
        private const val KEY_INSTALL = "install_stamp"
    }
}

/** How the process that left an [AppLockAwayRecord] ended, as far as the decision needs it. */
internal enum class PreviousExit {
    /** Android closed it to free memory or tidy up cached apps: the window still holds. */
    CLOSED_BY_SYSTEM,

    /** Force stop, a crash, an update, a permission change, or a reason the phone does not give. */
    LOCKS,
}

internal fun interface PreviousExitReader {
    fun exitOf(pid: Int): PreviousExit
}

/**
 * [android.app.ApplicationExitInfo] reasons that mean Android itself closed a backgrounded
 * OmniTerm. Anything else locks, including reasons a later Android version adds. The values are
 * written out because the constants only exist from Android 11; AppLockGraceTest checks them
 * against the platform's.
 */
internal val CLOSED_BY_SYSTEM_REASONS = setOf(
    2, // REASON_SIGNALED: killed by a signal, as an unreported low-memory kill is.
    3, // REASON_LOW_MEMORY: the low-memory killer.
    9, // REASON_EXCESSIVE_RESOURCE_USAGE: a cached app using too much CPU.
    12, // REASON_DEPENDENCY_DIED: a process it depended on went away.
    13, // REASON_OTHER: housekeeping such as "too many cached apps".
    14, // REASON_FREEZER: the cached-app freezer.
)

internal const val EXIT_REASON_USER_REQUESTED = 10

/**
 * Whether the way the previous process ended lets its window carry over.
 *
 * - Android 10 and older keep no exit reasons, so a force stop or a crash cannot be told apart from
 *   the system closing the app: every new process locks there, as it always has.
 * - Android 11 to 14 report Force stop, `am kill`, and swiping the app out of Recents all as
 *   REASON_USER_REQUESTED, so all three lock.
 * - Android 15 and later also say whether this start followed a force stop
 *   ([android.app.ApplicationStartInfo.wasForceStopped]). A force stop locks; the other
 *   user-requested ends (Recents, `am kill`) keep the window like any other close.
 * - With no exit record at all for that process, it locks.
 */
internal fun classifyPreviousExit(sdkInt: Int, exitReason: Int?, forceStopped: Boolean?): PreviousExit {
    if (sdkInt < Build.VERSION_CODES.R) return PreviousExit.LOCKS
    if (forceStopped == true) return PreviousExit.LOCKS
    val reason = exitReason ?: return PreviousExit.LOCKS
    if (reason in CLOSED_BY_SYSTEM_REASONS) return PreviousExit.CLOSED_BY_SYSTEM
    if (
        reason == EXIT_REASON_USER_REQUESTED &&
        sdkInt >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
        forceStopped == false
    ) {
        return PreviousExit.CLOSED_BY_SYSTEM
    }
    return PreviousExit.LOCKS
}

internal class SystemPreviousExitReader(context: Context) : PreviousExitReader {
    private val appContext = context.applicationContext

    override fun exitOf(pid: Int): PreviousExit {
        val sdk = Build.VERSION.SDK_INT
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return classifyPreviousExit(sdk, null, null)
        val am = appContext.getSystemService(ActivityManager::class.java)
            ?: return PreviousExit.LOCKS
        val forceStopped: Boolean? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            newestStartWasForceStopped(am)
        } else {
            null
        }
        return classifyPreviousExit(sdk, exitReason(am, pid), forceStopped)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitReason(am: ActivityManager, pid: Int): Int? = runCatching {
        am.getHistoricalProcessExitReasons(appContext.packageName, pid, 1)
            .firstOrNull { it.pid == pid }
            ?.reason
    }.getOrNull()

    /** The newest start is this process's own. */
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun newestStartWasForceStopped(am: ActivityManager): Boolean? = runCatching {
        am.getHistoricalProcessStartReasons(1).firstOrNull()?.wasForceStopped()
    }.getOrNull()
}

/**
 * App Lock's unlocked window, for the whole process rather than one screen.
 *
 * The window opens when OmniTerm stops being visible while unlocked (never for a rotation or other
 * configuration change) and closes when it is visible again: within the chosen time it stays
 * unlocked, after it, it locks. One instance serves every Activity and ViewModel in the process,
 * so a screen rebuilt behind the user's back (Don't keep activities, the task removed and reopened
 * from a notification, Back to exit and open again) sees the same window. When the time is longer
 * than zero, the window is also written to disk, so it survives Android closing the process in the
 * background. It never survives a reboot, an update, a force stop or a crash (see
 * [classifyPreviousExit]), and "Immediately" (zero) keeps nothing on disk.
 */
internal class AppLockGraceWindow(
    val clock: AppLockClock,
    private val store: AppLockAwayStore,
    private val previousExit: PreviousExitReader,
    private val pid: Int,
    private val installStamp: Long,
) {
    private var leftAtMs: Long? = null
    private var restoreChecked = false

    fun nowMs(): Long = clock.elapsedRealtimeMs()

    /** OmniTerm stopped being visible. Only an unlocked app with App Lock on opens a window. */
    @Synchronized
    fun noteLeftForeground(
        unlocked: Boolean,
        lockEnabled: Boolean,
        timeoutMs: Long,
        nowMs: Long = nowMs(),
    ) {
        restoreFromPreviousProcess()
        if (!lockEnabled || !unlocked) {
            close()
            return
        }
        // Keep the earliest unmatched stop if Android delivers duplicate lifecycle callbacks.
        val since = leftAtMs ?: nowMs.also { leftAtMs = it }
        val boot = clock.bootCount()
        if (normalizeAppLockBackgroundTimeout(timeoutMs) > 0L && boot != null) {
            store.write(AppLockAwayRecord(boot, since, pid, installStamp))
        } else {
            store.clear()
        }
    }

    /** OmniTerm is visible again. True when the time away used up the window: lock now. */
    @Synchronized
    fun shouldRelockOnReturn(
        timeoutMs: Long,
        lockEnabled: Boolean,
        hasPin: Boolean,
        nowMs: Long = nowMs(),
    ): Boolean {
        restoreFromPreviousProcess()
        val since = leftAtMs ?: return false
        close()
        if (!lockEnabled || !hasPin) return false
        return !withinWindow(since, timeoutMs, nowMs)
    }

    /**
     * A new screen is deciding whether it starts locked. True only while a window is open and still
     * within its time; the window is used up either way.
     */
    @Synchronized
    fun startsUnlocked(
        timeoutMs: Long,
        lockEnabled: Boolean,
        hasPin: Boolean,
        nowMs: Long = nowMs(),
    ): Boolean {
        restoreFromPreviousProcess()
        val since = leftAtMs ?: return false
        close()
        return lockEnabled && hasPin && withinWindow(since, timeoutMs, nowMs)
    }

    /** Unlock, lock, Lock now, App Lock off or a new PIN: no window is open after any of them. */
    @Synchronized
    fun close() {
        leftAtMs = null
        store.clear()
    }

    private fun withinWindow(since: Long, timeoutMs: Long, nowMs: Long): Boolean {
        val timeout = normalizeAppLockBackgroundTimeout(timeoutMs)
        // Time since boot never runs backwards within one boot; if it seems to, lock.
        return timeout > 0L && nowMs >= since && nowMs - since < timeout
    }

    /**
     * The first time this process asks, take over a window the previous process left on disk, if
     * it is from this boot and this installation and that process was closed by the system.
     */
    private fun restoreFromPreviousProcess() {
        if (restoreChecked) return
        restoreChecked = true
        val record = store.read() ?: return
        store.clear()
        if (record.pid == pid) return
        if (record.installStamp != installStamp) return
        val boot = clock.bootCount() ?: return
        if (record.bootCount != boot) return
        if (previousExit.exitOf(record.pid) != PreviousExit.CLOSED_BY_SYSTEM) return
        leftAtMs = record.leftAtMs
    }
}

/** The process's one [AppLockGraceWindow]. */
internal object AppLockGrace {
    @Volatile
    private var window: AppLockGraceWindow? = null

    fun get(context: Context): AppLockGraceWindow =
        window ?: synchronized(this) {
            window ?: create(context.applicationContext).also { window = it }
        }

    /**
     * Called from the crash handler: a crash never leaves a window open for the next start. Must
     * not throw.
     */
    fun forgetAfterCrash(context: Context) {
        runCatching { window?.close() ?: PrefsAppLockAwayStore(context).clear() }
    }

    @VisibleForTesting
    fun replaceForTests(replacement: AppLockGraceWindow?) {
        synchronized(this) { window = replacement }
    }

    private fun create(context: Context) = AppLockGraceWindow(
        clock = SystemAppLockClock(context),
        store = PrefsAppLockAwayStore(context),
        previousExit = SystemPreviousExitReader(context),
        pid = android.os.Process.myPid(),
        installStamp = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        }.getOrDefault(-1L),
    )
}
