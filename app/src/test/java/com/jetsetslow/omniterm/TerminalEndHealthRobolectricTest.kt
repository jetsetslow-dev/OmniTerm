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
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
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
import org.junit.Assert.assertNull
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
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalEndHealthRobolectricTest {
    @Test fun aDroppedConnectionResetsHealthWhileItReconnects() = exercise(End.Drop)

    @Test fun closingATerminalLeavesHealthAlone() = exercise(End.UserClose)

    @Test fun aShellExitingOnTheServerLeavesHealthAlone() = exercise(End.RemoteExit)

    private enum class End { Drop, UserClose, RemoteExit }

    private fun exercise(end: End) = runBlocking {
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
                End.RemoteExit -> transport.shell.exitOnServer()
            }

            if (end == End.Drop) {
                waitWhileOnMain(main, 10_000) { model.metricsErrorsById[id] == null }
                assertEquals("Connection lost. Waiting for current metrics.", withContext(main) { model.metricsErrorsById[id] })
                awaitHealth(repo, id, HEALTH_SCORE_UNKNOWN)
            } else {
                waitWhileOnMain(main, 10_000) { model.activeSessions.contains(session) }
                // A reset could follow the teardown asynchronously, so health must also stay put.
                repeat(25) {
                    assertNull(withContext(main) { model.metricsErrorsById[id] })
                    assertEquals(87, checkNotNull(repo.getServerById(id)).healthScore)
                    delay(20)
                }
            }
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
        @Volatile private var opened = 0

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

        fun exitOnServer() {
            exitStatus.value = 0
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
}
