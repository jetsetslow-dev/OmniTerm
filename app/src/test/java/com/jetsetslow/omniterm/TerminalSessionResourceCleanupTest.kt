package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalInputQueue
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.After
import org.junit.Test

class TerminalSessionResourceCleanupTest {
    @After
    fun cleanManager() {
        TerminalSessionManager.clearAll()
    }

    @Test
    fun disposingTerminalCancelsOwnedScopesClosesChannelsAndClosesSocketExactlyOnce() {
        val closed = MutableStateFlow(false)
        val transport = mockk<TerminalSession>()
        every { transport.output } returns emptyFlow()
        every { transport.closed } returns closed
        every { transport.exitStatus } returns MutableStateFlow(null)
        every { transport.remoteExited } returns MutableStateFlow(false)
        every { transport.close() } answers { closed.value = true }

        val shell = ShellSession(7, "cleanup-host", transport, TerminalEmulator(), id = "cleanup")
        shell.terminalInputJob = Job()
        shell.terminalOutputJob = Job()
        shell.resizeJob = Job()
        shell.historyHydrationJob = Job()
        shell.controlInitJob = Job()
        shell.controlPaneRefreshJob = Job()
        shell.reconnectJob = Job()
        shell.terminalInputQueue = TerminalInputQueue()
        TerminalSessionManager.addSession(shell)

        TerminalSessionManager.cleanupSession(shell)

        assertThat(shell.terminalInputJob?.isCancelled).isTrue()
        assertThat(shell.terminalOutputJob?.isCancelled).isTrue()
        assertThat(shell.resizeJob?.isCancelled).isTrue()
        assertThat(shell.historyHydrationJob?.isCancelled).isTrue()
        assertThat(shell.controlInitJob?.isCancelled).isTrue()
        assertThat(shell.controlPaneRefreshJob?.isCancelled).isTrue()
        assertThat(shell.reconnectJob?.isCancelled).isTrue()
        assertThat(shell.terminalInputQueue?.closed).isTrue()
        assertThat(shell.terminalInputQueue?.channel?.trySend(byteArrayOf(1))?.isFailure).isTrue()
        assertThat(shell.resizeChannel.trySend(80 to 24).isFailure).isTrue()
        assertThat(TerminalSessionManager.activeSessions).doesNotContain(shell)
        verify(timeout = 2_000, exactly = 1) { transport.close() }
        assertThat(closed.value).isTrue()
    }
}
