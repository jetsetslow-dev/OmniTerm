package com.jetsetslow.omniterm.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Runs one job at a time without losing a request. Asked while idle, it starts at once. Asked while
 * a run is going, it runs the latest request once more when that run ends, however many came in.
 *
 * "Skip if a job is active" loses the request instead: a check rule added while a round was
 * reading the rules waited for the next poll, and a release build's test failed on that wait.
 */
class LatestRun(
    private val scope: CoroutineScope,
    private val context: CoroutineContext = EmptyCoroutineContext,
) {
    private val lock = Any()
    private var running = false
    private var next: (suspend () -> Unit)? = null

    fun request(block: suspend () -> Unit) {
        synchronized(lock) {
            if (running) {
                next = block
                return
            }
            running = true
        }
        scope.launch(context) {
            var current: (suspend () -> Unit)? = block
            while (current != null) {
                current()
                current = synchronized(lock) { next.also { next = null; if (it == null) running = false } }
            }
        }.invokeOnCompletion { cause ->
            // Cancelled or failed, possibly before it started: the next request starts afresh.
            if (cause != null) synchronized(lock) { running = false; next = null }
        }
    }
}
