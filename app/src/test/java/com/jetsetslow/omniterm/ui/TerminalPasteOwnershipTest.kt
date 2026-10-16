package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TerminalPasteOwnershipTest {
    @Test fun fullQueueRejectsWholePasteWithoutSendingPrefix() {
        val queue = TerminalInputQueue()
        val existing = byteArrayOf(1, 2)
        assertTrue(queue.enqueueBatch(listOf(existing), 4))
        val receipt = CompletableDeferred<TerminalWriteOutcome>()
        assertFalse(queue.enqueueBatch(listOf(byteArrayOf(3, 4), byteArrayOf(5)), 4, receipt))
        assertSame(existing, queue.channel.tryReceive().getOrNull())
        assertTrue(queue.channel.tryReceive().isFailure)
        assertEquals(2, queue.queuedBytes)
        assertFalse(receipt.isCompleted)
        queue.close()
    }

    @Test fun identicalChunksRemainOrderedAndReceiptWaitsForLastWrite() {
        val queue = TerminalInputQueue()
        val first = byteArrayOf(1)
        val last = byteArrayOf(1)
        val receipt = CompletableDeferred<TerminalWriteOutcome>()
        assertTrue(queue.enqueueBatch(listOf(first, last), 10, receipt))
        assertSame(first, queue.channel.tryReceive().getOrNull())
        assertTrue(queue.beginWrite(first))
        queue.finishWrite(first, TerminalWriteOutcome.ACCEPTED)
        assertFalse(receipt.isCompleted)
        assertSame(last, queue.channel.tryReceive().getOrNull())
        assertTrue(queue.beginWrite(last))
        assertFalse(receipt.isCompleted)
        queue.finishWrite(last, TerminalWriteOutcome.ACCEPTED)
        assertEquals(TerminalWriteOutcome.ACCEPTED, receipt.getCompleted())
        queue.workerFinished()
        assertEquals(TerminalWriteOutcome.ACCEPTED, receipt.getCompleted())
    }

    @Test fun eofRejectsQueuedPasteButPreservesAlreadyStartedSuccessfulWrite() {
        val queue = TerminalInputQueue()
        val active = byteArrayOf(1)
        val accepted = CompletableDeferred<TerminalWriteOutcome>()
        val rejected = CompletableDeferred<TerminalWriteOutcome>()
        assertTrue(queue.enqueueBatch(listOf(active), 10, accepted))
        assertTrue(queue.enqueueBatch(listOf(byteArrayOf(2)), 10, rejected))
        assertSame(active, queue.channel.tryReceive().getOrNull())
        assertTrue(queue.beginWrite(active))
        queue.close()
        assertFalse(accepted.isCompleted)
        assertEquals(TerminalWriteOutcome.UNCERTAIN, rejected.getCompleted())
        queue.finishWrite(active, TerminalWriteOutcome.ACCEPTED)
        queue.workerFinished()
        assertEquals(TerminalWriteOutcome.ACCEPTED, accepted.getCompleted())
        assertEquals(0, queue.queuedBytes)
    }

    @Test fun closeBetweenDequeueAndWritePreventsOldTransportInput() {
        val queue = TerminalInputQueue()
        val bytes = byteArrayOf(1)
        val receipt = CompletableDeferred<TerminalWriteOutcome>()
        queue.enqueueBatch(listOf(bytes), 10, receipt)
        assertSame(bytes, queue.channel.tryReceive().getOrNull())
        queue.close()
        assertFalse(queue.beginWrite(bytes))
        assertEquals(TerminalWriteOutcome.UNCERTAIN, receipt.getCompleted())
    }

    @Test fun cancelledWriterAndPrefixFailureResolveAllPasteWaiters() {
        for (prefixFailed in listOf(false, true)) {
            val queue = TerminalInputQueue()
            val first = byteArrayOf(1)
            val receipt = CompletableDeferred<TerminalWriteOutcome>()
            val following = CompletableDeferred<TerminalWriteOutcome>()
            queue.enqueueBatch(listOf(first, byteArrayOf(2)), 10, receipt)
            queue.enqueueBatch(listOf(byteArrayOf(3)), 10, following)
            queue.channel.tryReceive()
            assertTrue(queue.beginWrite(first))
            if (prefixFailed) queue.finishWrite(first, TerminalWriteOutcome.UNCERTAIN)
            queue.workerFinished()
            assertEquals(TerminalWriteOutcome.UNCERTAIN, receipt.getCompleted())
            assertEquals(TerminalWriteOutcome.UNCERTAIN, following.getCompleted())
            assertTrue(queue.closed)
            assertTrue(queue.channel.tryReceive().isFailure)
        }
    }

    private fun shell(): ShellSession {
        val transport = mockk<TerminalSession>()
        every { transport.closed } returns MutableStateFlow(false)
        return ShellSession(1, "fixture", transport, TerminalEmulator()).apply {
            terminalInputQueue = TerminalInputQueue()
            isConnected = true
            controlMode = true
            controlReady = true
            activePaneId = "%1"
        }
    }

    @Test fun confirmationCannotFollowSettledPaneChangeEvenWhenPaneReturns() {
        val shell = shell()
        val target = TerminalPasteTarget(shell)
        assertNull(target.rejection(shell, false))
        shell.activePaneId = "%2"
        shell.controlPaneChangeRevision.incrementAndGet()
        shell.activePaneId = "%1"
        shell.controlPaneChangeRevision.incrementAndGet()
        assertTrue(target.rejection(shell, false)!!.contains("pane changed"))
    }

    @Test fun confirmationRejectsReplacementConnectionQueueFocusAndReadOnly() {
        val shell = shell()
        val target = TerminalPasteTarget(shell)
        assertTrue(target.rejection(null, false)!!.contains("selection changed"))
        assertTrue(target.rejection(shell, true)!!.contains("read-only"))
        shell.terminalInputQueue = TerminalInputQueue()
        assertTrue(target.rejection(shell, false)!!.contains("Connection changed"))
        val next = TerminalPasteTarget(shell)
        shell.session = shell().session
        assertTrue(next.rejection(shell, false)!!.contains("Connection changed"))
    }

    @Test fun unavailablePaneOrClosedWriterNeverLooksReadyForPaste() {
        val shell = shell()
        shell.activePaneId = null
        assertTrue(TerminalPasteTarget(shell).rejection(shell, false)!!.contains("Wait for tmux"))
        shell.activePaneId = "%1"
        shell.terminalInputQueue!!.close()
        assertTrue(TerminalPasteTarget(shell).rejection(shell, false)!!.contains("disconnected"))
    }
}
