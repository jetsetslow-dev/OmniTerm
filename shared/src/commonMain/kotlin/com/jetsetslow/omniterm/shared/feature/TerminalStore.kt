package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.DiagnosticEvent
import com.jetsetslow.omniterm.shared.core.DiagnosticLogger
import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.LogLevel
import com.jetsetslow.omniterm.shared.core.WallClock
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.HostKey
import com.jetsetslow.omniterm.shared.platform.HostKeyDecision
import com.jetsetslow.omniterm.shared.platform.HostKeyTrust
import com.jetsetslow.omniterm.shared.platform.PlatformError
import com.jetsetslow.omniterm.shared.platform.SshAdapter
import com.jetsetslow.omniterm.shared.platform.SshEndpoint
import com.jetsetslow.omniterm.shared.platform.SshShell
import com.jetsetslow.omniterm.ui.TermKey
import com.jetsetslow.omniterm.ui.terminalGeometryMatches
import com.jetsetslow.omniterm.ui.terminalKeyAllowedInReadOnly
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Lifecycle phase of a single shared terminal session. */
enum class TerminalPhase { Connecting, AwaitingHostKey, Connected, Reconnecting, Disconnected }

data class TerminalGeometry(val columns: Int, val rows: Int)

/**
 * One session's portable state. Everything a renderer needs to decide *what* to draw lives here;
 * how it is drawn stays in each platform UI.
 */
data class TerminalSessionState(
    val id: String,
    val endpoint: SshEndpoint,
    val phase: TerminalPhase,
    val persistent: Boolean,
    val tmuxName: String? = null,
    val geometry: TerminalGeometry,
    /**
     * Bumped by every accepted resize. Work started under an older generation (notably tmux history
     * hydration) must be discarded rather than published over the newer geometry.
     */
    val geometryGeneration: Long = 0,
    val readOnly: Boolean = false,
    val backgrounded: Boolean = false,
    val historyHydrated: Boolean = false,
    val hydratedHistoryLines: Int = 0,
    val error: String? = null,
) {
    val connected: Boolean get() = phase == TerminalPhase.Connected
}

/** A tmux session left resumable, kept so the picker can offer it without an SSH round trip. */
data class ResumableSession(
    val tmuxName: String,
    val endpoint: SshEndpoint,
    val leftAtEpochMillis: Long,
)

/** A first-use or changed host key awaiting an explicit user decision. */
data class HostKeyApproval(
    val requestId: String,
    val endpoint: SshEndpoint,
    val presented: HostKey,
    val previous: HostKey?,
) {
    val changed: Boolean get() = previous != null
}

enum class SplitLayout { SideBySide, Stacked }

data class TerminalState(
    val sessions: List<TerminalSessionState> = emptyList(),
    val resumable: List<ResumableSession> = emptyList(),
    val focusedSessionId: String? = null,
    val split: Boolean = false,
    val paneSessionIds: List<String?> = listOf(null, null),
    val focusedPane: Int = 0,
    val layout: SplitLayout = SplitLayout.SideBySide,
    val pendingApproval: HostKeyApproval? = null,
    val connecting: Boolean = false,
    val error: String? = null,
) {
    fun session(id: String?): TerminalSessionState? = id?.let { key -> sessions.firstOrNull { it.id == key } }

    /**
     * The single session that owns keyboard input. In split view that is the focused pane's
     * session, never the last-attached one — acting on the wrong pane silently types into another
     * host.
     */
    val inputSession: TerminalSessionState?
        get() = if (split) session(paneSessionIds.getOrNull(focusedPane)) else session(focusedSessionId)
}

sealed interface TerminalAction {
    data class Connect(
        val endpoint: SshEndpoint,
        val geometry: TerminalGeometry,
        val persistent: Boolean = false,
        val tmuxName: String? = null,
    ) : TerminalAction

