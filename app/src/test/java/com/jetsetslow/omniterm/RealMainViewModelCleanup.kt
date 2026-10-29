package com.jetsetslow.omniterm

import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/**
 * ViewModelStore.clear() cancels work but does not wait for IO continuations/finally blocks.
 * Keep the test's real Main dispatcher installed until both ViewModel and process-owned terminal
 * work are finished; resetMain racing a last dispatch can poison the next Robolectric test.
 */
internal suspend fun clearViewModelsAndAwaitTerminalJobs(
    store: ViewModelStore,
    main: CoroutineDispatcher,
) {
    withTimeout(5_000) {
        val modelJobs = withContext(main) {
            val jobs = store.keys().mapNotNull { store[it]?.viewModelScope?.coroutineContext?.get(Job) }
            store.clear()
            TerminalSessionManager.clearAll()
            jobs
        }
        modelJobs.joinAll()
        val terminalRoot = checkNotNull(TerminalSessionManager.scope.coroutineContext[Job])
        // Teardown may enqueue close/snapshot work in the process scope. Do not cancel its root:
        // later tests still need the singleton, just like a later Activity in the real process.
        while (true) {
            val children = terminalRoot.children.toList()
            if (children.isEmpty()) break
            children.forEach { it.cancel() }
            children.joinAll()
        }
    }
}

/**
 * Waits while [condition] holds, reading it on [main] as the UI reads ViewModel state, and fails
 * after [timeoutMillis].
 *
 * The ViewModel sets related state together in one main-thread task: a message and its error flag,
 * a screen and its sessions. Polled from the test's own thread, a read can land between two of
 * those writes, see the first and then assert on the stale second; a release build failed that
 * way. Read on [main], the condition sees each task's writes all or none, and once it clears, the
 * test thread sees everything main wrote before it. `RealMainPollingPolicyTest` keeps tests on this.
 */
internal suspend fun waitWhileOnMain(
    main: CoroutineDispatcher,
    timeoutMillis: Long = 5_000,
    condition: () -> Boolean,
) {
    withTimeout(timeoutMillis) { pollOnMain(main, condition) }
}

/** [waitWhileOnMain] for a time limit that is itself the assertion: false if it did not clear. */
internal suspend fun clearsOnMainWithin(
    main: CoroutineDispatcher,
    timeoutMillis: Long,
    condition: () -> Boolean,
): Boolean = withTimeoutOrNull(timeoutMillis) { pollOnMain(main, condition); true } ?: false

private suspend fun pollOnMain(main: CoroutineDispatcher, condition: () -> Boolean) {
    while (withContext(main) { condition() }) delay(10)
}
