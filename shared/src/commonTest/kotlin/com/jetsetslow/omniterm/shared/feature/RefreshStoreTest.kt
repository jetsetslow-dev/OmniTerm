package com.jetsetslow.omniterm.shared.feature

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class RefreshStoreTest {
    @Test
    fun exposesProgressAndResult() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = RefreshStore(0, CoroutineScope(dispatcher), ProgressLoader {
            it(OperationProgress("Half", 1, 2))
            42
        })
        store.dispatch(RefreshStore.Action.Load)
        advanceUntilIdle()
        assertEquals(42, store.state.value.value)
        assertFalse(store.state.value.loading)
        assertEquals(null, store.state.value.error)
    }

    @Test
    fun newerRefreshOwnsProgressAndResult() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val first = CompletableDeferred<Int>()
        var invocation = 0
        val store = RefreshStore(0, CoroutineScope(dispatcher), ProgressLoader {
            invocation++
            if (invocation == 1) first.await() else 2
        })
        store.dispatch(RefreshStore.Action.Load)
        testScheduler.runCurrent()
        store.dispatch(RefreshStore.Action.Refresh)
        advanceUntilIdle()
        first.complete(1)
        advanceUntilIdle()
        assertEquals(2, store.state.value.value)
    }

    @Test
    fun cancellationClearsVisibleProgress() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val pending = CompletableDeferred<Int>()
        val store = RefreshStore(0, CoroutineScope(dispatcher), ProgressLoader {
            it(OperationProgress("Working"))
            pending.await()
        })
        store.dispatch(RefreshStore.Action.Load)
        testScheduler.runCurrent()
        assertTrue(store.state.value.loading)
        store.dispatch(RefreshStore.Action.Cancel)
        assertFalse(store.state.value.loading)
        assertEquals(null, store.state.value.progress)
    }
}