    /** Abandons an in-flight connect, mirroring the Android "Cancel" action on the connect screen. */
    data object CancelConnect : TerminalAction
    data class ResolveHostKey(val requestId: String, val trust: Boolean) : TerminalAction
    data class Focus(val sessionId: String) : TerminalAction
    data class Resize(val sessionId: String, val geometry: TerminalGeometry) : TerminalAction
    data class SetReadOnly(val sessionId: String, val readOnly: Boolean) : TerminalAction
    /** Typed or pasted text, routed to [TerminalState.inputSession]; the caller never picks the target. */
    data class SendInput(val bytes: ByteArray) : TerminalAction {
        override fun equals(other: Any?): Boolean = other is SendInput && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    /**
     * A non-printable key. Separate from [SendInput] because read-only treats the two differently:
     * paging is allowed, typing is not.
     */
    data class SendKey(val key: TermKey, val encoded: ByteArray) : TerminalAction {
        override fun equals(other: Any?): Boolean =
            other is SendKey && key == other.key && encoded.contentEquals(other.encoded)

        override fun hashCode(): Int = 31 * key.hashCode() + encoded.contentHashCode()
    }

    data class Disconnect(val sessionId: String) : TerminalAction
    data class LeaveOrBackground(val sessionId: String) : TerminalAction
    data class Reconnect(val sessionId: String) : TerminalAction
    data object EnterSplit : TerminalAction
    data object ExitSplit : TerminalAction
    data class AssignPane(val pane: Int, val sessionId: String?) : TerminalAction
    data class FocusPane(val pane: Int) : TerminalAction
    data class SetLayout(val layout: SplitLayout) : TerminalAction
}

/** Bytes arriving from a session's PTY. Implementations feed a terminal emulator; never a log. */
fun interface TerminalOutputSink {
    fun onBytes(sessionId: String, bytes: ByteArray)
}

/**
 * Loads scrollback for a resumed tmux session. It is a separate contract because hydration is slow,
 * cancellable, and must lose to any newer geometry.
 */
fun interface TerminalHistoryLoader {
    suspend fun load(session: TerminalSessionState, progress: (OperationProgress) -> Unit): List<String>
}

/**
 * Portable terminal/session orchestration (IOS-030). It owns connection phases, the session
 * registry, focus and split-pane ownership, host-key approval, read-only input policy, resize
 * ordering, and tmux resume — with no platform types. Foreground services, notifications, and
 * navigation stay in the platform composition roots that observe [state].
 */
class TerminalStore(
    private val scope: CoroutineScope,
    private val ssh: SshAdapter,
    private val hostKeyTrust: HostKeyTrust,
    private val ids: IdGenerator,
    private val clock: WallClock,
    private val outputSink: TerminalOutputSink = TerminalOutputSink { _, _ -> },
    private val historyLoader: TerminalHistoryLoader? = null,
    private val logger: DiagnosticLogger = DiagnosticLogger { },
) : FeatureStore<TerminalState, TerminalAction> {
    private val mutableState = MutableStateFlow(TerminalState())
    override val state: StateFlow<TerminalState> = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 8)
    override val effects: SharedFlow<StoreEffect> = mutableEffects.asSharedFlow()

    private val jobs = mutableMapOf<String, Job>()
    private val shells = mutableMapOf<String, SshShell>()
    private var approval: Pair<String, CompletableDeferred<Boolean>>? = null

