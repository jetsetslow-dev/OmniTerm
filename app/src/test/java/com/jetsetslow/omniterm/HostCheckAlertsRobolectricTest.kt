package com.jetsetslow.omniterm

import android.app.Application
import android.net.ConnectivityManager
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentLinkedQueue
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

    /**
     * A failing Script Check opens an incident with the script's exit status and the line it printed,
     * and the metrics polls that follow leave it open. The script runs once a minute; the probe,
     * which no rule needs, never runs.
     */
    @Test
    fun aFailingScriptCheckOpensAnIncidentThatMetricsPollsLeaveOpen() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            val scriptId = saveScript(repository, "Backups fresh", "check-backups --max-age {{age=1d}}")
            withContext(main) {
                model.addAlertRule(hostId, HostChecks.SCRIPT_CHECK, "/", 0f, "WARNING", "0m", target = scriptId.toString())
            }
            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(200)
                }
                repository.getActiveAlerts().single()
            }
            assertEquals(HostChecks.SCRIPT_CHECK, alert.metricName)
            assertEquals(2f, alert.currentValue)
            val ruleId = repository.getAllRules().single().id
            assertEquals("exit 2: nas is 3 days old", model.hostCheckResults.getValue(ruleId to hostId).summary)
            assertTrue("the placeholder took its default", host.commands.any { "check-backups --max-age 1d" in it })

            val polled = host.metricsRuns.get()
            withTimeout(15_000) {
                while (host.metricsRuns.get() < polled + 6) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(100)
                }
            }
            assertEquals(1, repository.getActiveAlerts().size)
            assertEquals("the script ran once: it is due once a minute", 1, host.scriptRuns.get())
            assertEquals(0, host.probeRuns.get())
        }
    }

    /** A check runs without anyone confirming it, so a script that looks destructive never runs as one. */
    @Test
    fun aDestructiveScriptNeverRunsAsACheck() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            val scriptId = saveScript(repository, "Prune", "rm -rf /srv/backup/old")
            withContext(main) {
                model.addAlertRule(hostId, HostChecks.SCRIPT_CHECK, "/", 0f, "WARNING", "0m", target = scriptId.toString())
            }
            val ruleId = withTimeout(5_000) {
                while (repository.getAllRules().isEmpty()) delay(20)
                repository.getAllRules().single().id
            }
            withTimeout(15_000) {
                while (host.metricsRuns.get() < 2) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(200)
                }
            }
            waitWhileOnMain(main, 15_000) { model.hostCheckResults[ruleId to hostId] == null }
            val result = model.hostCheckResults.getValue(ruleId to hostId)
            assertNull(result.value)
            assertTrue(result.summary, result.summary.startsWith("Not checked: A check runs every minute without asking"))
            assertTrue(host.commands.none { "rm -rf" in it })
            assertTrue(repository.getActiveAlerts().isEmpty())
        }
    }

    /**
     * An alert's runbook fills in Broadcast with that script and that host, and waits for the Run
     * confirmation Fleet shows: nothing reaches the host before it.
     */
    @Test
    fun anAlertsRunbookWaitsInFleetForConfirmation() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            val runbookId = saveScript(repository, "Restart backups", "systemctl restart backup.service")
            withContext(main) {
                model.addAlertRule(hostId, HostChecks.FAILED_SERVICES, "/", 0f, "WARNING", "0m", runbookScriptId = runbookId)
            }
            val rule = withTimeout(5_000) {
                while (repository.getAllRules().isEmpty()) delay(20)
                repository.getAllRules().single()
            }
            assertEquals(runbookId, rule.runbookScriptId)
            withContext(main) { model.openRunbook(rule.id, hostId) }
            waitWhileOnMain(main) { !model.pendingRunbookConfirm }
            withContext(main) {
                assertEquals(Screen.Fleet, model.currentScreen)
                assertEquals(1, model.fleetTabIndex)
                assertEquals(FleetTargetMode.Servers, model.broadcastTargetMode)
                assertEquals(listOf(hostId), model.broadcastTargetServerIds.toList())
                assertEquals("systemctl restart backup.service", model.broadcastCommandText)
                assertEquals(runbookId, model.broadcastPreset?.id)
            }
            assertTrue(host.commands.none { "backup.service" in it })

            // Deleting the script takes it off the rule.
            repository.deleteScript(repository.getAllScripts().single { it.id == runbookId })
            assertNull(repository.getAllRules().single().runbookScriptId)
        }
    }

    private suspend fun saveScript(repository: AppRepository, name: String, command: String): Int {
        repository.insertScript(QuickScriptEntity(emoji = "LIN", name = name, command = command, color = "cyan"))
        return repository.getAllScripts().single { it.name == name }.id
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

    /**
     * A Linux host with healthy metrics, two failed systemd units and a backup check that fails with
     * exit 2. It keeps every command it was sent.
     */
    private class AnsweringHost : FakeTransport() {
        val probeRuns = AtomicInteger()
        val metricsRuns = AtomicInteger()
        val scriptRuns = AtomicInteger()
        val commands = ConcurrentLinkedQueue<String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(command)
            return when {
                "check-backups" in command -> {
                    scriptRuns.incrementAndGet()
                    "SSH Error: command failed (2): nas is 3 days old"
                }
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
}
