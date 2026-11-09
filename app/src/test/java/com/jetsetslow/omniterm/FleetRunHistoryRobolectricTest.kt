package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetRunHostEntity
import com.jetsetslow.omniterm.data.FleetRunSummary
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.FleetTargetMode
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Fleet's run history: each Broadcast run is kept once it ends, with each host's result, so a run
 * can be looked at again after its cards are cleared or the app restarts.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class FleetRunHistoryRobolectricTest {

    @Test
    fun aFinishedRunIsKeptWithEachHostsResult() = withFleet { model, main, transport ->
        transport.replies[NAS] = "up 3 days\n"
        transport.replies[PI] = "SSH Error: command failed (2): nope\n"
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast("uptime", listOf(nasId, piId))
        }
        val run = awaitRuns(1).single()
        assertEquals("uptime", run.run.command)
        assertEquals(FleetRunHistory.SOURCE_FLEET, run.run.source)
        assertNull("no saved script picked", run.run.scriptName)
        assertEquals(2, run.hosts)
        assertEquals(1, run.succeeded)
        assertTrue(run.run.finishedAt >= run.run.startedAt)

        val hosts = model.fleetRunResults(run.run.id).associateBy { it.serverName }
        assertEquals(BroadcastStatus.Success, hosts.getValue("nas").status)
        assertEquals("up 3 days\n", hosts.getValue("nas").output)
        assertEquals(BroadcastStatus.Failure, hosts.getValue("pi").status)
        assertEquals("Exited with status 2.", hosts.getValue("pi").note)

        // The cards go; the run stays.
        withContext(main) { model.clearBroadcastOutputs() }
        assertTrue(withContext(main) { model.broadcastResults.isEmpty() })
        assertEquals(1, repository.fleetRunsFlow.first().size)
    }

    @Test
    fun aRetryIsItsOwnRunAndLeavesTheFirstResultsAlone() = withFleet { model, main, transport ->
        transport.replies[NAS] = "ok\n"
        transport.replies[PI] = "SSH Error: command failed (1): busy\n"
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast("apt-get update", listOf(nasId, piId))
        }
        val first = awaitRuns(1).single()
        transport.replies[PI] = "done\n"
        withContext(main) { model.retryFailedBroadcastHosts() }
        val runs = awaitRuns(2)
        val retry = runs.first()
        assertEquals(FleetRunHistory.SOURCE_RETRY, retry.run.source)
        assertEquals("apt-get update", retry.run.command)
        assertEquals("a retry keeps only the hosts it ran", listOf("pi"), model.fleetRunResults(retry.run.id).map { it.serverName })
        assertEquals(BroadcastStatus.Success, model.fleetRunResults(retry.run.id).single().status)

        val firstHosts = model.fleetRunResults(first.run.id).associateBy { it.serverName }
        assertEquals("the first run still says the host failed", BroadcastStatus.Failure, firstHosts.getValue("pi").status)
        assertEquals(BroadcastStatus.Success, firstHosts.getValue("nas").status)
    }

    @Test
    fun aHostThatFinishesLaterUpdatesItsOwnRun() = withFleet { model, main, transport ->
        transport.execReplies[NAS] = RemoteCommands.BROADCAST_NO_TMUX + "\n"
        withContext(main) {
            model.updateBroadcastInTmux(true)
            model.runFleetBroadcast("uptime", listOf(nasId))
        }
        val waiting = awaitRuns(1).single()
        assertEquals(BroadcastStatus.NeedsTmux, model.fleetRunResults(waiting.run.id).single().status)

        transport.replies[NAS] = "up\n"
        withContext(main) { model.runBroadcastHostWithoutTmux(nasId) }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || model.broadcastResults.single().status != BroadcastStatus.Success }
        withTimeout(10_000) {
            while (repository.fleetRunHosts(waiting.run.id).single().status != BroadcastStatus.Success.name) kotlinx.coroutines.delay(20)
        }
        val runs = repository.fleetRunsFlow.first()
        assertEquals("the same run, not a second one", 1, runs.size)
        assertEquals(waiting.run.startedAt, runs.single().run.startedAt)
        assertEquals("up\n", model.fleetRunResults(waiting.run.id).single().output)
    }

    @Test
    fun aRunKeepsTheEndOfALongOutputAndNotThePlaceholderValues() = withFleet { model, main, transport ->
        val long = "x".repeat(FleetRunHistory.OUTPUT_CHARS + 500) + "THE END\n"
        transport.replies[NAS] = long
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast("echo {{token}}", listOf(nasId), mapOf("token" to "s3cret-value"))
        }
        val run = awaitRuns(1).single()
        assertEquals("the command as written", "echo {{token}}", run.run.command)
        assertFalse(run.run.command.contains("s3cret-value"))
        assertTrue("the transport was given the value", transport.commands.any { it.contains("s3cret-value") })
        val host = model.fleetRunResults(run.run.id).single()
        assertEquals(FleetRunHistory.OUTPUT_CHARS, host.output.length)
        assertTrue(host.output.endsWith("THE END\n"))
        assertTrue(host.truncated)
        assertTrue(model.fleetRunReport(run.run, listOf(host)).startsWith("$ echo {{token}}\n"))
    }

    @Test
    fun useAgainFillsBroadcastWithTheScriptAndHostsWithoutRunning() = withFleet { model, main, transport ->
        repository.insertScript(
            QuickScriptEntity(emoji = "UP", name = "Uptime check", command = "uptime -p", color = "cyan", category = "Fleet", availableForFleet = true),
        )
        val script = repository.getAllScripts().last { it.name == "Uptime check" }
        val scriptId = script.id
        transport.replies[NAS] = "up\n"
        transport.replies[PI] = "up\n"
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.broadcastPreset = script
            model.broadcastCommandText = script.command
            model.runFleetBroadcast(script.command, listOf(nasId, piId))
        }
        val run = awaitRuns(1).single()
        assertEquals("Uptime check", run.run.scriptName)
        repository.deleteServerAndDependents(piId)
        val ran = transport.commands.size

        withContext(main) {
            model.broadcastPreset = null
            model.broadcastCommandText = ""
            model.broadcastTargetMode = FleetTargetMode.Groups
            model.loadFleetRunIntoBroadcast(run.run, model.fleetRunResults(run.run.id).map { it.serverId })
        }
        waitWhileOnMain(main, 10_000) { model.broadcastCommandText.isEmpty() }
        withContext(main) {
            assertEquals("uptime -p", model.broadcastCommandText)
            assertEquals(scriptId, model.broadcastPreset?.id)
            assertEquals(FleetTargetMode.Servers, model.broadcastTargetMode)
            assertEquals("a deleted host is left out", listOf(nasId), model.broadcastTargetServerIds.toList())
            assertFalse(model.isBroadcastExecuting)
        }
        assertEquals("nothing ran", ran, transport.commands.size)
    }

    @Test
    fun theHistoryKeepsTheNewestRunsAndDeletesWholeRuns() = runBlocking {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repository = AppRepository(AppDatabase.getDatabase(application))
        repository.clearFleetRuns()
        fun run(key: String, at: Long) = FleetRunEntity(runKey = key, startedAt = at, finishedAt = at + 1, command = "cmd-$key")
        fun host(id: Int) = FleetRunHostEntity(runId = 0, serverId = id, serverName = "h$id", status = BroadcastStatus.Success.name, output = "out")
        repository.recordFleetRun(run("a", 1), listOf(host(1), host(2)), keep = 2)
        repository.recordFleetRun(run("b", 2), listOf(host(1)), keep = 2)
        val oldest = repository.fleetRunsFlow.first().single { it.run.runKey == "a" }.run.id
        repository.recordFleetRun(run("c", 3), listOf(host(3)), keep = 2)
        val kept = repository.fleetRunsFlow.first()
        assertEquals(listOf("c", "b"), kept.map { it.run.runKey })
        assertTrue("the dropped run's hosts go with it", repository.fleetRunHosts(oldest).isEmpty())

        // Saving a run again updates it: its row, and the hosts given; the others keep theirs.
        repository.recordFleetRun(run("b", 99).copy(finishedAt = 500), listOf(host(2)), keep = 2)
        val b = repository.fleetRunsFlow.first().single { it.run.runKey == "b" }
        assertEquals("it keeps when it started", 2L, b.run.startedAt)
        assertEquals(500L, b.run.finishedAt)
        assertEquals(listOf(1, 2), repository.fleetRunHosts(b.run.id).map { it.serverId }.sorted())

        repository.deleteFleetRun(b.run.id)
        assertTrue(repository.fleetRunHosts(b.run.id).isEmpty())
        assertEquals(listOf("c"), repository.fleetRunsFlow.first().map { it.run.runKey })
        repository.clearFleetRuns()
        assertTrue(repository.fleetRunsFlow.first().isEmpty())
    }

    private var nasId = 0
    private var piId = 0
    private lateinit var repository: AppRepository

    private suspend fun awaitRuns(count: Int): List<FleetRunSummary> = withTimeout(10_000) {
        repository.fleetRunsFlow.first { it.size >= count }
    }

    private fun withFleet(
        block: suspend (AppViewModel, CoroutineDispatcher, HostTransport) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val executor = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(executor)
        val store = ViewModelStore()
        val transport = HostTransport()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            repository = AppRepository(AppDatabase.getDatabase(application))
            repository.clearFleetRuns()
            nasId = repository.insertServer(ServerEntity(name = "nas", host = NAS, username = "fixture", status = "online")).toInt()
            piId = repository.insertServer(ServerEntity(name = "pi", host = PI, username = "fixture", status = "online")).toInt()
            val model = withContext(executor) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(executor, 10_000) { model.servers.value.none { it.id == piId } }
            block(model, executor, transport)
        } finally {
            clearViewModelsAndAwaitTerminalJobs(store, executor)
            Dispatchers.resetMain()
            executor.close()
        }
    }

    /** Answers each host from its own reply, so hosts running at once cannot swap answers. */
    private class HostTransport : SshTransport {
        val replies = ConcurrentHashMap<String, String>()
        val execReplies = ConcurrentHashMap<String, String>()
        val commands = CopyOnWriteArrayList<String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            // The OS probe, metrics and other background reads get nothing; only broadcast starts are scripted.
            if (!command.contains("omniterm-bc-") && !command.contains("broadcast-")) return ""
            commands.add(command)
            return execReplies[creds.host] ?: ""
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            commands.add(command)
            val reply = replies[creds.host] ?: return ""
            if (!reply.startsWith("SSH Error")) onChunk(reply)
            return reply
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

    private companion object {
        const val NAS = "nas.invalid"
        const val PI = "pi.invalid"
    }
}
