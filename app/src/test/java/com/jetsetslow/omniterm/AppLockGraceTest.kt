package com.jetsetslow.omniterm

import android.app.ApplicationExitInfo
import com.jetsetslow.omniterm.ui.AppLockAwayRecord
import com.jetsetslow.omniterm.ui.AppLockAwayStore
import com.jetsetslow.omniterm.ui.AppLockClock
import com.jetsetslow.omniterm.ui.AppLockGraceWindow
import com.jetsetslow.omniterm.ui.CLOSED_BY_SYSTEM_REASONS
import com.jetsetslow.omniterm.ui.EXIT_REASON_USER_REQUESTED
import com.jetsetslow.omniterm.ui.PreviousExit
import com.jetsetslow.omniterm.ui.classifyPreviousExit
import com.jetsetslow.omniterm.ui.shouldRecordAppBackground
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * App Lock's unlocked window, with an injected clock, boot counter and record store, over every
 * scenario the 2026-11-13 report and its fix list name, for a 10-minute and a 60-minute window:
 *
 * - (a) switch apps and come back within the window: unlocked, in the same process;
 * - (b) come back after it, or exactly at it: locked;
 * - (c) rotation, theme or font change: never starts the countdown;
 * - (d) a new screen in the same process (Don't keep activities, Back to exit, the task removed and
 *   reopened from a notification while the keep-alive service runs): the same window;
 * - (e) Android closing the process in the background (low memory, the freezer, cached-app trims,
 *   `am kill` on Android 15+), reopened within or after the window;
 * - (f) a phone restart: locked;
 * - (g) a force stop: locked;
 * - (h) a crash: locked;
 * - (i) an update or reinstall: locked;
 * - (j) Lock now, leaving while locked, "Immediately", App Lock off, time running backwards: no
 *   window, or locked.
 */
class AppLockGraceTest {
    private val windows = listOf(10 * MINUTE, 60 * MINUTE)

    private class FakeClock(var now: Long = 50 * MINUTE, var boot: Int? = 41) : AppLockClock {
        override fun elapsedRealtimeMs() = now
        override fun bootCount() = boot
    }

    private class MemoryStore : AppLockAwayStore {
        var record: AppLockAwayRecord? = null
        var writes = 0
        override fun read() = record
        override fun write(record: AppLockAwayRecord) {
            this.record = record
            writes++
        }
        override fun clear() {
            record = null
        }
    }

    /** One process: its window over a store that outlives it, as the SharedPreferences file does. */
    private class Process(
        val clock: FakeClock,
        val store: MemoryStore,
        pid: Int,
        exit: PreviousExit = PreviousExit.CLOSED_BY_SYSTEM,
        installStamp: Long = 1_700_000_000_000L,
    ) {
        var askedAboutPid: Int? = null
        val window = AppLockGraceWindow(
            clock = clock,
            store = store,
            previousExit = { pid -> askedAboutPid = pid; exit },
            pid = pid,
            installStamp = installStamp,
        )

        fun leaveUnlocked(timeout: Long) = window.noteLeftForeground(true, true, timeout)
        fun returns(timeout: Long) = window.shouldRelockOnReturn(timeout, lockEnabled = true, hasPin = true)
        fun newScreenUnlocked(timeout: Long) = window.startsUnlocked(timeout, lockEnabled = true, hasPin = true)
    }

    @Test
    fun a_switchingAppsAndComingBackWithinTheWindowStaysUnlocked() {
        for (timeout in windows) {
            val clock = FakeClock()
            val app = Process(clock, MemoryStore(), pid = 1000)
            app.leaveUnlocked(timeout)
            clock.now += timeout - 1
            assertFalse("${timeout / MINUTE} min: back just inside the window", app.returns(timeout))
        }
    }

