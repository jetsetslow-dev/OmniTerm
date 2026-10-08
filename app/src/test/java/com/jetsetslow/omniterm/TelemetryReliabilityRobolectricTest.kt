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
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TelemetryReliabilityRobolectricTest {
    @Test
    fun emptyMetricsCannotAdvertisePerfectHealth() = checkTelemetry(initialReply = "") { model, repo, id, _ ->
        val row = checkNotNull(repo.getServerById(id))
        assertTrue("Health must be unavailable until metrics are verified; got ${row.healthScore}", row.healthScore < 0)
        assertNull("Empty command output is not a current sample", model.hostMetricsById[id])
        assertTrue("Missing readings must not enter retained history", repo.getMetricsForServer(id).isEmpty())
    }

    @Test
    fun failedMetricsInvalidateThePreviousGreenScore() = checkTelemetry(initialReply = validMetrics) { model, repo, id, ssh ->
        assertTrue(checkNotNull(repo.getServerById(id)).healthScore >= 0)
        ssh.reply = "SSH Error: command timed out"
        withContext(Dispatchers.Main) { model.refreshServer(id) }
        withTimeout(5_000) { ssh.failedMetrics.await() }
        withTimeout(5_000) {
            while (repo.getServerById(id)?.status != "online") delay(10)
        }
        val row = checkNotNull(repo.getServerById(id))
        assertTrue("A failed refresh must invalidate current health; got ${row.healthScore}", row.healthScore < 0)
        assertNull("The previous sample cannot remain current after failure", model.hostMetricsById[id])
        assertTrue("Historical readings must still be retained", repo.getMetricsForServer(id).isNotEmpty())
    }

    private fun checkTelemetry(
        initialReply: String,
        check: suspend (AppViewModel, AppRepository, Int, MetricsTransport) -> Unit,
    ) = runBlocking {
        // Production database and probes use IO; keep these integration checks in bounded real time.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            val id = repository.insertServer(ServerEntity(
                name = "Telemetry reliability fixture", host = "telemetry-fixture.invalid", username = "fixture",
                // The fake SSH route is authoritative; this test must not open a real TCP socket.
                proxyType = "http", proxyHost = "fixture-proxy.invalid",
            )).toInt()
            val transport = MetricsTransport(initialReply)
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            withTimeout(10_000) {
                while (!model.probedServerIds.containsKey(id)) delay(10)
            }
            check(model, repository, id, transport)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private class MetricsTransport(@Volatile var reply: String) : SshTransport {
        val failedMetrics = CompletableDeferred<Unit>()
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            if (command == RemoteCommands.OS_PROBE) return "Linux"
            val result = reply
            if (result.startsWith("SSH Error")) failedMetrics.complete(Unit)
            return result
        }
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String = exec(creds, command, stdin)
        override suspend fun testConnection(creds: SshCredentials): String? = null
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession = error("No terminal is needed for telemetry")
    }

    companion object {
        private const val validMetrics = "@OS\nLinux\n@CPU\n%Cpu(s): 100.0 id\n@MEM\nMem: 1000 200 800 0 0 800\n@DISK\n/dev/sda 1000 100 900 10% /\n@DISKS\nFilesystem 1K-blocks Used Available Use% Mounted on\n/dev/sda 1000 100 900 10% /\n"
    }
}
