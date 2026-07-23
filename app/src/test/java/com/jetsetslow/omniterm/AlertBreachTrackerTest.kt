package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.AlertBreachTracker
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlertBreachTrackerTest {
    private val key = 1 to 4
    private val window = 5 * 60_000L   // 5m rule
    private val gap = 90_000L          // stale-gap threshold
    private val poll = 15_000L         // sample cadence

    private fun tracker() = AlertBreachTracker()

    @Test
    fun sustainedBreachFiresAfterWindow() {
        val t = tracker()
        var now = 0L
        var fired = false
        repeat(21) { // 21 samples * 15s = 5m elapsed at the last one
            fired = t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap)
            now += poll
        }
        assertTrue(fired)
    }

    @Test
    fun breachShorterThanWindowDoesNotFire() {
        val t = tracker()
        var now = 0L
        repeat(10) {
            assertFalse(t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap))
            now += poll
        }
    }

    @Test
    fun singleJitterDipDoesNotResetTheWindow() {
        val t = tracker()
        var now = 0L
        repeat(10) { t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap); now += poll }
        t.onSample(key, over = false, now = now, windowMs = window, staleGapMs = gap); now += poll
        // Continue the breach: the window must still be anchored at t=0.
        var fired = false
        while (now <= window) {
            fired = t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap)
            now += poll
        }
        assertTrue("dip must not restart the sustained-breach window", fired)
    }

    @Test
    fun twoConsecutiveCleanSamplesResetTheWindow() {
        val t = tracker()
        var now = 0L
        repeat(30) { t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap); now += poll }
        repeat(2) { t.onSample(key, over = false, now = now, windowMs = window, staleGapMs = gap); now += poll }
        assertTrue(t.clearedFor(key))
        // A fresh breach starts a fresh window: no instant fire.
        assertFalse(t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap))
    }

    @Test
    fun samplingGapRestartsTheWindowInsteadOfInstantFiring() {
        val t = tracker()
        var now = 0L
        repeat(4) { t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap); now += poll }
        // App paused / host unreachable for 20 minutes; still over threshold on resume.
        now += 20 * 60_000L
        assertFalse(
            "unobserved time must not count toward the breach window",
            t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap),
        )
        // But a fresh sustained window after the gap does fire.
        var fired = false
        val restart = now
        while (now - restart <= window) {
            fired = t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap)
            now += poll
        }
        assertTrue(fired)
    }

    @Test
    fun incidentResolvesOnlyAfterHysteresis() {
        val t = tracker()
        var now = 0L
        repeat(30) { t.onSample(key, over = true, now = now, windowMs = window, staleGapMs = gap); now += poll }
        t.onSample(key, over = false, now = now, windowMs = window, staleGapMs = gap); now += poll
        assertFalse("one clean sample must not resolve the incident", t.clearedFor(key))
        t.onSample(key, over = false, now = now, windowMs = window, staleGapMs = gap)
        assertTrue(t.clearedFor(key))
    }

    @Test
    fun neverBreachedKeyReportsCleared() {
        // An incident restored from a previous app run has no in-memory state; the first clean
        // sample may resolve it immediately.
        assertTrue(tracker().clearedFor(key))
    }

    @Test
    fun forgetDropsState() {
        val t = tracker()
        t.onSample(key, over = true, now = 0L, windowMs = window, staleGapMs = gap)
        t.forget(key)
        assertTrue(t.clearedFor(key))
        assertFalse(t.onSample(key, over = true, now = window + 1, windowMs = window, staleGapMs = gap))
    }
}