    override fun dispatch(action: TerminalAction) {
        when (action) {
            is TerminalAction.Connect -> connect(action)
            TerminalAction.CancelConnect -> cancelConnect()
            is TerminalAction.ResolveHostKey -> resolveHostKey(action)
            is TerminalAction.Focus -> mutableState.update { it.copy(focusedSessionId = action.sessionId) }
            is TerminalAction.Resize -> resize(action.sessionId, action.geometry)
            is TerminalAction.SetReadOnly -> updateSession(action.sessionId) { it.copy(readOnly = action.readOnly) }
            is TerminalAction.SendInput -> sendInput(action.bytes, key = null)
            is TerminalAction.SendKey -> sendInput(action.encoded, action.key)
            is TerminalAction.Disconnect -> disconnect(action.sessionId)
            is TerminalAction.LeaveOrBackground -> leaveOrBackground(action.sessionId)
            is TerminalAction.Reconnect -> reconnect(action.sessionId)
            TerminalAction.EnterSplit -> enterSplit()
            TerminalAction.ExitSplit -> exitSplit()
            is TerminalAction.AssignPane -> assignPane(action.pane, action.sessionId)
            is TerminalAction.FocusPane -> mutableState.update { it.copy(focusedPane = action.pane.coerceIn(0, 1)) }
            is TerminalAction.SetLayout -> mutableState.update { it.copy(layout = action.layout) }
        }
    }

    // ── Connection ──

    private fun connect(request: TerminalAction.Connect) {
        // One connect at a time, matching Android's `if (isTerminalConnecting) return`. Letting a
        // second attempt supersede the first means two half-opened SSH channels race to attach, and
        // whichever loses must be found and closed; refusing removes the race instead of policing
        // it. The user's escape hatch is CancelConnect, not a competing Connect.
        if (mutableState.value.connecting) {
            logger.log(DiagnosticEvent("terminal.connect.refused", mapOf("reason" to "already-connecting")))
            return
        }

        val sessionId = ids.nextId()
        val session = TerminalSessionState(
            id = sessionId,
            endpoint = request.endpoint,
            phase = TerminalPhase.Connecting,
            persistent = request.persistent,
            tmuxName = request.tmuxName,
            geometry = request.geometry,
        )
        mutableState.update {
            it.copy(
                sessions = it.sessions + session,
                focusedSessionId = sessionId,
                connecting = true,
                error = null,
            )
        }
        if (mutableState.value.split) assignPane(mutableState.value.focusedPane, sessionId)
        jobs[sessionId] = scope.launch { runConnect(sessionId, request.endpoint) }
    }

