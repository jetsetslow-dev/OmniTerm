package com.jetsetslow.omniterm

import android.app.Application
import android.app.job.JobScheduler
import android.net.ConnectivityManager
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.automation.AlertRunbooks
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.BackupChecks
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Host checks open incidents from what the host says, and only from that. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class HostCheckAlertsRobolectricTest {
    // A Backup Age rule's password is encrypted with the phone's key store.
    @get:Rule val keyStore = TestAndroidKeyStore()

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

    /** A rule set to run its runbook starts it on the host when the incident opens; one that only offers it does not. */
    @Test
    fun anIncidentStartsTheRunbookOnlyForARuleSetToRunIt() {
        for (auto in listOf(true, false)) {
            withModel(Unreachable()) { repository, model, hostId ->
                AlertRunbooks.resetCooldowns()
                val scheduler = ApplicationProvider.getApplicationContext<Application>().getSystemService(JobScheduler::class.java)
                scheduler.cancelAll()
                val runbook = saveScript(repository, "Wake it", "systemctl restart networking")
                withContext(main) {
                    model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m", runbookScriptId = runbook, runbookAuto = auto)
                }
                withTimeout(15_000) {
                    while (repository.getActiveAlerts().isEmpty()) {
                        withContext(main) { model.refreshServer(hostId) }
                        delay(200)
                    }
                }
                val ruleId = repository.getAllRules().single().id
                assertEquals("auto=$auto", auto, scheduler.getPendingJob(AlertRunbooks.jobId(ruleId, hostId)) != null)
                scheduler.cancelAll()
            }
        }
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

    /**
     * A host check added while the host's probe runs is read by a probe right after that one, not
     * at the next poll: the running probe was sent before the rule existed.
     */
    @Test
    fun aHostCheckAddedDuringAProbeIsReadRightAfterIt() {
        val answer = CountDownLatch(1)
        val host = AnsweringHost(probeGate = answer)
        withModel(host) { repository, model, hostId ->
            try {
                withContext(main) { model.addAlertRule(hostId, HostChecks.FAILED_SERVICES, "/", 0f, "WARNING", "0m") }
                withTimeout(15_000) {
                    while (host.probeStarted.count > 0) {
                        withContext(main) { model.refreshServer(hostId) }
                        delay(200)
                    }
                }
                withContext(main) { model.addAlertRule(hostId, HostChecks.REBOOT_REQUIRED, "/", 0f, "WARNING", "0m") }
                val rebootRule = withTimeout(5_000) {
                    while (repository.getAllRules().size < 2) delay(10)
                    repository.getAllRules().single { it.metricName == HostChecks.REBOOT_REQUIRED }.id
                }
                // Let the new rule's own start request land while the first probe still runs.
                delay(500)
                answer.countDown()

                // No refresh: the next poll is 15 s away, so only the queued probe can read it now.
                waitWhileOnMain(main, timeoutMillis = 5_000) { model.hostCheckResults[rebootRule to hostId] == null }
                assertEquals(2, host.probeRuns.get())
            } finally {
                answer.countDown()
            }
        }
    }

    /**
     * A Backup Age rule reads its repository with the password on the command's input, opens an
     * incident for a backup older than its limit, and reads the repository once in 15 minutes
     * however often the host is polled. The password is kept only encrypted.
     */
    @Test
    fun anOldBackupOpensAnIncidentAndThePasswordTravelsOnlyOnInput() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            val target = BackupChecks.encode(BackupChecks.Target(BackupChecks.Tool.RESTIC, "/srv/restic"))
            withContext(main) {
                model.addAlertRule(hostId, HostChecks.BACKUP_AGE, "/", 26f, "WARNING", "0m", target = target, secret = BACKUP_PASSWORD)
            }
            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(200)
                }
                repository.getActiveAlerts().single()
            }
            assertEquals(HostChecks.BACKUP_AGE, alert.metricName)
            assertTrue("the fixture snapshot is from 2026-01-01", alert.currentValue > 26f)
            val ruleId = repository.getAllRules().single().id
            assertTrue(model.hostCheckResults.getValue(ruleId to hostId).summary.endsWith("old (snapshot 718e5335)"))
            assertEquals(listOf("$BACKUP_PASSWORD\n"), host.backupInputs.toList())
            assertTrue("never in a command", host.commands.none { BACKUP_PASSWORD in it })
            val stored = withContext(Dispatchers.IO) { AppDatabase.getDatabase(ApplicationProvider.getApplicationContext()).alertRuleDao().getAllRules() }.single()
            assertTrue("stored encrypted", stored.secret.startsWith("enc:v1:") && BACKUP_PASSWORD !in stored.secret)
            assertEquals("and read back as typed", BACKUP_PASSWORD, repository.getAllRules().single().secret)

            val polled = host.metricsRuns.get()
            withTimeout(15_000) {
                while (host.metricsRuns.get() < polled + 6) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(100)
                }
            }
            assertEquals("the repository is read once in 15 minutes", 1, host.backupInputs.size)
            assertEquals(1, repository.getActiveAlerts().size)
        }
    }

    /**
     * An Image Updates rule counts the images whose registry digest the host never pulled, and the
     * registries are asked once however often the host is polled; Containers → Images then shows
     * that same check, and its button asks again only after 10 minutes.
     */
    @Test
    fun anImageWithANewerBuildOpensAnIncidentAndRegistriesAreAskedOnce() {
        val host = AnsweringHost()
        withModel(host) { repository, model, hostId ->
            withContext(main) { model.addAlertRule(hostId, HostChecks.IMAGE_UPDATES, "/", 0f, "WARNING", "0m") }
            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(200)
                }
                repository.getActiveAlerts().single()
            }
            assertEquals(HostChecks.IMAGE_UPDATES, alert.metricName)
            assertEquals(1f, alert.currentValue)
            val ruleId = repository.getAllRules().single().id
            assertEquals("1 image with an update: registry:5000/team/app:latest", model.hostCheckResults.getValue(ruleId to hostId).summary)
            val polled = host.metricsRuns.get()
            withTimeout(15_000) {
                while (host.metricsRuns.get() < polled + 6) {
                    withContext(main) { model.refreshServer(hostId) }
                    delay(100)
                }
            }
            assertEquals("the registries were asked once", 1, host.registryChecks.get())
            withContext(main) {
                model.selectedServerId = hostId
                assertEquals(1, model.imageUpdateReports.getValue(hostId).updates.size)
                model.checkImageUpdates()
            }
            delay(500)
            assertEquals("a check minutes old is not repeated", 1, host.registryChecks.get())
        }
    }

    /**
     * A Backup Age rule comes back from a backup with its repository and password, switched off:
     * it runs a command on the host by itself, so it waits until it is turned on again. So does an
     * Image Updates rule, whose host asks registries on the internet.
     */
    @Test
    fun aRestoredBackupCheckKeepsItsPasswordAndComesBackOff() = withModel(Unreachable()) { repository, model, _ ->
        val application = ApplicationProvider.getApplicationContext<Application>()
        val target = BackupChecks.encode(BackupChecks.Target(BackupChecks.Tool.BORG, "/srv/borg", "nas-*"))
        withContext(main) {
            model.addAlertRule(0, HostChecks.BACKUP_AGE, "/", 30f, "WARNING", "0m", target = target, secret = BACKUP_PASSWORD)
            model.addAlertRule(0, HostChecks.FAILED_SERVICES, "/", 0f, "WARNING", "0m")
            model.addAlertRule(0, HostChecks.IMAGE_UPDATES, "/", 0f, "WARNING", "0m")
        }
        withTimeout(5_000) { while (repository.getAllRules().size < 3) delay(20) }
        val selection = BackupSelection.NONE.copy(alertRules = true)
        val uri = android.net.Uri.parse("content://backup-fixture/backup-age.json")
        val bytes = java.io.ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val exported = kotlinx.coroutines.CompletableDeferred<Boolean>()
        withContext(main) { model.exportBackup(uri, "backup-age-passphrase", application, selection) { ok, _ -> exported.complete(ok) } }
        assertTrue(withTimeout(10_000) { exported.await() })
        waitWhileOnMain(main) { model.backupExportRunning }
        val backup = bytes.toString(Charsets.UTF_8)
        assertFalse("the backup file is encrypted", BACKUP_PASSWORD in backup)

        withContext(Dispatchers.IO) { AppDatabase.getDatabase(application).alertRuleDao().getAllRules().forEach { repository.deleteRule(it) } }
        val restored = kotlinx.coroutines.CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, "backup-age-passphrase", selection) { ok, message -> restored.complete(ok to message) } }
        val (ok, message) = withTimeout(10_000) { restored.await() }
        assertTrue(message, ok)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        val rules = repository.getAllRules()
        val backupRule = rules.single { it.metricName == HostChecks.BACKUP_AGE }
        assertEquals(target, backupRule.target)
        assertEquals(BACKUP_PASSWORD, backupRule.secret)
        assertFalse("restored switched off", backupRule.enabled)
        assertFalse("an image check too", rules.single { it.metricName == HostChecks.IMAGE_UPDATES }.enabled)
        assertTrue("other rules keep their state", rules.single { it.metricName == HostChecks.FAILED_SERVICES }.enabled)
    }

    private suspend fun saveScript(repository: AppRepository, name: String, command: String): Int {
        repository.insertScript(QuickScriptEntity(emoji = "LIN", name = name, command = command, color = "cyan"))
        return repository.getAllScripts().single { it.name == name }.id
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private companion object {
        const val BACKUP_PASSWORD = "correct horse battery"
    }

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
     * exit 2. It keeps every command it was sent. Given [probeGate], the host-check probe answers
     * only once the gate opens.
     */
    private class AnsweringHost(private val probeGate: CountDownLatch? = null) : FakeTransport() {
        val probeRuns = AtomicInteger()
        val probeStarted = CountDownLatch(1)
        val metricsRuns = AtomicInteger()
        val scriptRuns = AtomicInteger()
        val commands = ConcurrentLinkedQueue<String>()
        val backupInputs = ConcurrentLinkedQueue<String>()
        val registryChecks = AtomicInteger()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(command)
            return when {
                "!RUNTIME" in command -> "!RUNTIME docker\n" +
                    "docker\tregistry:5000/team/app:latest\t[\"registry:5000/team/app@sha256:old\"]\n" +
                    "docker\tnginx:1.27\t[\"nginx@sha256:aaa\"]\n"
                "ck(){" in command -> {
                    registryChecks.incrementAndGet()
                    "!OK\tregistry:5000/team/app:latest\tsha256:new\n!OK\tdocker.io/library/nginx:1.27\tsha256:aaa\n"
                }
                "echo '@BACKUP'" in command -> {
                    backupInputs.add(stdin.orEmpty())
                    if (stdin == "$BACKUP_PASSWORD\n") {
                        "@BACKUP\n[{\"time\":\"2026-01-01T00:00:00Z\",\"short_id\":\"718e5335\"}]\n\n!RC 0\n@ERR\n"
                    } else {
                        "@BACKUP\n\n!RC 12\n@ERR\n{\"message_type\":\"exit_error\",\"code\":12,\"message\":\"Fatal: wrong password or no key found\"}\n"
                    }
                }
                "check-backups" in command -> {
                    scriptRuns.incrementAndGet()
                    "SSH Error: command failed (2): nas is 3 days old"
                }
                "echo '@FAILED'" in command -> {
                    probeRuns.incrementAndGet()
                    probeStarted.countDown()
                    probeGate?.await(10, TimeUnit.SECONDS)
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
