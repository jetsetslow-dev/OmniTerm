package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import com.jetsetslow.omniterm.data.ssh.TerminalSession as SshSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import java.util.UUID

/**
 * Represents an active, background-capable SSH terminal session in the app.
 * Each session has its own emulator, IO channels, and coroutine jobs.
 */
class ShellSession(
    val serverId: Int,
    val serverName: String,
    val session: SshSession,
    val emulator: TerminalEmulator,
    val id: String = UUID.randomUUID().toString()
) {
    var terminalScreen by mutableStateOf(TerminalSnapshot.EMPTY)
    var viewportFirstRow: Int = 0
    var viewportRowCount: Int = 24
    var followTail: Boolean = true
    var terminalInputChannel: Channel<ByteArray>? = null
    var terminalInputJob: Job? = null
    var terminalOutputJob: Job? = null
    var isConnected by mutableStateOf(true)
    var disconnectError by mutableStateOf<String?>(null)
}
