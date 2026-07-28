package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.AppLockTimeoutTracker
import com.jetsetslow.omniterm.ui.DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS
import com.jetsetslow.omniterm.ui.MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS
import com.jetsetslow.omniterm.ui.normalizeAppLockBackgroundTimeout
import com.jetsetslow.omniterm.ui.shouldRecordAppBackground
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLockTimeoutPolicyTest {
    @Test
    fun locksAtConfiguredBoundary() {
        val tracker = AppLockTimeoutTracker()
        tracker.noteBackgrounded(1_000L)

        assertTrue(
            tracker.consumeShouldRelock(
                nowMs = 31_000L,
                timeoutMs = 30_000L,
                lockEnabled = true,
                hasPin = true,
            ),
        )
    }

    @Test
    fun returningBeforeTimeoutConsumesThatBackgroundInterval() {
        val tracker = AppLockTimeoutTracker()
        tracker.noteBackgrounded(1_000L)

        assertFalse(tracker.consumeShouldRelock(30_999L, 30_000L, true, true))
        assertFalse(tracker.consumeShouldRelock(90_000L, 30_000L, true, true))
    }

    @Test
    fun duplicateStopsKeepEarliestBackgroundTime() {
        val tracker = AppLockTimeoutTracker()
        tracker.noteBackgrounded(1_000L)
        tracker.noteBackgrounded(20_000L)

        assertTrue(tracker.consumeShouldRelock(31_000L, 30_000L, true, true))
    }

    @Test
    fun disabledLockMissingPinAndClockRollbackDoNotLock() {
        fun result(enabled: Boolean, hasPin: Boolean, nowMs: Long): Boolean {
            val tracker = AppLockTimeoutTracker()
            tracker.noteBackgrounded(10_000L)
            return tracker.consumeShouldRelock(nowMs, 0L, enabled, hasPin)
        }

        assertFalse(result(enabled = false, hasPin = true, nowMs = 10_000L))
        assertFalse(result(enabled = true, hasPin = false, nowMs = 10_000L))
        assertFalse(result(enabled = true, hasPin = true, nowMs = 9_999L))
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
}
