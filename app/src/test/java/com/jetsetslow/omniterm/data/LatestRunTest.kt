package com.jetsetslow.omniterm.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class LatestRunTest {

    @Test
    fun aRequestDuringARunRunsTheLatestOneOnceMoreAfterIt() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val runner = LatestRun(scope)
            val started = CompletableDeferred<Unit>()
            val finish = CompletableDeferred<Unit>()
            val ran = CopyOnWriteArrayList<String>()
            runner.request { started.complete(Unit); finish.await(); ran += "first" }
            started.await()
            runner.request { ran += "second" }
            runner.request { ran += "third" }
            finish.complete(Unit)
            withTimeout(5_000) { while (ran.size < 2) delay(10) }
            delay(200)
            assertEquals("the run, then only the latest request", listOf("first", "third"), ran)

            val again = CompletableDeferred<Unit>()
            runner.request { again.complete(Unit) }
            withTimeout(5_000) { again.await() }
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun aRunThatFailsDoesNotBlockTheNextOne() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, _ -> })
        try {
            val runner = LatestRun(scope)
            val failing = CompletableDeferred<Unit>()
            runner.request { failing.complete(Unit); error("the check crashed") }
            failing.await()
            val next = CompletableDeferred<Unit>()
            withTimeout(5_000) {
                while (!next.isCompleted) {
                    runner.request { next.complete(Unit) }
                    delay(50)
                }
            }
        } finally {
            scope.cancel()
        }
    }
}
