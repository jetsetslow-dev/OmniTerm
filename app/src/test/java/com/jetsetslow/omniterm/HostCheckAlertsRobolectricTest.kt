package com.jetsetslow.omniterm

import android.app.Application
import android.net.ConnectivityManager
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Host checks open incidents from what the host says, and only from that. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class HostCheckAlertsRobolectricTest {

    @Test
    fun anUnreachableHostOpensAHostOfflineIncident() = withModel(Unreachable()) { repository, model, hostId ->
        withContext(main) { model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m") }
        val alert = withTimeout(15_000) {
            while (repository.getActiveAlerts().isEmpty()) {
                withContext(main) { model.refreshServer(hostId) }
                delay(200)
            }
            repository.getActiveAlerts().single()
        }
        assertEquals(hostId, alert.serverId)
        assertEquals(HostChecks.HOST_OFFLINE, alert.metricName)
        assertEquals(1f, alert.currentValue)
        val ruleId = repository.getAllRules().single().id
        assertEquals("offline", model.hostCheckResults.getValue(ruleId to hostId).summary)
    }

    /** With the phone itself off the network every host looks down, which says nothing about them. */
    @Test
    fun noHostOfflineIncidentWhileThePhoneHasNoNetwork() = withModel(Unreachable()) { repository, model, hostId ->
        val application = ApplicationProvider.getApplicationContext<Application>()
        val connectivity = shadowOf(application.getSystemService(ConnectivityManager::class.java))
        connectivity.setDefaultNetworkActive(false)
        connectivity.setActiveNetworkInfo(null)
        withContext(main) { model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m") }
        withTimeout(15_000) {
            while (repository.getServerById(hostId)?.status != "offline") delay(50)
        }
        repeat(5) {
            withContext(main) { model.refreshServer(hostId) }
            delay(300)
        }
        assertTrue(repository.getActiveAlerts().isEmpty())
    }

    /**
     * A failed unit opens an incident naming it, and the metrics polls that follow leave it open:
     * they carry no reading for a host check, which must not count as "recovered".
     */
    @Test
    fun aFailedServiceOpensAnIncidentThatMetricsPollsLeaveOpen() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            withContext(main) { model.addAlertRule(hostId, HostChecks.FAILED_SERVICES, "/", 0f, "WARNING", "0m") }
            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(200)
                }
                repository.getActiveAlerts().single()
            }
            assertEquals(HostChecks.FAILED_SERVICES, alert.metricName)
            assertEquals(2f, alert.currentValue)
            val ruleId = repository.getAllRules().single().id
            assertEquals(
                "2 failed services: nginx.service, smartd.service",
                model.hostCheckResults.getValue(ruleId to hostId).summary,
            )

            val polled = host.metricsRuns.get()
            withTimeout(15_000) {
                while (host.metricsRuns.get() < polled + 6) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(100)
                }
            }
            assertEquals(1, repository.getActiveAlerts().size)
            assertEquals("the probe ran once: it is due once a minute", 1, host.probeRuns.get())
        }
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private fun withModel(transport: SshTransport, body: suspend (AppRepository, AppViewModel, Int) -> Unit) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            // .invalid never resolves, so the direct port probe fails and the SSH route is tried.
            val hostId = repository.insertServer(ServerEntity(name = "Lab", host = "lab.invalid", username = "fixture")).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            body(repository, model, hostId)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private abstract class FakeTransport : SshTransport {
        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = exec(creds, command, stdin)

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = error("No shell is opened in these tests")
    }

    /** Every command fails as an unreachable server does. */
    private class Unreachable : FakeTransport() {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = "SSH Error: connect timed out"
        override suspend fun testConnection(creds: SshCredentials): String? = "connect timed out"
    }

    /** A Linux host with healthy metrics and two failed systemd units. */
    private class AnsweringHost : FakeTransport() {
        val probeRuns = AtomicInteger()
        val metricsRuns = AtomicInteger()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = when {
            "echo '@FAILED'" in command -> {
                probeRuns.incrementAndGet()
                "@FAILED\n!OK\nnginx.service\nsmartd.service\n@CONTAINERS\n@ZFS\n@MDSTAT\n@UPS\n@REBOOT\n"
            }
            "echo '@MEM'" in command -> {
                metricsRuns.incrementAndGet()
                "@OS\nLinux\n@CPU\n100.0 id\n@MEM\nMem: 100 20 0 0 0 80\n@DISK\n/dev/root 100 10 90 10% /\n"
            }
            else -> "Linux\n/bin/bash\n"
        }
    }
}
