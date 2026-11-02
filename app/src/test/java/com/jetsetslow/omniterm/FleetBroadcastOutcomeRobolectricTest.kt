package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SSH_CONNECTION_LOST
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastResultItem
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * What a broadcast host's card says when the command did not simply succeed. A dropped connection
 * showed the partial output and "failed" with no reason; with Run in tmux the command survives the
 * drop, and the card reconnects and finishes with the run's output.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class FleetBroadcastOutcomeRobolectricTest {

    @Test
    fun aDroppedConnectionSaysTheCommandMayStillBeRunning() = withBroadcast { model, main, transport ->
        transport.streamReplies.add(Reply(listOf("half of the out"), "SSH Error: $SSH_CONNECTION_LOST"))
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast("long-job", listOf(serverId))
        }
        val item = awaitCard(model) { card -> card.status != BroadcastStatus.Running }
        assertEquals(BroadcastStatus.Failure, item.status)
        assertEquals("half of the out", item.output)
        assertEquals(
            "Connection lost before the command finished. It may still be running on the host.",
            item.note,
        )
    }

    @Test
    fun aNonZeroExitSaysItsStatus() = withBroadcast { model, main, transport ->
        transport.streamReplies.add(Reply(listOf("nope\n"), "SSH Error: command failed (2): nope\n"))
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast("false", listOf(serverId))
        }
        val item = awaitCard(model) { card -> card.status != BroadcastStatus.Running }
        assertEquals(BroadcastStatus.Failure, item.status)
        assertEquals("Exited with status 2.", item.note)
    }

    @Test
    fun aHostWithoutTmuxWaitsForTheUser() = withBroadcast { model, main, transport ->
        transport.execReplies.add(RemoteCommands.BROADCAST_NO_TMUX + "\n")
        withContext(main) {
            model.updateBroadcastInTmux(true)
            model.runFleetBroadcast("uptime", listOf(serverId))
        }
        val item = awaitCard(model) { card -> card.status != BroadcastStatus.Running }
        assertEquals(BroadcastStatus.NeedsTmux, item.status)
        assertEquals("tmux is not installed on Broadcast fixture.", item.note)
        assertTrue("nothing ran outside tmux", transport.streamed.isEmpty())
    }

    @Test
    fun aTmuxRunReconnectsAfterADropAndFinishesWithItsOutput() = withBroadcast { model, main, transport ->
        transport.execReplies.add("__OMNITERM_STARTED__\n")
        transport.streamReplies.add(Reply(listOf("step 1\n"), "SSH Error: $SSH_CONNECTION_LOST"))
        transport.streamReplies.add(Reply(listOf("step 1\nstep 2\n"), "step 1\nstep 2\n"))
        withContext(main) {
            model.updateBroadcastInTmux(true)
            model.runFleetBroadcast("apt-get upgrade -y", listOf(serverId))
        }
        val waiting = awaitCard(model) { card -> card.status == BroadcastStatus.Reconnecting }
        assertEquals("Connection lost. The command keeps running in tmux; reconnecting…", waiting.note)
        assertTrue("still running while it reconnects", model.isBroadcastExecuting)

        withContext(main) { model.reconnectBroadcastHost(serverId) }
        val done = awaitCard(model) { card -> card.status == BroadcastStatus.Success }
        assertEquals("the replayed log replaces the partial output", "step 1\nstep 2\n", done.output)
        assertEquals(null, done.note)
        waitWhileOnMain(main) { model.isBroadcastExecuting }

        val runId = checkNotNull(done.tmuxRunId)
        assertEquals(RemoteCommands.broadcastTmuxStart(runId), transport.execs.first())
        assertTrue(
            "the runner carries the command",
            transport.stdins.first()!!.contains("'apt-get upgrade -y'"),
        )
        assertEquals(listOf(RemoteCommands.broadcastTmuxFollow(runId)), transport.streamed.distinct())
        assertEquals("the finished run's files are removed", RemoteCommands.broadcastTmuxCleanup(runId), transport.execs.last())
    }

    @Test
    fun stoppingATmuxRunEndsItOnTheHost() = withBroadcast { model, main, transport ->
        transport.execReplies.add("__OMNITERM_STARTED__\n")
        transport.streamReplies.add(Reply(listOf("working\n"), null))
        withContext(main) {
            model.updateBroadcastInTmux(true)
            model.runFleetBroadcast("sleep 600", listOf(serverId))
        }
        awaitCard(model) { card -> card.output.contains("working") }
        withContext(main) { model.stopFleetBroadcast() }
        val stopped = awaitCard(model) { card -> card.status == BroadcastStatus.Failure }
        assertEquals("Stopped.", stopped.note)
        waitWhileOnMain(main) { transport.execs.none { cmd -> cmd == RemoteCommands.broadcastTmuxStop(stopped.tmuxRunId!!) } }
        assertFalse(model.isBroadcastExecuting)
    }

    private var serverId = 0

    private suspend fun awaitCard(model: AppViewModel, until: (BroadcastResultItem) -> Boolean): BroadcastResultItem {
        var found: BroadcastResultItem? = null
        waitWhileOnMain(main, 10_000) {
            found = model.broadcastResults.firstOrNull()?.takeIf(until)
            found == null
        }
        return checkNotNull(found)
    }

    private lateinit var main: kotlinx.coroutines.CoroutineDispatcher

    private fun withBroadcast(
        block: suspend (AppViewModel, kotlinx.coroutines.CoroutineDispatcher, ScriptedTransport) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val executor = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        main = executor
        Dispatchers.setMain(executor)
        val store = ViewModelStore()
        val transport = ScriptedTransport()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            serverId = repository.insertServer(
                ServerEntity(name = "Broadcast fixture", host = "fixture.invalid", username = "fixture", status = "online"),
            ).toInt()
            val model = withContext(executor) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(executor, 10_000) { model.servers.value.none { it.id == serverId } }
            block(model, executor, transport)
        } finally {
            transport.release.complete(Unit)
            clearViewModelsAndAwaitTerminalJobs(store, executor)
            Dispatchers.resetMain()
            executor.close()
        }
    }

    /** One streamed reply: its chunks, then its result, or waits for [ScriptedTransport.release] when null. */
    private data class Reply(val chunks: List<String>, val result: String?)

    /** Answers execs and streams from scripted replies, in order, and records what was sent. */
    private class ScriptedTransport : SshTransport {
        val execReplies = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val streamReplies = java.util.concurrent.ConcurrentLinkedQueue<Reply>()
        val execs = java.util.concurrent.CopyOnWriteArrayList<String>()
        val stdins = java.util.concurrent.CopyOnWriteArrayList<String?>()
        val streamed = java.util.concurrent.CopyOnWriteArrayList<String>()
        val release = CompletableDeferred<Unit>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            // The OS probe, metrics and other background reads get nothing; only broadcast commands are scripted.
            if (!command.contains("omniterm-bc-") && !command.contains("broadcast-")) return ""
            execs.add(command)
            stdins.add(stdin)
            return execReplies.poll() ?: ""
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            streamed.add(command)
            val reply = streamReplies.poll() ?: return ""
            reply.chunks.forEach { onChunk(it) }
            reply.result?.let { return it }
            release.await()
            return ""
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