    @Test
    fun b_comingBackAfterTheWindowOrExactlyAtItLocks() {
        for (timeout in windows) {
            for (away in listOf(timeout, timeout + 1, timeout + 5 * MINUTE, 23 * 60 * MINUTE)) {
                val clock = FakeClock()
                val app = Process(clock, MemoryStore(), pid = 1000)
                app.leaveUnlocked(timeout)
                clock.now += away
                assertTrue("${timeout / MINUTE} min window, away $away ms", app.returns(timeout))
            }
        }
    }

    @Test
    fun b_eachReturnUsesUpItsWindow() {
        val clock = FakeClock()
        val store = MemoryStore()
        val app = Process(clock, store, pid = 1000)
        app.leaveUnlocked(10 * MINUTE)
        clock.now += 9 * MINUTE
        assertFalse(app.returns(10 * MINUTE))
        assertNull("returning deletes the record", store.record)
        // A later return with no new leave has nothing to measure; the next leave starts afresh.
        clock.now += 30 * MINUTE
        assertFalse(app.returns(10 * MINUTE))
        app.leaveUnlocked(10 * MINUTE)
        clock.now += 11 * MINUTE
        assertTrue(app.returns(10 * MINUTE))
    }

    @Test
    fun c_aConfigurationChangeNeverStartsTheCountdown() {
        assertFalse(shouldRecordAppBackground(isChangingConfigurations = true))
        assertTrue(shouldRecordAppBackground(isChangingConfigurations = false))
    }

    @Test
    fun d_aNewScreenInTheSameProcessSeesTheSameWindow() {
        for (timeout in windows) {
            val clock = FakeClock()
            val app = Process(clock, MemoryStore(), pid = 1000)
            app.leaveUnlocked(timeout)
            clock.now += timeout - MINUTE
            assertTrue("${timeout / MINUTE} min: rebuilt screen within the window", app.newScreenUnlocked(timeout))
            // The window is used up: the rebuilt screen's own return finds nothing to relock for.
            assertFalse(app.returns(timeout))

            app.leaveUnlocked(timeout)
            clock.now += timeout
            assertFalse("${timeout / MINUTE} min: rebuilt screen after the window", app.newScreenUnlocked(timeout))
        }
    }

    @Test
    fun d_aNewScreenWithNoOpenWindowStartsLocked() {
        val app = Process(FakeClock(), MemoryStore(), pid = 1000)
        assertFalse(app.newScreenUnlocked(60 * MINUTE))
    }

    @Test
    fun e_theSystemClosingTheProcessKeepsTheWindow() {
        for (timeout in windows) {
            for (inside in listOf(true, false)) {
                val clock = FakeClock()
                val store = MemoryStore()
                Process(clock, store, pid = 1000).leaveUnlocked(timeout)
                assertEquals("left once, written once", 1, store.writes)
                clock.now += if (inside) timeout - 1 else timeout
                val next = Process(clock, store, pid = 2000)
                assertEquals(
                    "${timeout / MINUTE} min, inside=$inside",
                    inside,
                    next.newScreenUnlocked(timeout),
                )
                assertEquals("the exit asked about is the process that left", 1000, next.askedAboutPid)
                assertNull("the record is used once", store.record)
            }
        }
    }

    @Test
    fun e_theWindowCountsFromTheFirstLeaveAcrossProcesses() {
        val clock = FakeClock()
        val store = MemoryStore()
        Process(clock, store, pid = 1000).leaveUnlocked(60 * MINUTE)
        clock.now += 59 * MINUTE
        // The new process restored the window but the user has not come back yet: a screen that
        // the system rebuilds and stops again must not restart the clock.
        val second = Process(clock, store, pid = 2000)
        second.leaveUnlocked(60 * MINUTE)
        clock.now += 2 * MINUTE
        assertTrue(second.returns(60 * MINUTE))
    }

    @Test
    fun e_theCurrentTimeoutDecides() {
        val clock = FakeClock()
        val store = MemoryStore()
        Process(clock, store, pid = 1000).leaveUnlocked(60 * MINUTE)
        clock.now += 20 * MINUTE
        assertFalse(Process(clock, store, pid = 2000).newScreenUnlocked(10 * MINUTE))
    }

