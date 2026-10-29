package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HEALTH_SCORE_UNKNOWN
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Only a dropped connection that OmniTerm reconnects from resets a host's health, with "Connection
 * lost. Waiting for current metrics.". Closing a terminal, or the shell exiting on the server, says
 * nothing about the host's metrics and leaves them alone. The Flutter app keeps the same rule, in
 * `shell_view_model_test.dart` and `host_status_probe_test.dart`.
 *
 * A shell that exits on the server also stays on screen, ended, with its scrollback and exit status,
 * as it does in the Flutter app, until the user dismisses it; nothing reconnects it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalEndHealthRobolectricTest {
    @Test fun aDroppedConnectionResetsHealthWhileItReconnects() = exercise(End.Drop)

    @Test fun closingATerminalLeavesHealthAlone() = exercise(End.UserClose)

    @Test fun aShellExitingOnTheServerLeavesHealthAlone() = exercise(End.RemoteExit)

    @Test fun anExitedShellStaysWithItsScrollbackUntilDismissed() = exercise(End.RemoteExit) { model, session, transport, main ->
        withContext(main) {
            assertTrue(model.activeSessions.contains(session))
            assertFalse(session.isConnected)
            assertEquals(3, session.endedExitStatus)
            assertTrue(model.terminalBufferTextFor(session, full = true).contains(LAST_WORDS))
            assertEquals("an ended shell keeps nothing alive", 0, TerminalSessionManager.activeKeepaliveSessionsCount)
            model.retrySession(session.id)
        }
        delay(300)
        withContext(main) {
            assertFalse("an exit is not a drop and is never reopened", session.reconnecting)
            assertEquals(1, transport.opened)
            // Closing it only dismisses it: there is nothing left to disconnect or terminate.
            model.requestDisconnectSession(session.id)
            assertNull(model.pendingDisconnectSessionId)
            assertFalse(model.activeSessions.contains(session))
        }
    }

    private enum class End { Drop, UserClose, RemoteExit }

    private fun exercise(
        end: End,
        afterEnd: (suspend (AppViewModel, ShellSession, ShellOnlyTransport, CoroutineDispatcher) -> Unit)? = null,
    ) = runBlocking<Unit> {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = ShellOnlyTransport()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val id = repo.insertServer(
                ServerEntity(name = "Health fixture", host = "fixture.invalid", username = "fixture", healthScore = 87)
            ).toInt()
            serverId = id
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            // Every host starts unknown on launch; score this one only once that has happened.
            awaitHealth(repo, id, HEALTH_SCORE_UNKNOWN)
            repo.updateHealthScore(id, 87)
            withContext(main) {
                model.selectedServerId = id
                model.connectTerminal()
            }
            withTimeout(10_000) { transport.shell.reading.await() }
            val session = checkNotNull(withContext(main) { model.currentSession })

            when (end) {
                End.Drop -> transport.shell.drop()
                End.UserClose -> withContext(main) { model.disconnectSession(session.id) }
                End.RemoteExit -> {
                    transport.shell.print("$LAST_WORDS\r\n")
                    waitWhileOnMain(main, 10_000) { !model.terminalBufferTextFor(session, full = true).contains(LAST_WORDS) }
                    transport.shell.exitOnServer(status = 3)
                }
            }

            if (end == End.Drop) {
                waitWhileOnMain(main, 10_000) { model.metricsErrorsById[id] == null }
                assertEquals("Connection lost. Waiting for current metrics.", withContext(main) { model.metricsErrorsById[id] })
                awaitHealth(repo, id, HEALTH_SCORE_UNKNOWN)
            } else {
                // A close removes the session; an exit on the server leaves it listed, ended.
                waitWhileOnMain(main, 10_000) {
                    if (end == End.UserClose) model.activeSessions.contains(session) else session.endedExitStatus == null
                }
                // A reset could follow the teardown asynchronously, so health must also stay put.
                repeat(25) {
                    assertNull(withContext(main) { model.metricsErrorsById[id] })
                    assertEquals(87, checkNotNull(repo.getServerById(id)).healthScore)
                    delay(20)
                }
            }
            afterEnd?.invoke(model, session, transport, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                repository?.let { repo -> serverId?.let { repo.getServerById(it)?.let { row -> repo.deleteServer(row) } } }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private suspend fun awaitHealth(repo: AppRepository, id: Int, health: Int) = withTimeout(10_000) {
        while (checkNotNull(repo.getServerById(id)).healthScore != health) delay(10)
    }

    /**
     * Opens [shell], and a fresh one for any reconnect. Every command waits for good, so the
     * background health probes never finish and never write a reason of their own.
     */
    private class ShellOnlyTransport : SshTransport {
        val shell = EndableShell()
        @Volatile var opened = 0
            private set

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = awaitCancellation()

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = awaitCancellation()

        override suspend fun testConnection(creds: SshCredentials): String? = awaitCancellation()

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = if (opened++ == 0) shell else EndableShell()
    }

    /** A shell that can drop its connection, or end as a remote `exit` does. */
    private class EndableShell : TerminalSession {
        private val bytes = Channel<ByteArray>()
        val reading = CompletableDeferred<Unit>()
        override val output: Flow<ByteArray> = flow {
            reading.complete(Unit)
            for (chunk in bytes) emit(chunk)
        }
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)

        fun drop() {
            bytes.close(IOException("Connection reset"))
        }

        suspend fun print(text: String) = bytes.send(text.toByteArray())

        fun exitOnServer(status: Int = 0) {
            exitStatus.value = status
            remoteExited.value = true
            bytes.close()
        }

        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() {
            closed.value = true
            bytes.close()
        }
    }

    private companion object {
        const val LAST_WORDS = "logout: the last words before the exit"
    }
}
