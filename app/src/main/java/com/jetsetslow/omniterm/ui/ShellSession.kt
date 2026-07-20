package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.TerminalSession as SshSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlin.random.Random
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

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

internal fun generateTmuxSessionName(random: Random? = null): String {
    val wordsRandom = random ?: Random.Default
    val tokenBytes = ByteArray(16).also { bytes ->
        if (random == null) UUID.randomUUID().let { uuid ->
            for (index in 0 until 8) bytes[index] = (uuid.mostSignificantBits ushr (index * 8)).toByte()
            for (index in 0 until 8) bytes[index + 8] = (uuid.leastSignificantBits ushr (index * 8)).toByte()
        } else {
            random.nextBytes(bytes)
        }
    }
    // Encode each nibble as a-p: shell-safe letters only while retaining 128 bits of entropy.
    val token = buildString(32) {
        tokenBytes.forEach { byte ->
            append('a' + ((byte.toInt() ushr 4) and 0x0f))
            append('a' + (byte.toInt() and 0x0f))
        }
    }
    return "omniterm-" + listOf(
        TmuxNameAdjectives[wordsRandom.nextInt(TmuxNameAdjectives.size)],
        TmuxNameNouns[wordsRandom.nextInt(TmuxNameNouns.size)],
        TmuxNameEndings[wordsRandom.nextInt(TmuxNameEndings.size)],
        token,
    ).joinToString("-")
}

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
    tmuxName.removePrefix("omniterm-")
        .replace(Regex("-[a-p]{32}$"), "")
        .replace('-', ' ')

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
    /** Coordinates reconnect ownership transfer with user/lifecycle cleanup. */
    val sessionOwnershipLock = Any()
    var terminalScreen by mutableStateOf(TerminalSnapshot.EMPTY)
    val snapshotGeneration = AtomicLong(0)
    var publishedSnapshotGeneration: Long = 0
    var viewportFirstRow: Int = 0
    var viewportRowCount: Int = 24
    var followTail: Boolean = true
    /**
     * PTY grid this session is currently rendered at. Tracked per-session (not globally) so split
     * panes can each own their own dimensions — a side-by-side pane is narrower than a full-screen
     * one, and each must resize its remote PTY independently. Seeded to the connect-time size.
     */
    var termCols: Int = 80
    var termRows: Int = 24
    /**
     * True when THIS session (running in tmux) has been scrolled up into copy-mode, so its pane
     * should show a jump-to-bottom control. Per-session so one split pane scrolling back doesn't
     * arm the control on the other. Mirrors the old global terminalTmuxScrolledBack flag.
     */
    var tmuxScrolledBack by mutableStateOf(false)
    /**
     * True when output has arrived since the last tmux history re-sync, meaning local scrollback
     * may be missing rows the user never had on screen (tmux collapses fast output into a repaint
     * for attached clients instead of streaming every line). Checked when the user scrolls off the
     * tail; cleared by the re-sync. Only meaningful for persistent (tmux) sessions.
     */
    @Volatile var scrollbackDirty: Boolean = false
    /** Atomically excludes overlapping capture-pane re-syncs for this session. */
    val scrollbackSyncMutex = Mutex()
    /**
     * Short-lived cache of the pane's `#{alternate_on}` state (a full-screen TUI owns the pane),
     * so touch-scroll routing doesn't need a side-channel round trip on every gesture. Only used
     * for regular-attach persistent sessions — control mode and raw PTYs read the emulator's own
     * alternate-screen state, which is authoritative there.
     */
    @Volatile var paneAltActive: Boolean = false
    @Volatile var paneAltCheckedAtMs: Long = 0L
    /** Initial large tmux-history hydration; session-owned so closing never leaves parser work behind. */
    var historyHydrationJob: Job? = null

    // ── tmux control mode (experimental) ──
    /**
     * True when this persistent session attached with `tmux -C`: the channel carries the tmux
     * control protocol instead of rendered ANSI. Output is routed through a TmuxControlParser,
     * input is encoded as `send-keys -H` commands, and the client must paint the initial screen
     * itself (control mode never repaints). Decided at connect time from the app setting.
     */
    var controlMode: Boolean = false
    /** Active pane id ("%0") that %output events are routed from and input is sent to. */
    @Volatile var activePaneId: String? = null
    /** Input stays queued until initial history/screen seeding has completed. */
    @Volatile var controlReady: Boolean = false
    @Volatile var controlInitFailed: Boolean = false
    /** Input typed before the pane id was resolved; flushed by the control-mode init. */
    val pendingControlInput = ArrayList<ByteArray>()
    var pendingControlInputBytes: Int = 0
    var controlInputOverflowWarned: Boolean = false
    /** Initialisation is session-owned so reconnect/close can cancel an obsolete generation. */
    var controlInitJob: Job? = null
    var controlPaneRefreshJob: Job? = null
    var controlAttached: CompletableDeferred<Unit> = CompletableDeferred()
    val controlReplyLock = Any()
    var controlRepliesSeen: Long = 0
    var controlReplyBaseline: Long = 0
    var controlCommandsEnqueued: Long = 0
    var controlReplySignal: Channel<Unit> = Channel(Channel.CONFLATED)
    val controlReplyErrors = HashMap<Long, String>()
    val controlAwaitedOrdinals = HashSet<Long>()
    val controlPaneChangeRevision = AtomicLong(0)
    @Volatile var controlExitSeen: Boolean = false
    @Volatile var controlExitReason: String? = null
    var terminalInputQueue: TerminalInputQueue? = null
    var terminalInputOverflowWarned: Boolean = false
    var terminalInputJob: Job? = null
    var terminalOutputJob: Job? = null
    /**
     * Latest desired remote PTY size, conflated to newest-wins. A split-layout flip or IME
     * show/hide fires several resizes in one burst; sending each from its own coroutine let the
     * window-change packets land on the wire OUT OF ORDER, leaving the remote (and tmux's repaint)
     * at a stale size that no longer matches the local grid — the "garbled text after
     * stacking/rotating" failure. One consumer draining a conflated channel guarantees the last
     * size sent is the last size requested.
     */
    val resizeChannel = Channel<Pair<Int, Int>>(Channel.CONFLATED)
    /** Single consumer of [resizeChannel]; lazily started, cancelled with the session. */
    var resizeJob: Job? = null
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

/**
 * Non-blocking, byte-budgeted wire queue. The channel itself is unlimited so a UI caller never
 * blocks on SSH, while [queuedBytes] provides the real memory bound.
 */
class TerminalInputQueue {
    val channel = Channel<ByteArray>(Channel.UNLIMITED)
    var queuedBytes: Int = 0
    var closed: Boolean = false
}
