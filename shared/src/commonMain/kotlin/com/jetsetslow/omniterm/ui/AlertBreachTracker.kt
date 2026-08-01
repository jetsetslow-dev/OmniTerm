package com.jetsetslow.omniterm.ui

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.updateAndGet

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
    private data class State(val since: Long, val lastSeen: Long, val underStreak: Int)

    private val states = MutableStateFlow<Map<Pair<Int, Int>, State>>(emptyMap())

    /** Feed one sample; returns true when the breach has been sustained for [windowMs]. */
    fun onSample(key: Pair<Int, Int>, over: Boolean, now: Long, windowMs: Long, staleGapMs: Long): Boolean {
        var triggered = false
        states.updateAndGet { current ->
            val existing = current[key]
            if (!over) {
                if (existing == null) return@updateAndGet current
                val next = existing.copy(lastSeen = now, underStreak = existing.underStreak + 1)
                return@updateAndGet if (next.underStreak >= RESET_AFTER_UNDER_SAMPLES) {
                    current - key
                } else {
                    current + (key to next)
                }
            }
            val next = when {
                existing == null -> State(since = now, lastSeen = now, underStreak = 0)
                now - existing.lastSeen > staleGapMs -> existing.copy(since = now, lastSeen = now, underStreak = 0)
                else -> existing.copy(lastSeen = now, underStreak = 0)
            }
            triggered = now - next.since >= windowMs
            current + (key to next)
        }
        return triggered
    }

    /**
     * True when an active incident may resolve: the breach state is fully cleared (enough
     * consecutive clean samples, or no breach was ever observed this app run).
     */
    fun clearedFor(key: Pair<Int, Int>): Boolean = key !in states.value

    /** Drop tracked state, e.g. when the rule is deleted or its incident is dismissed. */
    fun forget(key: Pair<Int, Int>) {
        states.update { it - key }
    }

    /** Drop every host window for a rule after that rule is deleted or materially edited. */
    fun forgetRule(ruleId: Int) {
        states.update { current -> current.filterKeys { it.first != ruleId } }
    }

    companion object {
        const val RESET_AFTER_UNDER_SAMPLES = 2
    }
}
