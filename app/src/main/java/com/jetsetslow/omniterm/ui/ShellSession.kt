package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.TerminalSession as SshSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlin.random.Random
import java.util.UUID

private val TmuxNameAdjectives = listOf(
    "bouncy", "brisk", "cheery", "cozy", "curious", "dapper", "fizzy", "jolly",
    "mellow", "peppy", "plucky", "quirky", "snappy", "sparkly", "sunny", "zippy",
)

private val TmuxNameNouns = listOf(
    "bagel", "banjo", "biscuit", "bubble", "button", "cactus", "cupcake", "doorknob",
    "fountain", "gadget", "lantern", "muffin", "noodle", "pancake", "pickle", "teacup",
)

private val TmuxNameEndings = listOf(
    "orbit", "parade", "signal", "sprinkle", "sunrise", "tango", "waffle", "whistle",
    "wiggle", "window", "wizard", "zipper", "marshmallow", "moonbeam", "popcorn", "rainbow",
)

internal fun generateTmuxSessionName(random: Random = Random.Default): String =
    "omniterm-" + listOf(
        TmuxNameAdjectives[random.nextInt(TmuxNameAdjectives.size)],
        TmuxNameNouns[random.nextInt(TmuxNameNouns.size)],
        TmuxNameEndings[random.nextInt(TmuxNameEndings.size)],
    ).joinToString("-")

internal fun generateUniqueTmuxSessionName(
    existingNames: Set<String>,
    random: Random = Random.Default,
): String {
    repeat(128) {
        val candidate = generateTmuxSessionName(random)
        if (candidate !in existingNames) return candidate
    }
    // The phrase space is intentionally friendly and finite. This fallback remains number-free and
    // shell-safe while making an in-practice collision impossible if a host has many saved sessions.
    val letters = UUID.randomUUID().toString().filter { it in 'a'..'f' }.take(16).ifBlank { "fallback" }
    return "omniterm-session-$letters"
}

internal fun displayTmuxSessionName(tmuxName: String): String =
    tmuxName.removePrefix("omniterm-").replace('-', ' ')

/**
 * Represents an active, background-capable SSH terminal session in the app.
 * Each session has its own emulator, IO channels, and coroutine jobs.
 */
class ShellSession(
    val serverId: Int,
    val serverName: String,
    session: SshSession,
    val emulator: TerminalEmulator,
    val id: String = UUID.randomUUID().toString(),
) {
    // The live SSH channel. Swapped out by auto-reconnect, so it's a var (not val).
    var session: SshSession = session
    var terminalScreen by mutableStateOf(TerminalSnapshot.EMPTY)
    var viewportFirstRow: Int = 0
    var viewportRowCount: Int = 24
    var followTail: Boolean = true
    var terminalInputChannel: Channel<ByteArray>? = null
    var terminalInputJob: Job? = null
    var terminalOutputJob: Job? = null
    var isConnected by mutableStateOf(true)
    var disconnectError by mutableStateOf<String?>(null)

    // ── Auto-reconnect / persistent-session state ──
    // Credentials + last known PTY size are kept so a dropped session can be reopened without the UI.
    var creds: SshCredentials? = null
    var lastCols: Int = 80
    var lastRows: Int = 24
    /** True ⇒ relaunch inside tmux on connect so the session survives drops (re-attached on reconnect). */
    var persistent: Boolean = false
    /**
     * Unique tmux session name for THIS shell, so multiple persistent sessions to the same host each
     * re-attach their own session rather than colliding on one shared name.
     */
    var tmuxName: String = generateTmuxSessionName()
    /** Reconnect coroutine in flight (backoff retry loop); cancelled on manual disconnect. */
    var reconnectJob: Job? = null
    /** True while the auto-reconnect backoff loop is running (drives the "Reconnecting…" UI). */
    var reconnecting by mutableStateOf(false)
    /** Set true by a user-initiated disconnect so the drop handler doesn't try to auto-reconnect. */
    var userClosed: Boolean = false
}
