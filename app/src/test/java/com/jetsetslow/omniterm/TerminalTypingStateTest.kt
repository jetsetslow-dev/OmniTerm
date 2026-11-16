package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalTyping
import org.junit.Assert.*
import org.junit.Test

/** Receiver policy is ordinary JVM logic; no Android framework or scheduler is required. */
class TerminalTypingStateTest {
    private val typing = TerminalTyping()
    private fun session(name: String) = ShellSession(0, name, TypingFixtureTransport(), TerminalEmulator())

    @Test fun fixedSelectionRejectsUnknownAndClosedIdsAndNeverAutoAdds() {
        val first = session("first")
        val closed = session("closed").apply { userClosed = true }
        assertFalse(typing.enabled)
        typing.select(setOf(first.id, closed.id, "unknown"), listOf(first, closed))
        assertEquals(setOf(first.id), typing.selectedIds)
        val later = session("later")
        assertEquals(listOf(first), typing.receivers(first, listOf(first, later)))
        typing.remove(first.id)
        assertFalse(typing.enabled)
    }

    @Test fun exclusionsAreLiveAndRecoverWithoutChangingTheFixedSelection() {
        val first = session("first")
        val other = session("other")
        val sessions = listOf(first, other)
        typing.select(sessions.map { it.id }.toSet(), sessions)
        other.inputLocked = true
        assertEquals("input locked", typing.exclusion(other))
        assertEquals(listOf(first), typing.receivers(first, sessions))
        other.inputLocked = false
        other.reconnecting = true
        assertEquals("reconnecting", typing.exclusion(other))
        assertEquals(listOf(first), typing.receivers(first, sessions))
        other.reconnecting = false
        other.isConnected = false
        assertEquals("disconnected", typing.exclusion(other))
        assertEquals(listOf(first), typing.receivers(first, sessions))
        other.isConnected = true
        assertEquals(sessions, typing.receivers(first, sessions))
    }

    @Test fun stoppingChangesConfirmationRevisionAndFreshStateIsAlwaysOff() {
        val first = session("first")
        typing.select(setOf(first.id), listOf(first))
        val before = typing.revision
        typing.stop()
        assertTrue(typing.revision > before)
        assertFalse(typing.enabled)
        assertFalse(TerminalTyping().enabled)
    }
}
