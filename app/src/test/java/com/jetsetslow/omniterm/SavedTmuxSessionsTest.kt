package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.HostTmuxSession
import com.jetsetslow.omniterm.ui.TmuxEndResult
import com.jetsetslow.omniterm.ui.endRemoteTmux
import com.jetsetslow.omniterm.ui.hostTmuxSessions
import com.jetsetslow.omniterm.ui.keepTrustedHostKeys
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Removing saved tmux sessions, and what deleting a host does to its sessions and keys. */
class SavedTmuxSessionsTest {

    private fun saved(name: String, serverId: Int) = PersistentSessionEntity(name, serverId, "host$serverId")

    @Test
    fun `a host's tmux sessions are its open ones plus the saved ones not open here`() {
        val sessions = hostTmuxSessions(
            serverIds = setOf(1),
            openPersistent = listOf(HostTmuxSession(1, "omni-a"), HostTmuxSession(2, "omni-b")),
            saved = listOf(saved("omni-a", 1), saved("omni-c", 1), saved("omni-d", 2)),
        )
        // omni-a is both open and saved: one session, offered once.
        assertEquals(listOf(HostTmuxSession(1, "omni-a"), HostTmuxSession(1, "omni-c")), sessions)
    }

    @Test
    fun `a host with nothing running has no sessions to offer ending`() {
        assertTrue(hostTmuxSessions(setOf(3), emptyList(), listOf(saved("omni-a", 1))).isEmpty())
    }

    @Test
    fun `a session counts as ended only when tmux confirms it is gone`() = runTest {
        assertEquals(TmuxEndResult.Ended, endRemoteTmux(kill = { "" }, stillExists = { false }))
        assertEquals(TmuxEndResult.NotConfirmed, endRemoteTmux(kill = { "" }, stillExists = { true }))
        // The kill seemed to work but the check could not run: still not ended.
        assertEquals(TmuxEndResult.NotConfirmed, endRemoteTmux(kill = { "" }, stillExists = { null }))
    }

    @Test
    fun `an unreachable server is reported without asking tmux again`() = runTest {
        var probed = false
        val result = endRemoteTmux(
            kill = { "SSH Error: connect timed out\n" },
            stillExists = { probed = true; null },
        )
        assertEquals(TmuxEndResult.Unreachable("SSH Error: connect timed out"), result)
        assertFalse(probed)
    }

    @Test
    fun `trusted keys stay while another saved host uses the same address`() {
        val other = ServerEntity(id = 2, name = "nas admin", host = "nas.local", port = 2222, username = "root")
        // Keys are also stored under the bare host name, so even another port shares them.
        assertTrue(keepTrustedHostKeys("nas.local", listOf(other)))
        assertFalse(keepTrustedHostKeys("pi.local", listOf(other)))
        assertFalse(keepTrustedHostKeys("nas.local", emptyList()))
    }
}
