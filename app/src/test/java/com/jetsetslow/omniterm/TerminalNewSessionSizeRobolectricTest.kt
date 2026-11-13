package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * A session opened while the visible pane changed size (the keyboard shown or hidden, a split, a
 * rotation during the sign-in) takes the pane's size once it is shown: the emulator, the remote
 * terminal and the session agree. Before, the session noted the new size without resizing either,
 * so the first measure was skipped and the remote drew for a grid the screen did not have.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalNewSessionSizeRobolectricTest {

    @Test
    fun aSessionOpenedWhileThePaneResizedMatchesThePane() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = GatedTransport()
        val repo = AppRepository(AppDatabase.getDatabase(ApplicationProvider.getApplicationContext<Application>()))
        var id = 0
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            id = repo.insertServer(ServerEntity(name = "Size fixture", host = "fixture.invalid", username = "fixture")).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) {
                model.saveTmuxControlMode(false)
                model.selectedServerId = id
                model.connectTerminal()
            }
            waitWhileOnMain(main, 10_000) { model.currentSession?.isConnected != true || model.isTerminalConnecting }
            val first = checkNotNull(model.currentSession)
            withContext(main) { model.resizeTerminalFor(first, 100, 30) }

            // A second session starts at the visible pane's size and waits in its sign-in.
            transport.gate = CompletableDeferred()
            withContext(main) { model.connectTerminal() }
            withTimeout(5_000) { while (transport.opened.size < 2) delay(10) }
            assertEquals(100 to 30, transport.opened[1])
            // The keyboard comes up meanwhile and the visible pane shrinks.
            withContext(main) { model.resizeTerminalFor(first, 100, 18) }
            transport.gate?.complete(Unit)
            waitWhileOnMain(main, 10_000) {
                model.isTerminalConnecting || model.currentSession === first || model.currentSession?.isConnected != true
            }
            val second = checkNotNull(model.currentSession)

            // Its pane measures what the visible pane measures now.
            withContext(main) { model.resizeTerminalFor(second, 100, 18) }
            withTimeoutOrNull(3_000) { while (transport.shells[1].resizes.lastOrNull() != (100 to 18)) delay(10) }
            val grid = synchronized(second.emulator) { second.emulator.cols to second.emulator.rows }
            assertEquals("emulator", 100 to 18, grid)
            assertEquals("remote terminal", 100 to 18, transport.shells[1].resizes.lastOrNull() ?: transport.opened[1])
            assertEquals("session", 100 to 18, second.termCols to second.termRows)
            assertEquals("reconnect size", 100 to 18, second.lastCols to second.lastRows)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                repo.getServerById(id)?.let { repo.deleteServer(it) }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** Opens a new shell per call; a call waits on [gate] when one is set. */
    private class GatedTransport : SshTransport {
        @Volatile var gate: CompletableDeferred<Unit>? = null
        val opened = CopyOnWriteArrayList<Pair<Int, Int>>()
        val shells = CopyOnWriteArrayList<RecordingShell>()
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?) = ""
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit) = ""
        override suspend fun testConnection(creds: SshCredentials): String? = null
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession {
            opened += cols to rows
            gate?.await()
            return RecordingShell().also { shells += it }
        }
    }

    private class RecordingShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        val resizes = CopyOnWriteArrayList<Pair<Int, Int>>()
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) {
            resizes += cols to rows
        }
        override fun close() { closed.value = true }
    }
}
