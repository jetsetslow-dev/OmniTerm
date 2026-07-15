package com.jetsetslow.omniterm.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.SessionService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * A singleton that holds active [ShellSession] objects to ensure they survive
 * activity destruction as long as the app process is alive.
 */
object TerminalSessionManager {
    private val supervisor = SupervisorJob()
    val scope = CoroutineScope(Dispatchers.Default + supervisor)
    private var app: Application? = null
    var isBackgroundKeepAlive = true

    fun init(application: Application) {
        app = application
    }

    /** The list of all active, background-capable SSH terminal sessions. */
    val activeSessions = mutableStateListOf<ShellSession>()

    /**
     * Process-scoped terminal attachment state. A Recents swipe destroys the Activity/ViewModel
     * while the foreground service deliberately keeps SSH sessions alive; keeping pane ownership
     * here lets the next Activity restore the same single/split arrangement instead of presenting
     * two live sessions as unrelated background terminals.
     */
    var currentSessionId by mutableStateOf<String?>(null)
    var activeSshTab by mutableStateOf(0)
    var multiSshSessionId1 by mutableStateOf<String?>(null)
    var multiSshSessionId2 by mutableStateOf<String?>(null)
    var multiSshLayout by mutableStateOf(MultiSshLayout.SideBySide)
    var multiSshFocusedPane by mutableStateOf(1)

    /** The count of currently connected sessions, used for keep-alive service logic. */
    var activeKeepaliveSessionsCount by mutableStateOf(0)

    fun updateKeepaliveCount() {
        activeKeepaliveSessionsCount = activeSessions.count { it.isConnected || it.reconnecting }
    }

    fun startKeepAliveService() {
        val context = app ?: return
        val eligible = activeSessions.filter { it.isConnected || it.reconnecting }
        if (!isBackgroundKeepAlive || eligible.isEmpty()) return
        val sessionData = encodeSessionNotificationPayload(eligible)
        if (sessionData.isEmpty()) return
        val intent = android.content.Intent(context, SessionService::class.java).apply {
            action = SessionService.ACTION_UPDATE_SESSIONS
            putStringArrayListExtra(SessionService.EXTRA_SESSIONS, sessionData)
        }
        try {
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        } catch (e: Exception) {
            android.util.Log.w("TerminalSessions", "Unable to start keep-alive session service", e)
        }
    }

    fun stopKeepAliveService() {
        val context = app ?: return
        val intent = android.content.Intent(context, SessionService::class.java)
        context.stopService(intent)
    }

    fun cleanupSession(s: ShellSession) {
        val closing = synchronized(s.sessionOwnershipLock) {
            s.isConnected = false
            s.userClosed = true
            s.reconnectJob?.cancel()
            s.session
        }
        s.controlInitJob?.cancel()
        s.controlPaneRefreshJob?.cancel()
        s.historyHydrationJob?.cancel()
        s.controlReplySignal.close()
        // close() is idempotent; doing it here guarantees the transport reader thread and the
        // SSH connection die with the session even if a caller forgot to close first. Run it off any
        // caller thread (this is often invoked from Main): JSch's disconnect can block on network I/O,
        // which on a dead/changed network would freeze the UI and trap the user in a stuck session.
        scope.launch(Dispatchers.IO) { try { closing.close() } catch (_: Exception) {} }
        s.terminalOutputJob?.cancel()
        s.terminalInputJob?.cancel()
        s.terminalInputQueue?.let { synchronized(it) { it.closed = true; it.channel.close() } }
        s.resizeJob?.cancel()
        s.resizeChannel.close()
        activeSessions.remove(s)
        clearUiReferences(s.id)
        updateKeepaliveCount()
        if (activeKeepaliveSessionsCount == 0) stopKeepAliveService()
        else startKeepAliveService() // Update remaining notifications
    }

    fun disconnectFromNotification(sessionId: String) {
        val session = activeSessions.find { it.id == sessionId } ?: return
        cleanupSession(session)
    }

    fun disconnectAllFromNotification() {
        clearAll()
        updateKeepaliveCount()
        stopKeepAliveService()
    }

    fun publishTerminalSnapshot(session: ShellSession) {
        val (generation, snap) = synchronized(session.emulator) {
            val generation = session.snapshotGeneration.incrementAndGet()
            val total = session.emulator.rowCount()
            val count = session.viewportRowCount.coerceIn(1, 300)
            val maxFirst = (total - count).coerceAtLeast(0)
            val first = if (session.followTail) maxFirst else session.viewportFirstRow.coerceIn(0, maxFirst)
            session.viewportFirstRow = first
            generation to session.emulator.snapshotRange(first, count)
        }
        // Mutation of SnapshotState must happen on Main thread.
        scope.launch(Dispatchers.Main.immediate) {
            if (generation > session.publishedSnapshotGeneration) {
                session.publishedSnapshotGeneration = generation
                session.terminalScreen = snap
            }
        }
    }

    /**
     * Finds a session by its unique ID.
     */
    fun findSession(id: String): ShellSession? {
        return activeSessions.find { it.id == id }
    }

    /**
     * Adds a new session to the manager.
     */
    fun addSession(session: ShellSession) {
        activeSessions.add(session)
    }

    /**
     * Removes a session from the manager.
     */
    fun removeSession(session: ShellSession) {
        activeSessions.remove(session)
        clearUiReferences(session.id)
    }

    private fun clearUiReferences(sessionId: String) {
        if (currentSessionId == sessionId) currentSessionId = null
        if (multiSshSessionId1 == sessionId) multiSshSessionId1 = null
        if (multiSshSessionId2 == sessionId) multiSshSessionId2 = null
        if (activeSessions.isEmpty()) resetUiAttachment()
    }

    private fun resetUiAttachment() {
        currentSessionId = null
        activeSshTab = 0
        multiSshSessionId1 = null
        multiSshSessionId2 = null
        multiSshLayout = MultiSshLayout.SideBySide
        multiSshFocusedPane = 1
    }

    /**
     * Clears all sessions and ensures their underlying SSH connections are closed.
     * Note: the caller should usually call s.session.close() before removing.
     */
    fun clearAll() {
        activeSessions.forEach {
            val closing = synchronized(it.sessionOwnershipLock) {
                it.isConnected = false
                it.userClosed = true
                it.reconnectJob?.cancel()
                it.session
            }
            it.controlInitJob?.cancel()
            it.controlPaneRefreshJob?.cancel()
            it.historyHydrationJob?.cancel()
            it.controlReplySignal.close()
            // Close off-thread: a synchronous JSch disconnect can block on network I/O and freeze
            // whatever thread (often Main) called clearAll().
            scope.launch(Dispatchers.IO) { try { closing.close() } catch (_: Exception) {} }
            it.terminalOutputJob?.cancel()
            it.terminalInputJob?.cancel()
            it.terminalInputQueue?.let { queue -> synchronized(queue) { queue.closed = true; queue.channel.close() } }
            it.resizeJob?.cancel()
            it.resizeChannel.close()
        }
        activeSessions.clear()
        resetUiAttachment()
        updateKeepaliveCount()
        stopKeepAliveService()
    }
}