    @Test
    fun f_aPhoneRestartLocks() {
        for (timeout in windows) {
            for (boot in listOf(42, null)) {
                val clock = FakeClock()
                val store = MemoryStore()
                Process(clock, store, pid = 1000).leaveUnlocked(timeout)
                clock.boot = boot
                clock.now = MINUTE // time since boot starts again at a restart
                assertFalse("boot=$boot", Process(clock, store, pid = 1000).newScreenUnlocked(timeout))
            }
        }
    }

    @Test
    fun f_noBootCountMeansNothingIsKeptOnDisk() {
        val clock = FakeClock(boot = null)
        val store = MemoryStore()
        Process(clock, store, pid = 1000).leaveUnlocked(60 * MINUTE)
        assertNull(store.record)
    }

    @Test
    fun g_h_i_forceStopCrashAndUnexplainedEndsLock() {
        for (timeout in windows) {
            val clock = FakeClock()
            val store = MemoryStore()
            Process(clock, store, pid = 1000).leaveUnlocked(timeout)
            clock.now += MINUTE
            assertFalse(Process(clock, store, pid = 2000, exit = PreviousExit.LOCKS).newScreenUnlocked(timeout))
        }
    }

    @Test
    fun g_forceStopIsToldApartOnlyWhereAndroidSaysSo() {
        // Android 15+: the start says whether a force stop came before it.
        assertEquals(PreviousExit.LOCKS, classifyPreviousExit(35, EXIT_REASON_USER_REQUESTED, forceStopped = true))
        assertEquals(PreviousExit.CLOSED_BY_SYSTEM, classifyPreviousExit(35, EXIT_REASON_USER_REQUESTED, forceStopped = false))
        assertEquals(PreviousExit.LOCKS, classifyPreviousExit(36, ApplicationExitInfo.REASON_LOW_MEMORY, forceStopped = true))
        // Without the start's answer, a user-requested end locks.
        assertEquals(PreviousExit.LOCKS, classifyPreviousExit(35, EXIT_REASON_USER_REQUESTED, forceStopped = null))
        // Android 11–14 report Force stop, Recents and am kill alike: all lock.
        for (sdk in 30..34) {
            assertEquals(PreviousExit.LOCKS, classifyPreviousExit(sdk, EXIT_REASON_USER_REQUESTED, forceStopped = null))
            assertEquals(PreviousExit.CLOSED_BY_SYSTEM, classifyPreviousExit(sdk, ApplicationExitInfo.REASON_LOW_MEMORY, null))
        }
    }

    @Test
    fun h_crashesAnrsAndOtherDeliberateEndsLock() {
        val locking = listOf(
            ApplicationExitInfo.REASON_UNKNOWN,
            ApplicationExitInfo.REASON_EXIT_SELF,
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            ApplicationExitInfo.REASON_PERMISSION_CHANGE,
            ApplicationExitInfo.REASON_USER_STOPPED,
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE,
            ApplicationExitInfo.REASON_PACKAGE_UPDATED,
            99, // a reason a later Android adds
        )
        for (reason in locking) {
            for (sdk in listOf(30, 34, 35, 37)) {
                assertEquals("reason $reason on $sdk", PreviousExit.LOCKS, classifyPreviousExit(sdk, reason, forceStopped = false))
            }
        }
        assertEquals("no exit record", PreviousExit.LOCKS, classifyPreviousExit(35, null, forceStopped = false))
    }

    @Test
    fun e_systemReasonsKeepTheWindowFromAndroid11() {
        val system = listOf(
            ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            ApplicationExitInfo.REASON_DEPENDENCY_DIED,
            ApplicationExitInfo.REASON_OTHER,
            ApplicationExitInfo.REASON_FREEZER,
        )
        assertEquals("the written-out values match the platform's", system.toSet(), CLOSED_BY_SYSTEM_REASONS)
        assertEquals(ApplicationExitInfo.REASON_USER_REQUESTED, EXIT_REASON_USER_REQUESTED)
        for (reason in system) {
            assertEquals(PreviousExit.CLOSED_BY_SYSTEM, classifyPreviousExit(30, reason, null))
            assertEquals(PreviousExit.CLOSED_BY_SYSTEM, classifyPreviousExit(35, reason, false))
        }
    }

