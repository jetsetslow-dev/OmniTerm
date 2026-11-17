package com.jetsetslow.omniterm

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.job.JobScheduler
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.automation.AlertRunbookRunner
import com.jetsetslow.omniterm.automation.AlertRunbooks
import com.jetsetslow.omniterm.automation.RunNotifications
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A runbook an alert runs on its own: only for a rule set to, only while its incident is open, on
 * that one host, refusing what automation refuses, at most once every 30 minutes per rule and host.
 * The run is in Fleet's history and the incident links to it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AlertRunbookRobolectricTest {
    private val application: Application get() = ApplicationProvider.getApplicationContext()
    private lateinit var repository: AppRepository

    @Test
    fun itRunsOnTheIncidentsHostAndTheIncidentLinksTheRun() = withLab { hosts ->
        val rule = rule(script("systemctl restart nginx"))
        val alert = incident(rule)

        val result = AlertRunbookRunner(application, repository, hosts).run(rule, nasId)!!

        assertTrue(result.succeeded)
        assertEquals("only the incident's host", listOf("nas"), result.hosts.map { it.name })
        assertTrue(hosts.commands.none { it.first.host == PI })
        val run = repository.fleetRunsFlow.first().single()
        assertEquals(FleetRunHistory.SOURCE_ALERT, run.run.source)
        assertEquals(BroadcastStatus.Success.name, repository.fleetRunHosts(run.run.id).single().status)
        assertEquals("the incident opens its run", run.run.runKey, repository.getActiveAlerts().single { it.id == alert }.runbookRunKey)
        val notice = shadowOf(application.getSystemService(NotificationManager::class.java)).getNotification(RunNotifications.idFor(run.run.runKey))
        assertEquals(RunNotifications.Channel.ALERT_RUNS.id, notice.channelId)
        assertEquals("Alert “${HostChecks.FAILED_SERVICES}” on nas ran $SCRIPT_NAME", notice.extras.getString(Notification.EXTRA_TITLE))
    }

    @Test
    fun nothingRunsOnceTheIncidentClosedOrTheRuleNoLongerRunsIt() = withLab { hosts ->
        val script = script("systemctl restart nginx")
        val closed = rule(script)
        assertNull("no open incident", AlertRunbookRunner(application, repository, hosts).run(closed, nasId))
        val offers = rule(script, auto = false)
        incident(offers)
        assertNull("the rule only offers its runbook", AlertRunbookRunner(application, repository, hosts).run(offers, nasId))
        val off = rule(script, enabled = false)
        incident(off)
        assertNull("the rule is off", AlertRunbookRunner(application, repository, hosts).run(off, nasId))
        assertTrue(hosts.commands.isEmpty())
        assertTrue(repository.fleetRunsFlow.first().isEmpty())
    }

    @Test
    fun itRefusesWhatAutomationRefusesAndSaysSo() = withLab { hosts ->
        val rule = rule(script("rm -rf /var/log/nginx"))
        incident(rule)
        val result = AlertRunbookRunner(application, repository, hosts).run(rule, nasId)!!
        assertTrue(result.error!!, result.error!!.startsWith("An alert runs it without asking, so it must only read"))
        assertTrue(hosts.commands.isEmpty())
        assertTrue(repository.fleetRunsFlow.first().isEmpty())
        assertNull(repository.getActiveAlerts().single().runbookRunKey)
        val shown = shadowOf(application.getSystemService(NotificationManager::class.java)).allNotifications
            .single { it.extras.getString(Notification.EXTRA_TITLE) == "Alert “${HostChecks.FAILED_SERVICES}” on nas could not run $SCRIPT_NAME" }
        assertEquals("omniterm://notification/alerts", shadowOf(shown.contentIntent).savedIntent.dataString)
    }

    @Test
    fun aRuleAndHostStartAtMostOnceEveryThirtyMinutes() = withLab { _ ->
        val scheduler = application.getSystemService(JobScheduler::class.java)
        val now = 1_800_000_000_000L
        assertTrue(AlertRunbooks.start(application, 7, nasId, now))
        val job = scheduler.getPendingJob(AlertRunbooks.jobId(7, nasId))!!
        assertEquals(7, job.extras.getInt("rule"))
        assertEquals(nasId, job.extras.getInt("server"))
        assertFalse("a second incident soon after starts nothing", AlertRunbooks.start(application, 7, nasId, now + 29 * 60_000L))
        assertTrue("another host is its own", AlertRunbooks.start(application, 7, nasId + 1, now + 60_000L))
        assertTrue("after half an hour it may run again", AlertRunbooks.start(application, 7, nasId, now + 31 * 60_000L))
    }

    private suspend fun script(command: String): QuickScriptEntity {
        repository.insertScript(QuickScriptEntity(emoji = "", name = SCRIPT_NAME, command = command, color = "cyan"))
        return repository.getAllScripts().last { it.name == SCRIPT_NAME }
    }

    private suspend fun rule(script: QuickScriptEntity, auto: Boolean = true, enabled: Boolean = true): Int {
        repository.insertRule(
            AlertRuleEntity(
                serverId = 0, metricName = HostChecks.FAILED_SERVICES, thresholdValue = 0f, severity = "WARNING",
                triggerWindow = "0m", enabled = enabled, notes = "rule ${repository.getAllRules().size}",
                runbookScriptId = script.id, runbookAuto = auto, runbookNotify = RunNotify.ALWAYS,
            ),
        )
        return repository.getAllRules().maxOf { it.id }
    }

    private suspend fun incident(ruleId: Int): Int {
        repository.insertAlert(
            ActiveAlertEntity(
                ruleId = ruleId, serverId = nasId, metricName = HostChecks.FAILED_SERVICES,
                currentValue = 1f, thresholdValue = 0f, severity = "WARNING", triggeredTime = 1L,
            ),
        )
        return repository.getActiveAlerts().single { it.ruleId == ruleId }.id
    }

    private var nasId = 0

    private fun withLab(block: suspend (FakeHosts) -> Unit) = runBlocking {
        val db = AppDatabase.getDatabase(application)
        withContext(Dispatchers.IO) { db.clearAllTables() }
        repository = AppRepository(db)
        AlertRunbooks.resetCooldowns()
        nasId = repository.insertServer(ServerEntity(name = "nas", host = NAS, username = "fixture")).toInt()
        repository.insertServer(ServerEntity(name = "pi", host = PI, username = "fixture"))
        try {
            block(FakeHosts())
        } finally {
            application.getSystemService(JobScheduler::class.java).cancelAll()
            AlertRunbooks.resetCooldowns()
            withContext(Dispatchers.IO) { db.clearAllTables() }
        }
    }

    private class FakeHosts : SshTransport {
        val commands = CopyOnWriteArrayList<Pair<SshCredentials, String>>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(creds to command)
            return if (command == RemoteCommands.OS_PROBE) "Linux\n/bin/bash" else ""
        }

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String =
            error("a runbook reads whole results")

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("a runbook opens no shell")
    }

    private companion object {
        const val NAS = "10.0.0.10"
        const val PI = "10.0.0.11"
        const val SCRIPT_NAME = "runbook fixture"
    }
}
