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

    /** The count of currently connected sessions, used for keep-alive service logic. */
    var activeKeepaliveSessionsCount by mutableStateOf(0)

    fun updateKeepaliveCount() {
        activeKeepaliveSessionsCount = activeSessions.count { it.isConnected }
    }

    fun startKeepAliveService() {
        val context = app ?: return
        if (!isBackgroundKeepAlive || activeSessions.isEmpty()) return
        val sessionData = ArrayList(
            activeSessions.toList().filter { it.isConnected }.map { "${it.id}|${it.serverName}" }
        )
        val intent = android.content.Intent(context, SessionService::class.java).apply {
            action = SessionService.ACTION_UPDATE_SESSIONS
            putStringArrayListExtra(SessionService.EXTRA_SESSIONS, sessionData)
        }
        try {
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    fun stopKeepAliveService() {
        val context = app ?: return
        val intent = android.content.Intent(context, SessionService::class.java)
        context.stopService(intent)
    }

    fun cleanupSession(s: ShellSession) {
        s.isConnected = false
        s.userClosed = true
        s.reconnectJob?.cancel()
        // close() is idempotent; doing it here guarantees the transport reader thread and the
        // SSH connection die with the session even if a caller forgot to close first. Run it off any
        // caller thread (this is often invoked from Main): JSch's disconnect can block on network I/O,
        // which on a dead/changed network would freeze the UI and trap the user in a stuck session.
        val closing = s.session
        scope.launch(Dispatchers.IO) { try { closing.close() } catch (_: Exception) {} }
        s.terminalOutputJob?.cancel()
        s.terminalInputJob?.cancel()
        s.terminalInputChannel?.close()
        activeSessions.remove(s)
        updateKeepaliveCount()
        if (activeKeepaliveSessionsCount == 0) stopKeepAliveService()
        else startKeepAliveService() // Update remaining notifications
    }

    fun publishTerminalSnapshot(session: ShellSession) {
        val snap = synchronized(session.emulator) {
            val total = session.emulator.rowCount()
            val count = session.viewportRowCount.coerceIn(1, 300)
            val maxFirst = (total - count).coerceAtLeast(0)
            val first = if (session.followTail) maxFirst else session.viewportFirstRow.coerceIn(0, maxFirst)
            session.viewportFirstRow = first
            session.emulator.snapshotRange(first, count)
        }
        // Mutation of SnapshotState must happen on Main thread.
        scope.launch(Dispatchers.Main.immediate) {
            session.terminalScreen = snap
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
    }

    /**
     * Clears all sessions and ensures their underlying SSH connections are closed.
     * Note: the caller should usually call s.session.close() before removing.
     */
    fun clearAll() {
        activeSessions.forEach {
            it.userClosed = true
            it.reconnectJob?.cancel()
            // Close off-thread: a synchronous JSch disconnect can block on network I/O and freeze
            // whatever thread (often Main) called clearAll().
            val closing = it.session
            scope.launch(Dispatchers.IO) { try { closing.close() } catch (_: Exception) {} }
            it.isConnected = false
            it.terminalOutputJob?.cancel()
            it.terminalInputJob?.cancel()
            it.terminalInputChannel?.close()
        }
        activeSessions.clear()
    }
}