    @Test
    fun k_android10AndOlderCannotSayWhySoANewProcessLocks() {
        for (sdk in 24..29) {
            assertEquals(PreviousExit.LOCKS, classifyPreviousExit(sdk, ApplicationExitInfo.REASON_LOW_MEMORY, null))
        }
    }

    @Test
    fun i_anUpdateOrReinstallLocks() {
        for (timeout in windows) {
            val clock = FakeClock()
            val store = MemoryStore()
            Process(clock, store, pid = 1000, installStamp = 1L).leaveUnlocked(timeout)
            clock.now += MINUTE
            assertFalse(Process(clock, store, pid = 2000, installStamp = 2L).newScreenUnlocked(timeout))
        }
    }

    @Test
    fun j_lockNowAndEveryLockCloseTheWindow() {
        for (timeout in windows) {
            val clock = FakeClock()
            val store = MemoryStore()
            val app = Process(clock, store, pid = 1000)
            app.leaveUnlocked(timeout)
            app.window.close()
            assertNull(store.record)
            clock.now += MINUTE
            assertFalse(app.newScreenUnlocked(timeout))
            assertFalse(Process(clock, store, pid = 2000).newScreenUnlocked(timeout))
        }
    }

    @Test
    fun j_leavingWhileLockedOrWithAppLockOffOpensNoWindow() {
        val clock = FakeClock()
        val store = MemoryStore()
        val app = Process(clock, store, pid = 1000)
        app.leaveUnlocked(60 * MINUTE)
        app.window.noteLeftForeground(unlocked = false, lockEnabled = true, timeoutMs = 60 * MINUTE)
        assertNull("leaving while locked forgets an earlier window", store.record)
        assertFalse(app.newScreenUnlocked(60 * MINUTE))

        app.window.noteLeftForeground(unlocked = true, lockEnabled = false, timeoutMs = 60 * MINUTE)
        assertNull(store.record)
        assertFalse(app.window.startsUnlocked(60 * MINUTE, lockEnabled = true, hasPin = true))
    }

    @Test
    fun j_immediatelyKeepsNothingOnDiskAndAlwaysLocks() {
        val clock = FakeClock()
        val store = MemoryStore()
        val app = Process(clock, store, pid = 1000)
        app.leaveUnlocked(0L)
        assertNull(store.record)
        assertTrue("same instant still locks", app.returns(0L))
        app.leaveUnlocked(0L)
        assertFalse(app.newScreenUnlocked(0L))
    }

    @Test
    fun j_timeRunningBackwardsLocks() {
        val clock = FakeClock()
        val store = MemoryStore()
        Process(clock, store, pid = 1000).leaveUnlocked(60 * MINUTE)
        clock.now -= 1
        assertFalse(Process(clock, store, pid = 2000).newScreenUnlocked(60 * MINUTE))
    }

    @Test
    fun j_aRecordFromThisVeryProcessIsNotTakenOver() {
        // A process never restores its own record: it can only be in memory already.
        val clock = FakeClock()
        val store = MemoryStore()
        store.record = AppLockAwayRecord(41, clock.now, 1000, 1_700_000_000_000L)
        assertFalse(Process(clock, store, pid = 1000).newScreenUnlocked(60 * MINUTE))
    }

    @Test
    fun theRecordHoldsNothingButTimesAndNumbers() {
        val clock = FakeClock()
        val store = MemoryStore()
        Process(clock, store, pid = 1000).leaveUnlocked(60 * MINUTE)
        assertEquals(AppLockAwayRecord(41, 50 * MINUTE, 1000, 1_700_000_000_000L), store.record)
    }

    private companion object {
        const val MINUTE = 60_000L
    }
}
