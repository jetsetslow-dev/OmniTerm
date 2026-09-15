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
import com.jetsetslow.omniterm.ui.FleetTargetMode
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * The three per-host diagnostics on Fleet — Uptime, DF, PS — stream their own output and leave
 * Broadcast alone.
 *
 * Compose's FleetScreen builds all three from one list and routes them through
 * `runStreamingAction`, which shares `actionStream*` state with every other streaming popup in the
 * app. Two things can go wrong and neither is visible from the button: a diagnostic could send the
 * wrong command (the list pairs label to command by hand), and it could disturb the Broadcast tab's
 * unsent command or target selection, which sit on the same view model. The Flutter port has a
 * guard for this; the Compose side had none, which is what the handover asked for.
 *
 * A Robolectric test rather than instrumentation on purpose: root-package instrumentation tests are
 * filtered out of required CI, so an androidTest here would have run in no gate at all.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class FleetDiagnosticStreamingRobolectricTest {
    @Test
    fun uptimeStreamsWithoutDisturbingBroadcast() = checkDiagnostic("Uptime", "uptime")

    @Test
    fun diskFreeStreamsWithoutDisturbingBroadcast() = checkDiagnostic("DF", "df -h")

    @Test
    fun processListStreamsWithoutDisturbingBroadcast() = checkDiagnostic("PS", "ps aux | head -5")

    private fun checkDiagnostic(label: String, expectedCommand: String) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = StreamingDiagnosticTransport()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            val id = repository.insertServer(
                ServerEntity(name = "Diagnostic fixture", host = "fixture.invalid", username = "fixture"),
            ).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            withTimeout(10_000) { while (model.servers.value.none { it.id == id }) delay(10) }
            val server = checkNotNull(model.servers.value.first { it.id == id })

            // Broadcast state the diagnostic must not touch, set to something recognisable first.
            withContext(main) {
                model.broadcastCommandText = "an unsent broadcast"
                model.broadcastTargetMode = FleetTargetMode.Servers
            }

            withContext(main) { model.runStreamingAction("$label · ${server.name}", expectedCommand, server = server) }

            // Output appears as it arrives, not only once the command finishes.
            withTimeout(5_000) { while (!model.actionStreamOutput.contains("first chunk")) delay(10) }
            assertTrue("a running diagnostic must show it is running", model.actionStreamRunning)
            assertFalse(
                "output must stream rather than appear only at completion",
                model.actionStreamOutput.contains("last chunk"),
            )
            assertTrue("the popup must name the host it dialled", model.actionStreamTitle.contains(server.name))

            transport.release.complete(Unit)
            withTimeout(5_000) { while (model.actionStreamRunning) delay(10) }
            assertTrue(model.actionStreamOutput.contains("last chunk"))

            assertEquals(
                "each button must send its own command, not the first one",
                listOf(expectedCommand),
                transport.commands.toList(),
            )
            assertEquals("the popup must dial the host it names", listOf("fixture.invalid"), transport.hosts.toList())
            assertEquals(
                "a read-only diagnostic must not consume the Broadcast tab's unsent command",
                "an unsent broadcast",
                model.broadcastCommandText,
            )
            assertEquals(FleetTargetMode.Servers, model.broadcastTargetMode)
        } finally {
            if (!transport.release.isCompleted) transport.release.complete(Unit)
            store.clear()
            Dispatchers.resetMain()
            main.close()
        }
    }

    /** Streams one chunk, waits to be released, then streams a second. */
    private class StreamingDiagnosticTransport : SshTransport {
        val release = CompletableDeferred<Unit>()
        val commands = java.util.concurrent.CopyOnWriteArrayList<String>()
        val hosts = java.util.concurrent.CopyOnWriteArrayList<String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            commands.add(command)
            hosts.add(creds.host)
            onChunk("first chunk\n")
            release.await()
            onChunk("last chunk\n")
            return "first chunk\nlast chunk\n"
        }

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = IdleShell()
    }

    private class IdleShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
