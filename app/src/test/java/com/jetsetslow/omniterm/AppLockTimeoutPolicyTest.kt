package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.AppLockTimeoutDraft
import com.jetsetslow.omniterm.ui.AppLockAwayRecord
import com.jetsetslow.omniterm.ui.AppLockAwayStore
import com.jetsetslow.omniterm.ui.AppLockClock
import com.jetsetslow.omniterm.ui.AppLockGraceWindow
import com.jetsetslow.omniterm.ui.PreviousExit
import com.jetsetslow.omniterm.ui.DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS
import com.jetsetslow.omniterm.ui.MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS
import com.jetsetslow.omniterm.ui.normalizeAppLockBackgroundTimeout
import com.jetsetslow.omniterm.ui.shouldRecordAppBackground
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLockTimeoutPolicyTest {
    private fun window() = AppLockGraceWindow(
        clock = object : AppLockClock {
            override fun elapsedRealtimeMs() = 0L
            override fun bootCount(): Int? = 1
        },
        store = object : AppLockAwayStore {
            override fun read(): AppLockAwayRecord? = null
            override fun write(record: AppLockAwayRecord) = Unit
            override fun clear() = Unit
        },
        previousExit = { PreviousExit.LOCKS },
        pid = 100,
        installStamp = 1L,
    )

    @Test
    fun locksAtConfiguredBoundary() {
        val tracker = window()
        tracker.noteLeftForeground(unlocked = true, lockEnabled = true, timeoutMs = 30_000L, nowMs = 1_000L)

        assertTrue(
            tracker.shouldRelockOnReturn(
                timeoutMs = 30_000L,
                lockEnabled = true,
                hasPin = true,
                nowMs = 31_000L,
            ),
        )
    }

    @Test
    fun returningBeforeTimeoutConsumesThatBackgroundInterval() {
        val tracker = window()
        tracker.noteLeftForeground(true, true, 30_000L, nowMs = 1_000L)

        assertFalse(tracker.shouldRelockOnReturn(30_000L, true, true, nowMs = 30_999L))
        assertFalse(tracker.shouldRelockOnReturn(30_000L, true, true, nowMs = 90_000L))
    }

    @Test
    fun duplicateStopsKeepEarliestBackgroundTime() {
        val tracker = window()
        tracker.noteLeftForeground(true, true, 30_000L, nowMs = 1_000L)
        tracker.noteLeftForeground(true, true, 30_000L, nowMs = 20_000L)

        assertTrue(tracker.shouldRelockOnReturn(30_000L, true, true, nowMs = 31_000L))
    }

    @Test
    fun disabledLockAndMissingPinDoNotLockButTimeRunningBackwardsDoes() {
        fun result(enabled: Boolean, hasPin: Boolean, nowMs: Long): Boolean {
            val tracker = window()
            tracker.noteLeftForeground(true, true, 0L, nowMs = 10_000L)
            return tracker.shouldRelockOnReturn(0L, enabled, hasPin, nowMs)
        }

        assertFalse(result(enabled = false, hasPin = true, nowMs = 10_000L))
        assertFalse(result(enabled = true, hasPin = false, nowMs = 10_000L))
        // Time since boot cannot run backwards within one process; if it seems to, fail closed.
        val tracker = window()
        tracker.noteLeftForeground(true, true, 60_000L, nowMs = 10_000L)
        assertTrue(tracker.shouldRelockOnReturn(60_000L, true, true, nowMs = 9_999L))
    }

    @Test
    fun persistedTimeoutIsDefaultedAndBounded() {
        assertEquals(DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS, normalizeAppLockBackgroundTimeout(null))
        assertEquals(0L, normalizeAppLockBackgroundTimeout(-1L))
        assertEquals(
            MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS,
            normalizeAppLockBackgroundTimeout(Long.MAX_VALUE),
        )
    }

    @Test
    fun configurationChangeDoesNotStartBackgroundTimer() {
        assertFalse(shouldRecordAppBackground(isChangingConfigurations = true))
        assertTrue(shouldRecordAppBackground(isChangingConfigurations = false))
    }

    @Test
    fun customTimeoutRemainsSelectedWhileDeletingDefaultValue() {
        val custom = AppLockTimeoutDraft.fromTimeout(30_000L).selectCustom()

        val oneMinute = custom.editCustomValue("1")
        assertTrue(oneMinute.customSelected)
        assertEquals("1", oneMinute.customValue)
        assertEquals(60_000L, oneMinute.timeoutMs)
        assertTrue(oneMinute.isValid)

        val empty = oneMinute.editCustomValue("")
        assertTrue(empty.customSelected)
        assertEquals("", empty.customValue)
        assertEquals(60_000L, empty.timeoutMs)
        assertFalse(empty.isValid)

        val replacement = empty.editCustomValue("25")
        assertTrue(replacement.customSelected)
        assertEquals(25 * 60_000L, replacement.timeoutMs)
        assertTrue(replacement.isValid)
    }

    @Test
    fun presetSelectionLeavesCustomEditingModeExplicitly() {
        val custom = AppLockTimeoutDraft.fromTimeout(10 * 60_000L)
        assertTrue(custom.customSelected)

        val preset = custom.selectPreset(60_000L)
        assertFalse(preset.customSelected)
        assertEquals(60_000L, preset.timeoutMs)
    }
}
