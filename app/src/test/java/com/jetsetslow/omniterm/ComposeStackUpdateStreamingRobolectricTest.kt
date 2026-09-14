package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
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
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Stack Update, exercised as it actually runs rather than as a command string.
 *
 * `ComposeCommandTest` already pins what the update script contains — four named stages, a
 * non-fatal pull, `build --pull`, `up -d`. What it cannot show is how the app behaves while that
 * script is running on a real host, and update is the slowest action in the app: a registry pull
 * followed by a local image build can go minutes between writes, and the build stage is exactly
 * where a private-registry pull failure lands on stderr.
 *
 * Three things can go wrong there and none of them are visible from the command string:
 * output could be buffered until the command exits (leaving the user watching an empty box through
 * the whole build), a non-fatal pull failure could be swallowed so the local-build fallback looks
 * like a silent success, and a failure-flavoured stream could be replayed automatically. The
 * handover names all three.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ComposeStackUpdateStreamingRobolectricTest {
    private val project = "fixture-stack"
    private val workingDir = "/srv/fixture-stack"
    private val configFiles = "compose.yml"

    /**
     * Update's stages reach the popup while the command is still running, not in one batch at the
     * end. Pull and build are minutes apart on a real host.
     */
    @Test
    fun updateStreamsEachStageWhileStillRunning() = withUpdate { model, transport ->
        transport.emit("[1/4] Pulling images\n")
        withTimeout(5_000) { while (!model.actionStreamOutput.contains("[1/4]")) delay(10) }
        assertTrue("update must show it is still running", model.actionStreamRunning)
        assertFalse(
            "later stages must not already be present — that would mean output was batched",
            model.actionStreamOutput.contains("[4/4]"),
        )

        transport.emit("[2/4] Building images\n")
        withTimeout(5_000) { while (!model.actionStreamOutput.contains("[2/4]")) delay(10) }
        assertTrue("an earlier stage must not be dropped as later ones arrive", model.actionStreamOutput.contains("[1/4]"))

        transport.emit("[3/4] Recreating services\n[4/4] Checking services\n")
        transport.finish()
        withTimeout(5_000) { while (model.actionStreamRunning) delay(10) }
        for (stage in listOf("[1/4]", "[2/4]", "[3/4]", "[4/4]")) {
            assertTrue("stage $stage missing from the finished transcript", model.actionStreamOutput.contains(stage))
        }
    }

    /**
     * A pull that fails (private registry, no login) is non-fatal by design: the script carries on
     * and builds the image locally. The warning must still be readable afterwards, or that fallback
     * is indistinguishable from a clean pull.
     */
    @Test
    fun pullFailureStaysVisibleWhileTheLocalBuildProceeds() = withUpdate { model, transport ->
        transport.emit("[1/4] Pulling images\n")
        transport.emit("Warning: pull failed for fixture-stack, building locally instead\n")
        withTimeout(5_000) { while (!model.actionStreamOutput.contains("Warning:")) delay(10) }
        assertTrue("a non-fatal pull failure must not end the run", model.actionStreamRunning)

        transport.emit("[2/4] Building images\n[3/4] Recreating services\n[4/4] Checking services\n")
        transport.finish()
        withTimeout(5_000) { while (model.actionStreamRunning) delay(10) }

        assertTrue(
            "the pull warning must survive to the end — it is the only sign the image was built locally",
            model.actionStreamOutput.contains("Warning: pull failed"),
        )
        assertTrue("the local build must still have run", model.actionStreamOutput.contains("[2/4]"))
        assertTrue("the stack must still be recreated", model.actionStreamOutput.contains("[3/4]"))
        assertEquals("a tolerated pull failure must not re-run update", 1, transport.commands.size)
    }

    /** The Update button must send the audited update script, and send it exactly once. */
    @Test
    fun updateSendsTheAuditedScriptOnceAndNeverReplaysIt() = withUpdate { model, transport ->
        transport.emit("SSH Error: connection reset\n")
        transport.finish()
        withTimeout(5_000) { while (model.actionStreamRunning) delay(10) }

        assertEquals(
            "Update must send the same script ComposeCommandTest audits, not a hand-rolled variant",
            listOf(RemoteCommands.dockerComposeAction(project, workingDir, configFiles, "update", runtime = "docker")),
            transport.commands.toList(),
        )
        assertTrue("the failure must be shown, not swallowed", model.actionStreamOutput.contains("SSH Error"))
    }

    /**
     * A stack with no compose working directory cannot have an update run for it. It must say so
     * rather than dispatch a `cd ` into nowhere.
     */
    @Test
    fun aStackWithoutAWorkingDirectoryRunsNothing() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = UpdateTransport()
        try {
            val model = newModel(transport, store, main)
            withContext(main) { model.dockerStackUpdate("standalone", "", configFiles, "docker") }
            delay(300)
            assertEquals("no command may be dispatched for a stack with no compose dir", 0, transport.commands.size)
            assertTrue("the refusal must be explained", model.actionStreamOutput.isNotBlank())
            assertFalse(model.actionStreamRunning)
        } finally {
            transport.finish(); store.clear(); Dispatchers.resetMain(); main.close()
        }
    }

    private fun withUpdate(body: suspend (AppViewModel, UpdateTransport) -> Unit) = runBlocking {
        // Real time: AppViewModel does its database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = UpdateTransport()
        try {
            val model = newModel(transport, store, main)
            withContext(main) { model.dockerStackUpdate(project, workingDir, configFiles, "docker") }
            withTimeout(5_000) { while (transport.commands.isEmpty()) delay(10) }
            body(model, transport)
        } finally {
            transport.finish()
            store.clear()
            Dispatchers.resetMain()
            main.close()
        }
    }

    private suspend fun newModel(
        transport: UpdateTransport,
        store: ViewModelStore,
        main: kotlinx.coroutines.CoroutineDispatcher,
    ): AppViewModel {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repository = AppRepository(AppDatabase.getDatabase(application))
        val id = repository.insertServer(
            ServerEntity(name = "Stack fixture", host = "fixture.invalid", username = "fixture"),
        ).toInt()
        val model = withContext(main) { AppViewModel(application, transport) }
        store.put("test", model)
        withTimeout(10_000) { while (model.servers.value.none { it.id == id }) delay(10) }
        withContext(main) { model.selectedServerId = id }
        return model
    }

    /**
     * Holds the stream open so the test controls exactly when each stage lands. A channel rather
     * than a shared flow: `execStream` then returns precisely when the last chunk has been
     * delivered, so the assertions never race a drain timer.
     */
    private class UpdateTransport : SshTransport {
        val commands = CopyOnWriteArrayList<String>()
        private val chunks = Channel<String>(Channel.UNLIMITED)

        suspend fun emit(chunk: String) { chunks.send(chunk) }
        fun finish() { chunks.close() }

        // loadDocker() runs as update's onComplete; it must find nothing rather than fail.
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            commands.add(command)
            val transcript = StringBuilder()
            for (chunk in chunks) {
                transcript.append(chunk)
                onChunk(chunk)
            }
            return transcript.toString()
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
