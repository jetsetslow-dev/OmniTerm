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
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.broadcastBatches
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Rolling Fleet runs: a few hosts at a time, in the confirmed order, stopping after a batch with a
 * failure when asked to; then "Retry" runs only the hosts that did not succeed and keeps the rest.
 * Before this every host started at once, so a bad update reached the whole fleet before the first
 * failure could be seen.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class FleetRollingRunRobolectricTest {

    @Test
    fun batchesKeepTheOrderAndAllAtOnceIsOneBatch() {
        assertEquals(listOf(listOf(1, 2), listOf(3, 4), listOf(5)), broadcastBatches(listOf(1, 2, 3, 4, 5), 2))
        assertEquals(listOf(listOf(1, 2, 3)), broadcastBatches(listOf(1, 2, 3), 0))
        assertEquals(listOf(listOf(1, 2, 3)), broadcastBatches(listOf(1, 2, 3), 5))
    }

    @Test
    fun aFailedBatchStopsTheRunAndRetryRunsOnlyTheRest() = withHosts { model, main, hosts, ids ->
        hosts.failing.add("b")
        withContext(main) {
            model.updateBroadcastBatchSize(2)
            model.updateBroadcastStopOnFailure(true)
            model.runFleetBroadcast(COMMAND, ids)
        }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }

        assertEquals(
            listOf("a" to BroadcastStatus.Success, "b" to BroadcastStatus.Failure, "c" to BroadcastStatus.NotRun, "d" to BroadcastStatus.NotRun),
            withContext(main) { model.broadcastResults.map { it.serverName.removePrefix("Rolling ") to it.status } },
        )
        assertEquals(
            "Not run: Rolling b did not succeed, and the run stops on a failure.",
            withContext(main) { model.broadcastResults[2].note },
        )
        // Hosts in one batch start together, in no fixed order.
        assertEquals("only the first batch ran", setOf("a", "b"), hosts.started().toSet())
        assertEquals(2, hosts.started().size)
        assertEquals("a batch's hosts ran together, and no more", 2, hosts.maxRunning.get())
        assertEquals(ids.drop(1), withContext(main) { model.broadcastRetryableIds })

        hosts.failing.clear()
        hosts.events.clear()
        hosts.maxRunning.set(0)
        withContext(main) { model.retryFailedBroadcastHosts() }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }

        assertEquals(
            "the retried hosts keep their places and the other card its result",
            listOf("a" to BroadcastStatus.Success, "b" to BroadcastStatus.Success, "c" to BroadcastStatus.Success, "d" to BroadcastStatus.Success),
            withContext(main) { model.broadcastResults.map { it.serverName.removePrefix("Rolling ") to it.status } },
        )
        assertEquals("ran on a\n", withContext(main) { model.broadcastResults[0].output })
        val retriedStarts = hosts.started()
        assertEquals("a is not run again", 3, retriedStarts.size)
        assertEquals("b and c are the first batch", setOf("b", "c"), retriedStarts.take(2).toSet())
        assertEquals("d is the second", "d", retriedStarts[2])
        assertTrue(
            "d waited for b and c",
            hosts.events.indexOf("start d") > maxOf(hosts.events.indexOf("end b"), hosts.events.indexOf("end c")),
        )
        assertEquals(emptyList<Int>(), withContext(main) { model.broadcastRetryableIds })

        val report = withContext(main) { model.broadcastReport() }
        assertTrue(report, report.startsWith("$ $COMMAND\n"))
        assertTrue(report, report.contains("== Rolling a · complete\nran on a\n"))
        assertTrue(report, report.contains("== Rolling d · complete\nran on d\n"))
    }

    @Test
    fun withoutStopOnFailureEveryBatchRunsInTheConfirmedOrder() = withHosts { model, main, hosts, ids ->
        hosts.failing.add("b")
        withContext(main) {
            model.updateBroadcastBatchSize(1)
            model.updateBroadcastStopOnFailure(false)
            model.runFleetBroadcast(COMMAND, ids.reversed())
        }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }

        assertEquals(listOf("d", "c", "b", "a"), hosts.started())
        assertEquals(1, hosts.maxRunning.get())
        assertEquals(
            listOf("d" to BroadcastStatus.Success, "c" to BroadcastStatus.Success, "b" to BroadcastStatus.Failure, "a" to BroadcastStatus.Success),
            withContext(main) { model.broadcastResults.map { it.serverName.removePrefix("Rolling ") to it.status } },
        )
    }

    @Test
    fun stoppingARollingRunLeavesTheWaitingHostsNotRun() = withHosts { model, main, hosts, ids ->
        hosts.holding.add("a")
        withContext(main) {
            model.updateBroadcastBatchSize(2)
            model.runFleetBroadcast(COMMAND, ids)
        }
        waitWhileOnMain(main, 10_000) { model.broadcastResults.getOrNull(1)?.status != BroadcastStatus.Success }
        assertEquals(
            "a holds the first batch open, so c and d wait",
            listOf(BroadcastStatus.Running, BroadcastStatus.Success, BroadcastStatus.Waiting, BroadcastStatus.Waiting),
            withContext(main) { model.broadcastResults.map { it.status } },
        )
        withContext(main) { model.stopFleetBroadcast() }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }

        val cards = withContext(main) { model.broadcastResults.toList() }
        assertEquals(BroadcastStatus.Failure, cards[0].status)
        assertEquals("Stopped.", cards[0].note)
        assertEquals(listOf(BroadcastStatus.NotRun, BroadcastStatus.NotRun), cards.drop(2).map { it.status })
        assertEquals("Not run: the run was stopped before this host's turn.", cards[3].note)
        assertTrue("the waiting hosts never started", "c" !in hosts.started() && "d" !in hosts.started())
    }

    private fun withHosts(
        block: suspend (AppViewModel, CoroutineDispatcher, RollingHosts, List<Int>) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val hosts = RollingHosts()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repository = AppRepository(AppDatabase.getDatabase(application))
        val ids = mutableListOf<Int>()
        var model: AppViewModel? = null
        try {
            for (name in listOf("a", "b", "c", "d")) {
                ids += repository.insertServer(
                    ServerEntity(name = "Rolling $name", host = "$name.invalid", username = "fixture", status = "online"),
                ).toInt()
            }
            model = withContext(main) { AppViewModel(application, hosts) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.count { it.id in ids } < ids.size }
            withContext(main) { model.updateBroadcastInTmux(false) }
            block(model, main, hosts, ids)
        } finally {
            hosts.release.complete(Unit)
            model?.let { withContext(main) { it.updateBroadcastBatchSize(0); it.updateBroadcastStopOnFailure(true) } }
            clearViewModelsAndAwaitTerminalJobs(store, main)
            ids.forEach { id -> repository.getServerById(id)?.let { repository.deleteServer(it) } }
            Dispatchers.resetMain()
            main.close()
        }
    }

    /**
     * Four hosts that answer [COMMAND] after a short while, so a batch's hosts overlap; hosts in
     * [failing] exit 1, hosts in [holding] wait for [release]. Records each start and end.
     */
    private class RollingHosts : SshTransport {
        val failing: MutableSet<String> = ConcurrentHashMap.newKeySet()
        val holding: MutableSet<String> = ConcurrentHashMap.newKeySet()
        val events = CopyOnWriteArrayList<String>()
        val maxRunning = AtomicInteger()
        val release = CompletableDeferred<Unit>()
        private val running = AtomicInteger()

        fun started(): List<String> = events.filter { it.startsWith("start ") }.map { it.removePrefix("start ") }

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            if (command != COMMAND) return ""
            val host = creds.host.removeSuffix(".invalid")
            events.add("start $host")
            maxRunning.accumulateAndGet(running.incrementAndGet(), ::maxOf)
            try {
                onChunk("ran on $host\n")
                if (host in holding) release.await() else delay(60)
            } finally {
                running.decrementAndGet()
                events.add("end $host")
            }
            return if (host in failing) "SSH Error: command failed (1)" else "ran on $host\n"
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
        const val COMMAND = "upgrade-step"
    }
}
