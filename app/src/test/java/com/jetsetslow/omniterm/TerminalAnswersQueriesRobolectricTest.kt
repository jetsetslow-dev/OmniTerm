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
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * The terminal answers the remote's device queries over the same channel. fish asks for the
 * device attributes at every start and reads no input for 10 seconds while it waits for an answer.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalAnswersQueriesRobolectricTest {

    @Test
    fun deviceQueriesAreAnsweredOnTheTerminalChannel() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val shell = RecordingShell()
        val repo = AppRepository(AppDatabase.getDatabase(ApplicationProvider.getApplicationContext<Application>()))
        var id = 0
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            id = repo.insertServer(ServerEntity(name = "Query fixture", host = "fixture.invalid", username = "fixture")).toInt()
            val model = withContext(main) { AppViewModel(application, ShellOnlyTransport(shell)) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) {
                model.saveTmuxControlMode(false)
                model.updateTerminalReadOnly(false)
                model.selectedServerId = id
                model.connectTerminal()
            }
            waitWhileOnMain(main, 10_000) { model.currentSession?.isConnected != true || model.isTerminalConnecting }

            withTimeout(5_000) { while (shell.output.subscriptionCount.value == 0) delay(10) }

            shell.output.emit("Welcome\r\n\u001B[c".toByteArray())
            assertEquals(listOf("\u001B[?1;2c"), shell.awaitReplies())

            shell.output.emit("\u001B[2J\u001B[H> \u001B[6n".toByteArray())
            assertEquals(listOf("\u001B[1;3R"), shell.awaitReplies())
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

    private class ShellOnlyTransport(private val shell: RecordingShell) : SshTransport {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?) = ""
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit) = ""
        override suspend fun testConnection(creds: SshCredentials): String? = null
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?) = shell
    }

    private class RecordingShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        private val replies = CopyOnWriteArrayList<String>()
        override suspend fun write(bytes: ByteArray) {
            bytes.decodeToString().takeIf { it.startsWith("\u001B[") }?.let { replies.add(it) }
        }

        /** Escape sequences written since the last call; anything the app types itself is ignored. */
        suspend fun awaitReplies(): List<String> {
            withTimeout(5_000) { while (replies.isEmpty()) delay(10) }
            delay(100)
            return replies.toList().also { replies.clear() }
        }
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
