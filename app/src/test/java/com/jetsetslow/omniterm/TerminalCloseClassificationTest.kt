package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ssh.classifyTerminalClose
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalCloseClassificationTest {

    @Test
    fun realExitStatusIsCleanExit() {
        val close = classifyTerminalClose(
            remoteEof = true,
            channelIsEof = true,
            sessionConnected = false,
            exitStatus = 0,
        )

        assertTrue(close.remoteExited)
        assertEquals(0, close.exitStatus)
    }

    @Test
    fun cleanEofWithoutExitStatusWhileSessionIsAliveIsCleanExit() {
        val close = classifyTerminalClose(
            remoteEof = true,
            channelIsEof = true,
            sessionConnected = true,
            exitStatus = -1,
        )

        assertTrue(close.remoteExited)
        assertEquals(0, close.exitStatus)
    }

    @Test
    fun eofAfterDeadSessionWithoutExitStatusIsNetworkDrop() {
        val close = classifyTerminalClose(
            remoteEof = true,
            channelIsEof = true,
            sessionConnected = false,
            exitStatus = -1,
        )

        assertFalse(close.remoteExited)
        assertEquals(-1, close.exitStatus)
    }

    @Test
    fun closedStreamWithoutChannelEofIsNetworkDrop() {
        val close = classifyTerminalClose(
            remoteEof = true,
            channelIsEof = false,
            sessionConnected = false,
            exitStatus = null,
        )

        assertFalse(close.remoteExited)
        assertEquals(null, close.exitStatus)
    }
}
