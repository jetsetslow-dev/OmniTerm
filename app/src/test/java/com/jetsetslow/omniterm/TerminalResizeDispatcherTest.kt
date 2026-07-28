package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.launchTerminalResizeConsumer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalResizeDispatcherTest {

    @Test
    fun resizeBurstConflatesToFinalSigwinchWithoutOutOfOrderIntermediateSizes() = runBlocking {
        val channel = Channel<Pair<Int, Int>>(Channel.CONFLATED)
        val firstResizeStarted = CompletableDeferred<Unit>()
        val releaseFirstResize = CompletableDeferred<Unit>()
        val calls = mutableListOf<Pair<Int, Int>>()
        val job = CoroutineScope(Dispatchers.Default).launchTerminalResizeConsumer(
            channel = channel,
            dispatcher = Dispatchers.Default,
        ) { cols, rows ->
            val first = synchronized(calls) {
                calls += cols to rows
                calls.size == 1
            }
            if (first) {
                firstResizeStarted.complete(Unit)
                releaseFirstResize.await()
            }
        }

        try {
            channel.trySend(90 to 30)
            withTimeout(5_000) { firstResizeStarted.await() }
            channel.trySend(100 to 35)
            channel.trySend(110 to 40)
            channel.trySend(120 to 45)
            releaseFirstResize.complete(Unit)

            withTimeout(5_000) {
                while (synchronized(calls) { calls.size } < 2) delay(10)
            }

            assertEquals(listOf(90 to 30, 120 to 45), synchronized(calls) { calls.toList() })
        } finally {
            channel.close()
            releaseFirstResize.complete(Unit)
            job.cancelAndJoin()
        }
    }
}