    private suspend fun runConnect(sessionId: String, endpoint: SshEndpoint) {
        try {
            if (!authorizeHostKey(sessionId, endpoint)) return
            val current = mutableState.value.session(sessionId) ?: return
            when (val opened = ssh.openShell(endpoint, current.geometry.columns, current.geometry.rows)) {
                is CapabilityResult.Available -> attach(sessionId, opened.value)
                is CapabilityResult.Unsupported -> fail(sessionId, opened.reason)
                is CapabilityResult.Failed -> fail(sessionId, describe(opened.error))
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            fail(sessionId, "Connection failed")
            logger.log(
                DiagnosticEvent(
                    "terminal.connect.failed",
                    mapOf("session" to sessionId, "kind" to (error::class.simpleName ?: "error")),
                    LogLevel.Warning,
                ),
            )
        }
    }

    /** @return true when the connection may proceed. */
    private suspend fun authorizeHostKey(sessionId: String, endpoint: SshEndpoint): Boolean {
        val presented = when (val result = ssh.presentedHostKey(endpoint)) {
            is CapabilityResult.Available -> result.value
            is CapabilityResult.Unsupported -> {
                fail(sessionId, result.reason); return false
            }
            is CapabilityResult.Failed -> {
                fail(sessionId, describe(result.error)); return false
            }
        }
        return when (val decision = hostKeyTrust.evaluate(endpoint, presented)) {
            HostKeyDecision.Trusted -> true
            is HostKeyDecision.Malformed -> {
                fail(sessionId, "Rejected malformed host key: ${decision.reason}")
                false
            }
            HostKeyDecision.Unknown, is HostKeyDecision.Changed -> {
                val previous = (decision as? HostKeyDecision.Changed)?.previous
                val approved = requestApproval(sessionId, endpoint, presented, previous)
                if (!approved) {
                    fail(sessionId, if (previous != null) "Host key changed and was rejected" else "Host key was not trusted")
                    return false
                }
                hostKeyTrust.trust(endpoint, presented)
                // The session may have been torn down while the dialog was open.
                mutableState.value.session(sessionId) != null
            }
        }
    }

    private suspend fun requestApproval(
        sessionId: String,
        endpoint: SshEndpoint,
        presented: HostKey,
        previous: HostKey?,
    ): Boolean {
        val pending = CompletableDeferred<Boolean>()
        approval = sessionId to pending
        val request = HostKeyApproval(ids.nextId(), endpoint, presented, previous)
        updateSession(sessionId) { it.copy(phase = TerminalPhase.AwaitingHostKey) }
        mutableState.update { it.copy(pendingApproval = request) }
        return try {
            pending.await()
        } finally {
            if (approval?.second === pending) approval = null
            mutableState.update { if (it.pendingApproval?.requestId == request.requestId) it.copy(pendingApproval = null) else it }
        }
    }

    private fun resolveHostKey(action: TerminalAction.ResolveHostKey) {
        val pending = mutableState.value.pendingApproval ?: return
        if (pending.requestId != action.requestId) return
        approval?.second?.complete(action.trust)
    }

    private suspend fun attach(sessionId: String, shell: SshShell) {
        val session = mutableState.value.session(sessionId)
        if (session == null) {
            // Stale completion: the session was disconnected or superseded while connecting.
            shell.close()
            logger.log(DiagnosticEvent("terminal.connect.discarded", mapOf("session" to sessionId)))
            return
        }
        shells[sessionId] = shell
        updateSession(sessionId) { it.copy(phase = TerminalPhase.Connected, error = null) }
        mutableState.update { it.recomputeConnecting() }
        scope.launch { pump(sessionId, shell) }
        if (session.persistent && historyLoader != null) hydrateHistory(sessionId)
    }

    private suspend fun pump(sessionId: String, shell: SshShell) {
        try {
            shell.output.collect { bytes -> outputSink.onBytes(sessionId, bytes) }
            // A completed output flow is a server-side disconnect, not a user action.
            if (mutableState.value.session(sessionId)?.phase == TerminalPhase.Connected) {
                updateSession(sessionId) { it.copy(phase = TerminalPhase.Disconnected, error = "Server disconnected") }
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            updateSession(sessionId) { it.copy(phase = TerminalPhase.Disconnected, error = "Connection lost") }
        }
    }

    private suspend fun hydrateHistory(sessionId: String) {
        val loader = historyLoader ?: return
        val session = mutableState.value.session(sessionId) ?: return
        val captured = session.geometry
        val capturedGeneration = session.geometryGeneration
        val lines = runCatching { loader.load(session) { } }.getOrNull() ?: return
        val now = mutableState.value.session(sessionId) ?: return
        val sameGrid = terminalGeometryMatches(
            captured.columns,
            captured.rows,
            capturedGeneration,
            now.geometry.columns,
            now.geometry.rows,
            now.geometryGeneration,
        )
        if (!sameGrid || now.phase != TerminalPhase.Connected) {
            // A resize (or teardown) won the race. Publishing this scrollback would restore a screen
            // laid out for the old geometry over the live one.
            logger.log(DiagnosticEvent("terminal.history.discarded", mapOf("session" to sessionId)))
            return
        }
        updateSession(sessionId) { it.copy(historyHydrated = true, hydratedHistoryLines = lines.size) }
    }

    // ── Input, geometry, focus ──

    /**
     * Read-only is enforced here, below every UI: no accessory bar, paste, or hardware keyboard
     * path can reach the remote by bypassing a view. [key] is null for typed/pasted text, which
     * read-only always refuses; a key is refused unless [terminalKeyAllowedInReadOnly] permits it,
     * exactly as Android's `sendKey` does.
     */
    private fun sendInput(bytes: ByteArray, key: TermKey?) {
        val target = mutableState.value.inputSession ?: return
        if (target.readOnly && (key == null || !terminalKeyAllowedInReadOnly(key))) {
            logger.log(DiagnosticEvent("terminal.input.blocked", mapOf("session" to target.id)))
            return
        }
        if (!target.connected) return
        val shell = shells[target.id] ?: return
        scope.launch { shell.send(bytes) }
    }

    private fun resize(sessionId: String, geometry: TerminalGeometry) {
        if (geometry.columns <= 0 || geometry.rows <= 0) return
        val session = mutableState.value.session(sessionId) ?: return
        if (session.geometry == geometry) return
        updateSession(sessionId) {
            it.copy(geometry = geometry, geometryGeneration = it.geometryGeneration + 1)
        }
        val shell = shells[sessionId] ?: return
        scope.launch { shell.resize(geometry.columns, geometry.rows) }
    }

    // ── Teardown ──

    /**
     * Abandons the in-flight attempt. Mirrors Android's `cancelConnect()`: the job is cancelled and
     * the pending session removed, so a shell that still arrives afterwards owns nothing and is
     * closed by [attach].
     */
    private fun cancelConnect() {
        mutableState.value.sessions
            .filter { it.phase == TerminalPhase.Connecting || it.phase == TerminalPhase.AwaitingHostKey }
            .forEach { disconnect(it.id) }
        mutableState.update { it.recomputeConnecting().copy(error = null) }
    }

    private fun disconnect(sessionId: String) {
        teardown(sessionId, null)
        mutableState.update { current ->
            val remaining = current.sessions.filterNot { it.id == sessionId }
            current.copy(
                sessions = remaining,
                focusedSessionId = current.focusedSessionId.takeIf { it != sessionId } ?: remaining.firstOrNull()?.id,
                paneSessionIds = current.paneSessionIds.map { if (it == sessionId) null else it },
            ).recomputeConnecting()
        }
    }

    private fun leaveOrBackground(sessionId: String) {
        val session = mutableState.value.session(sessionId) ?: return
        if (!session.persistent) {
            // Non-tmux sessions stay alive but lose focus and their pane; the platform decides
            // whether the process may keep running there.
            mutableState.update { current ->
                current.copy(
                    sessions = current.sessions.map { if (it.id == sessionId) it.copy(backgrounded = true) else it },
                    focusedSessionId = current.focusedSessionId.takeIf { it != sessionId },
                    paneSessionIds = current.paneSessionIds.map { if (it == sessionId) null else it },
                )
            }
            return
        }
        teardown(sessionId, null)
        val resumable = session.tmuxName?.let {
            ResumableSession(it, session.endpoint, clock.nowEpochMillis())
        }
        mutableState.update { current ->
            val remaining = current.sessions.filterNot { it.id == sessionId }
            current.copy(
                sessions = remaining,
                resumable = if (resumable == null) current.resumable else current.resumable.filterNot { it.tmuxName == resumable.tmuxName } + resumable,
                focusedSessionId = current.focusedSessionId.takeIf { it != sessionId } ?: remaining.firstOrNull()?.id,
                paneSessionIds = current.paneSessionIds.map { if (it == sessionId) null else it },
            ).recomputeConnecting()
        }
    }

    private fun reconnect(sessionId: String) {
        val session = mutableState.value.session(sessionId) ?: return
        if (session.phase == TerminalPhase.Connected) return
        closeShell(sessionId)
        jobs.remove(sessionId)?.cancel()
        updateSession(sessionId) { it.copy(phase = TerminalPhase.Reconnecting, error = null) }
        jobs[sessionId] = scope.launch { runConnect(sessionId, session.endpoint) }
    }

    /** Cancels a session's work and closes its shell without touching the session list. */
    private fun teardown(sessionId: String, reason: String?) {
        jobs.remove(sessionId)?.cancel()
        closeShell(sessionId)
        // Only this session's own approval prompt is answered; another session's must survive.
        approval?.takeIf { it.first == sessionId }?.second?.complete(false)
        if (reason != null) {
            logger.log(DiagnosticEvent("terminal.session.superseded", mapOf("session" to sessionId, "reason" to reason)))
        }
        mutableState.update { current ->
            current.copy(sessions = current.sessions.filterNot { it.id == sessionId })
        }
    }

    private fun closeShell(sessionId: String) {
        val shell = shells.remove(sessionId) ?: return
        // Close on the store scope so a cancelled session still releases its channel.
        scope.launch { shell.close() }
    }

    // ── Split panes ──

    private fun enterSplit() {
        mutableState.update { current ->
            if (current.split) return@update current
            current.copy(
                split = true,
                focusedPane = 0,
                paneSessionIds = listOf(current.focusedSessionId, null),
            )
        }
    }

    private fun exitSplit() {
        mutableState.update { current ->
            if (!current.split) return@update current
            val focused = current.paneSessionIds.getOrNull(current.focusedPane) ?: current.focusedSessionId
            current.copy(split = false, focusedSessionId = focused, paneSessionIds = listOf(null, null))
        }
    }

    private fun assignPane(pane: Int, sessionId: String?) {
        val index = pane.coerceIn(0, 1)
        mutableState.update { current ->
            val panes = current.paneSessionIds.toMutableList()
            // One session can never own two panes: the same PTY in both would double-apply input.
            for (i in panes.indices) if (panes[i] == sessionId && i != index) panes[i] = null
            panes[index] = sessionId
            current.copy(paneSessionIds = panes, focusedSessionId = sessionId ?: current.focusedSessionId)
        }
    }

    // ── Helpers ──

    private fun fail(sessionId: String, message: String) {
        if (mutableState.value.session(sessionId) == null) return
        updateSession(sessionId) { it.copy(phase = TerminalPhase.Disconnected, error = message) }
        mutableState.update { it.recomputeConnecting().copy(error = message) }
        mutableEffects.tryEmit(StoreEffect.Message(message))
    }

    /**
     * `connecting` covers the whole in-flight window, host-key prompt included: an unanswered
     * approval dialog is still an open attempt, and a second Connect behind it would strand it.
     * A per-session reconnect is deliberately not counted — it belongs to a session that already
     * exists and must not block opening a different host.
     */
    private fun TerminalState.recomputeConnecting(): TerminalState = copy(
        connecting = sessions.any { it.phase == TerminalPhase.Connecting || it.phase == TerminalPhase.AwaitingHostKey },
    )

    private fun updateSession(sessionId: String, transform: (TerminalSessionState) -> TerminalSessionState) {
        mutableState.update { current ->
            current.copy(sessions = current.sessions.map { if (it.id == sessionId) transform(it) else it })
        }
    }

    private fun describe(error: PlatformError): String = when (error) {
        PlatformError.Cancelled -> "Connection cancelled"
        PlatformError.PermissionDenied -> "Permission denied"
        PlatformError.AuthenticationFailed -> "Authentication failed"
        PlatformError.NetworkUnavailable -> "Network unavailable"
        PlatformError.HostKeyRejected -> "Host key rejected"
        PlatformError.NotFound -> "Host not found"
        PlatformError.StorageUnavailable -> "Storage unavailable"
        is PlatformError.Protocol -> "Connection failed (${error.code})"
    }

    override fun close() {
        approval?.second?.complete(false)
        approval = null
        jobs.values.forEach { it.cancel() }
        jobs.clear()
        val open = shells.values.toList()
        shells.clear()
        // NonCancellable so the scope cancellation below cannot leave PTY channels open; the
        // coroutine is not a child of the store scope's job.
        scope.launch(NonCancellable) { open.forEach { runCatching { it.close() } } }
        mutableState.update { TerminalState(resumable = it.resumable) }
        scope.cancel()
    }
}
