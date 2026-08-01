package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.ui.widget.runWidgetRender
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.io.IOException

/**
 * Guards the catch ORDER in [runWidgetRender].
 *
 * The widget configuration screen used to catch `CancellationException` before
 * `TimeoutCancellationException`. Because the latter is a subclass, a render that exceeded the
 * widget load budget was rethrown as ordinary cancellation, which terminates a coroutine silently:
 * no crash, no log, and nothing after the call runs. In the app that left the Save button stuck on
 * "Saving…" forever and the launcher dropped the half-configured widget.
 *
 * Plain JVM tests with real dispatchers and bounded real-time waits: this is a pure
 * exception-classification guarantee with no Android dependency, and virtual time would not
 * exercise the subclass relationship that caused the bug.
 */
class WidgetRenderOutcomeTest {

    @Test
    fun `render timeout is returned as a failure rather than cancelling the caller`() = runBlocking {
        var reachedCodeAfterRender = false

        val failure = runWidgetRender {
            // Exactly the shape of OmniTermWidgetUpdater.update: a withTimeout around a load that
            // overruns its budget.
            withTimeout(30) { delay(5_000) }
        }
        reachedCodeAfterRender = true

        assertThat(failure).isInstanceOf(TimeoutCancellationException::class.java)
        // The regression: before the fix this line was never reached, because the rethrown
        // TimeoutCancellationException cancelled the enclosing coroutine instead.
        assertThat(reachedCodeAfterRender).isTrue()
    }

    @Test
    fun `timeout is a CancellationException, which is why the catch order matters`() {
        // Pins the subclass relationship the bug depended on. If kotlinx ever changed this, the
        // ordering requirement in runWidgetRender would deserve a fresh look rather than silently
        // becoming redundant.
        val timeout = runCatching { runBlocking { withTimeout(1) { delay(5_000) } } }.exceptionOrNull()
        assertThat(timeout).isInstanceOf(TimeoutCancellationException::class.java)
        assertThat(timeout).isInstanceOf(CancellationException::class.java)
    }

    @Test
    fun `ordinary failures are returned so the caller can report them`() = runBlocking {
        val failure = runWidgetRender { throw IOException("database unavailable") }

        assertThat(failure).isInstanceOf(IOException::class.java)
        assertThat(failure).hasMessageThat().isEqualTo("database unavailable")
    }

    @Test
    fun `successful render reports no failure`() = runBlocking {
        assertThat(runWidgetRender { }).isNull()
    }

    @Test
    fun `genuine cancellation still propagates so work stops after teardown`() = runBlocking {
        // The other half of the contract: swallowing real cancellation would let a destroyed
        // screen keep running. Cancel the scope while the render is suspended and assert that
        // runWidgetRender does NOT convert that into a returned failure.
        val renderStarted = CompletableDeferred<Unit>()
        var returnedNormally = false

        val job = launch(Dispatchers.Default) {
            runWidgetRender {
                renderStarted.complete(Unit)
                delay(10_000)
            }
            returnedNormally = true
        }

        renderStarted.await()
        job.cancel()
        job.join()

        assertThat(job.isCancelled).isTrue()
        assertThat(returnedNormally).isFalse()
    }

    @Test
    fun `a timeout in one render does not cancel sibling work in the same scope`() = runBlocking {
        // The launcher updates several widget ids together. A timeout rendering one must not take
        // down the others, which is what rethrowing cancellation into a shared scope would do.
        val results = coroutineScope {
            val slow = async(Dispatchers.Default) {
                runWidgetRender { withTimeout(30) { delay(5_000) } }
            }
            val fast = async(Dispatchers.Default) { runWidgetRender { } }
            listOf(slow.await(), fast.await())
        }

        assertThat(results[0]).isInstanceOf(TimeoutCancellationException::class.java)
        assertThat(results[1]).isNull()
    }
}
