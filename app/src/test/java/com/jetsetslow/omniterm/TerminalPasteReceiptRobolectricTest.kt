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
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalPasteReceiptRobolectricTest {
    @Test fun pasteProgressWaitsForWriterAndEveryCommandKeepsCapturedPane() = exercise(fail = false)
    @Test fun partialWriteFailureShowsUncertaintyAndCannotCloseReplacement() = exercise(fail = true)

    @Test fun oversizedControlPasteNeedsSmallerSectionInsteadOfWaiting() = exercise(fail = false, oversized = true)

    private fun exercise(fail: Boolean, oversized: Boolean = false) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = HeldTransport()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val id = repo.insertServer(ServerEntity(name = "Paste fixture", host = "fixture.invalid", username = "fixture")).toInt()
            serverId = id
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            withTimeout(10_000) { while (model.servers.value.none { it.id == id }) delay(10) }
            withContext(main) {
                model.saveTmuxControlMode(false)
                model.updateTerminalReadOnly(false)
                model.selectedServerId = id
                model.connectTerminal()
            }
            withTimeout(10_000) { while (model.currentSession?.isConnected != true || model.isTerminalConnecting) delay(10) }
            val shell = checkNotNull(model.currentSession)
            transport.shell.armed = true
            val payload = "a".repeat(if (oversized) 2_000_000 else 9_000)
            withContext(main) {
                // Exercise the actual ViewModel encoding and ordered IO worker independently of
                // remote tmux discovery; the device case covers real control-mode selection.
                shell.controlMode = true
                shell.controlReady = true
                shell.activePaneId = "%1"
                model.pasteText(payload, model.captureTerminalPasteTarget(shell))
            }
            if (oversized) {
                assertFalse("Oversized input must not enter the writer", transport.shell.started.isCompleted)
                assertTrue(checkNotNull(shell.pasteFeedback).message, shell.pasteFeedback!!.message.contains("smaller section"))
                assertFalse(shell.pasteFeedback!!.busy)
                return@runBlocking
            }
            withTimeout(5_000) { transport.shell.started.await() }
            assertTrue("Pending writer must expose progress", shell.pasteFeedback?.busy == true)
            val replacement = HeldShell()
            withContext(main) {
                shell.activePaneId = "%2"
                shell.controlPaneChangeRevision.incrementAndGet()
                if (fail) shell.session = replacement
            }
            transport.shell.failure = if (fail) IOException("fixture partial write") else null
            transport.shell.release.complete(Unit)
            withTimeout(5_000) { while (shell.pasteFeedback?.busy != false) delay(10) }
            val feedback = checkNotNull(shell.pasteFeedback).message
            if (fail) {
                assertTrue(feedback, feedback.contains("Some text may have been sent"))
                withTimeout(5_000) { while (!transport.shell.closed.value) delay(10) }
                assertFalse("An old failure cannot close the replacement", replacement.closed.value)
                assertTrue("An old failure cannot disconnect the replacement", shell.isConnected)
            } else {
                assertEquals("Sent 9000 characters to terminal.", feedback)
                assertTrue("Large paste must exercise more than one wire command", transport.shell.pasteWrites.size > 1)
                assertTrue(transport.shell.pasteWrites.all { it.startsWith("send-keys -t %1 ") })
                assertFalse(transport.shell.pasteWrites.any { it.contains("send-keys -t %2 ") })
            }
        } finally {
            transport.shell.release.complete(Unit)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                repository?.let { repo -> serverId?.let { repo.getServerById(it)?.let { row -> repo.deleteServer(row) } } }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private class HeldTransport : SshTransport {
        val shell = HeldShell()
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?) = ""
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit) = ""
        override suspend fun testConnection(creds: SshCredentials): String? = null
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?) = shell
    }
    private class HeldShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val pasteWrites = CopyOnWriteArrayList<String>()
        @Volatile var armed = false
        @Volatile var failure: Exception? = null
        override suspend fun write(bytes: ByteArray) {
            if (!armed) return
            started.complete(Unit)
            release.await()
            failure?.let { throw it }
            pasteWrites.add(bytes.decodeToString())
        }
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
