package com.jetsetslow.omniterm.ui

import java.util.concurrent.ConcurrentHashMap

/**
 * Sustained-breach window tracker for alert rules, keyed by (ruleId, serverId).
 *
 * Two behaviours make triggering consistent where the naive "reset on any clean sample"
 * approach was not:
 *  - Hysteresis: a single under-threshold sample (metric jitter) neither resets the breach
 *    window nor resolves an active incident; it takes [RESET_AFTER_UNDER_SAMPLES] consecutive
 *    clean samples.
 *  - Gap restart: when sampling stops mid-breach (app paused, battery saver, host unreachable),
 *    wall-clock time keeps passing but nothing was observed. A sample arriving after more than
 *    the stale gap restarts the window instead of instantly firing on the accumulated time.
 */
class AlertBreachTracker {
    private class State(var since: Long, var lastSeen: Long, var underStreak: Int)

    private val states = ConcurrentHashMap<Pair<Int, Int>, State>()

    /** Feed one sample; returns true when the breach has been sustained for [windowMs]. */
    fun onSample(key: Pair<Int, Int>, over: Boolean, now: Long, windowMs: Long, staleGapMs: Long): Boolean {
        val existing = states[key]
        if (!over) {
            if (existing != null) {
                existing.lastSeen = now
                existing.underStreak++
                if (existing.underStreak >= RESET_AFTER_UNDER_SAMPLES) states.remove(key)
            }
            return false
        }
        val state = when {
            existing == null -> State(since = now, lastSeen = now, underStreak = 0).also { states[key] = it }
            now - existing.lastSeen > staleGapMs -> existing.also { it.since = now }
            else -> existing
        }
        state.lastSeen = now
        state.underStreak = 0
        return now - state.since >= windowMs
    }

    /**
     * True when an active incident may resolve: the breach state is fully cleared (enough
     * consecutive clean samples, or no breach was ever observed this app run).
     */
    fun clearedFor(key: Pair<Int, Int>): Boolean = !states.containsKey(key)

    /** Drop tracked state, e.g. when the rule is deleted or its incident is dismissed. */
    fun forget(key: Pair<Int, Int>) {
        states.remove(key)
    }

    companion object {
        const val RESET_AFTER_UNDER_SAMPLES = 2
    }
}
