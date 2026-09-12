package com.jetsetslow.omniterm

import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

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
