package com.jetsetslow.omniterm.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Shows a session's screen after output, at most once per [intervalMs].
 *
 * The reader calls [markDirty] after every chunk it feeds the emulator. One loop owns the timing:
 * it takes the signal, waits out the rest of the interval, clears any signal that came meanwhile
 * (the snapshot it is about to take covers those chunks) and publishes. A chunk fed while that
 * snapshot is being taken signals again, so the loop runs once more: the last chunk of a burst is
 * always shown, even when the remote then goes quiet.
 *
 * The throttle this replaces kept its timer and its pending job in two plain variables shared by
 * the reader and the delayed job. A chunk that arrived after the delayed job took its snapshot but
 * before it cleared its job found a job still active, scheduled nothing, and stayed off the screen
 * until more output or a resize came. It also timed itself with the wall clock, so a clock set
 * backwards held every update until the clock caught up.
 */
class TerminalSnapshotPublisher(
    scope: CoroutineScope,
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
    private val nowMs: () -> Long = ::monotonicNowMs,
    private val publish: () -> Unit,
) {
    private val dirty = Channel<Unit>(Channel.CONFLATED)

    private val loop: Job = scope.launch {
        var lastPublishMs: Long? = null
        for (signal in dirty) {
            val last = lastPublishMs
            if (last != null) {
                val wait = last + intervalMs - nowMs()
                if (wait > 0) delay(wait)
            }
            dirty.tryReceive()
            lastPublishMs = nowMs()
            publish()
        }
    }

    /** New output reached the emulator. Safe from any thread. */
    fun markDirty() {
        dirty.trySend(Unit)
    }

    /** Stops publishing. The owner shows the final screen itself. */
    fun stop() {
        dirty.close()
        loop.cancel()
    }

    companion object {
        const val DEFAULT_INTERVAL_MS = 16L

        private fun monotonicNowMs(): Long = System.nanoTime() / 1_000_000
    }
}
