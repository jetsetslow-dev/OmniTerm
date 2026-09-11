package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TmuxResumeLatencyRobolectricTest {
    @Test
    fun slowOptionalCaptureDoesNotHoldAReadyShellAtOpeningChannel() = checkResume(controlMode = false)

    @Test
    fun slowHistoryDoesNotBlockControlScreenOrInput() = checkResume(controlMode = true)

    @Test
    fun newTmuxDoesNotWaitForHistoryBeforeItsSessionExists() = checkResume(controlMode = false, fresh = true)

    private fun checkResume(controlMode: Boolean, fresh: Boolean = false) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = CaptureBlockedTransport(controlMode)
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            val id = repository.insertServer(ServerEntity(
                name = "Resume fixture", host = "fixture.invalid", username = "fixture", persistentSession = true,
            )).toInt()
            repository.upsertPersistentSession(PersistentSessionEntity("omniterm-latency-fixture", id, "Resume fixture"))
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            withTimeout(10_000) {
                while (model.servers.value.none { it.id == id } || model.restorablePersistentSessions.isEmpty()) delay(10)
            }
            withContext(main) {
                model.saveTmuxControlMode(controlMode)
                if (fresh) {
                    model.selectedServerId = id
                    model.connectTerminal()
                } else model.resumePersistentSession("omniterm-latency-fixture")
            }
            withTimeout(5_000) { transport.opened.await() }
            val usable = withTimeoutOrNull(2_000) {
                while (model.currentSessionId == null || model.isTerminalConnecting) delay(10)
                true
            } ?: false
            assertTrue("A ready SSH channel must attach without waiting for an optional screen/history capture", usable)
            assertTrue(transport.shell.writes.any {
                it.contains(if (fresh) "new-session" else "attach-session -t omniterm-latency-fixture")
            })
            if (controlMode) {
                withTimeout(5_000) { transport.captureStarted.await() }
                val ready = withTimeoutOrNull(2_000) {
                    while (model.currentSession?.controlReady != true) delay(10)
                    true
                } ?: false
                assertTrue("Control mode must paint and enable input without waiting for full history", ready)
                val session = checkNotNull(model.currentSession)
                val beforeHistory = synchronized(session.emulator) { session.emulator.snapshot().rows.toString() }
                assertTrue("Quiet pane must already be visible", beforeHistory.contains("VISIBLE_FIXTURE"))
                withContext(main) { model.pasteText("input-fixture") }
                withTimeout(2_000) {
                    while (transport.shell.writes.none { it.contains("send-keys -t %1") }) delay(10)
                }
                transport.captureRelease.complete(Unit)
                withTimeout(5_000) { session.historyHydrationJob?.join() }
                val afterHistory = synchronized(session.emulator) { session.emulator.snapshot().rows.toString() }
                assertTrue("History hydration must preserve the visible pane", afterHistory.contains("VISIBLE_FIXTURE"))
                assertTrue("Full history must still load", afterHistory.contains("HISTORY_FIXTURE"))
            }
        } finally {
            transport.captureRelease.complete(Unit)
            withContext(main) { store.clear(); TerminalSessionManager.clearAll() }
            Dispatchers.resetMain()
            main.close()
        }
    }

    private class CaptureBlockedTransport(private val controlMode: Boolean) : SshTransport {
        val opened = CompletableDeferred<Unit>()
        val captureStarted = CompletableDeferred<Unit>()
        val captureRelease = CompletableDeferred<Unit>()
        val shell = FakeShell(controlMode)
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            if (command == RemoteCommands.TMUX_CHECK) return "yes"
            if (command.contains("has-session")) return "yes"
            if (controlMode) {
                if (command.contains("pane_id")) return "%1"
                if (command.contains("cursor_x")) return "0 0"
                if (command.contains("capture-pane")) return "VISIBLE_FIXTURE"
            } else if (command.contains("capture-pane")) captureRelease.await()
            return ""
        }
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String {
            if (command.contains("capture-pane")) {
                captureStarted.complete(Unit)
                captureRelease.await()
                onChunk("HISTORY_FIXTURE\n")
            }
            return ""
        }
        override suspend fun testConnection(creds: SshCredentials): String? = null
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession {
            onPhaseChange?.invoke("Opening channel…")
            opened.complete(Unit)
            return shell
        }
    }

    private class FakeShell(private val controlMode: Boolean) : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        val writes = java.util.concurrent.CopyOnWriteArrayList<String>()
        override suspend fun write(bytes: ByteArray) {
            val command = bytes.decodeToString()
            writes.add(command)
            if (controlMode) {
                val reply = if (command.contains("attach-session")) {
                    "%begin 1 1 0\n%end 1 1 0\n%session-changed $0 omniterm-latency-fixture\n"
                } else "%begin 1 2 1\n%end 1 2 1\n"
                output.emit(reply.toByteArray())
            }
        }
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
