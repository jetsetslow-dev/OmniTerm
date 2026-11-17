package com.jetsetslow.omniterm.automation

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.UnattendedScripts
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.ui.NotificationLinks
import com.jetsetslow.omniterm.ui.commandDangerHits
import java.util.concurrent.ConcurrentHashMap

/**
 * Runbooks an alert runs on its own: a rule the user set to run its runbook when an incident opens
 * runs it on that host, once, in the background, with nobody there to confirm it, so it refuses
 * what automation refuses. Each rule and host runs at most once every [COOLDOWN_MS], so a service
 * that keeps falling over is not restarted in a loop. The run is in Fleet's history, and the
 * incident links to it.
 *
 * Idea credit: Termix's Automations (alert-triggered runs).
 */
object AlertRunbooks {
    // Automation 0x4F4D_xxxx, schedules 0x4F4E_xxxx and 0x4F4F_xxxx; a rule and host here.
    private const val JOB_ID_BASE = 0x4F_50_00_00
    internal const val KEY_RULE = "rule"
    internal const val KEY_SERVER = "server"
    const val COOLDOWN_MS = 30 * 60_000L

    private val lastStarted = ConcurrentHashMap<Pair<Int, Int>, Long>()

    internal fun jobId(ruleId: Int, serverId: Int) = JOB_ID_BASE + (Math.floorMod(31 * ruleId + serverId, 0x10000))

    /**
     * Starts [ruleId]'s runbook on [serverId] as soon as Android allows, unless it started there in
     * the last [COOLDOWN_MS]. False when it did not start.
     */
    fun start(context: Context, ruleId: Int, serverId: Int, now: Long = System.currentTimeMillis()): Boolean {
        val key = ruleId to serverId
        val last = lastStarted[key]
        if (last != null && now - last < COOLDOWN_MS) return false
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        fun builder() = JobInfo.Builder(jobId(ruleId, serverId), ComponentName(context, AlertRunbookJobService::class.java))
            .setExtras(PersistableBundle().apply { putInt(KEY_RULE, ruleId); putInt(KEY_SERVER, serverId) })
        val started = runCatching {
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && scheduler.schedule(builder().setExpedited(true).build()) == JobScheduler.RESULT_SUCCESS) ||
                scheduler.schedule(builder().setOverrideDeadline(0).build()) == JobScheduler.RESULT_SUCCESS
        }.getOrDefault(false)
        if (started) lastStarted[key] = now
        return started
    }

    /** Forgets when runbooks last started, for tests. */
    internal fun resetCooldowns() = lastStarted.clear()
}

/** Runs one rule's runbook on one host for the incident that is open there. */
class AlertRunbookRunner(
    context: Context,
    private val repository: AppRepository,
    private val transport: SshTransport,
    private val clock: () -> Long = System::currentTimeMillis,
    private val runTimeoutMs: Long = Automation.RUN_TIMEOUT_MS,
) {
    private val context = context.applicationContext

    /**
     * Runs [ruleId]'s runbook on [serverId]; null when there is nothing to do: the rule no longer
     * runs it on its own, the incident has closed, or the rule or host is gone.
     */
    suspend fun run(ruleId: Int, serverId: Int): Automation.RunResult? {
        val rule = repository.getAllRules().find { it.id == ruleId }?.takeIf { it.enabled && it.runbookAuto } ?: return null
        val alert = repository.getActiveAlerts().find { it.ruleId == ruleId && it.serverId == serverId } ?: return null
        val server = repository.getServerById(serverId) ?: return null
        val script = rule.runbookScriptId?.let { id -> repository.getAllScripts().find { it.id == id } }
        val by = context.getString(R.string.alert_runbook_by, rule.metricName, server.name)
        val runKey = "alert-" + java.util.UUID.randomUUID()
        UnattendedScripts.problem(script, script?.let { commandDangerHits(it.command) }.orEmpty(), UnattendedScripts.Runner.ALERT)?.let { reason ->
            val result = Automation.RunResult(emptyList(), reason)
            // Nothing ran, so there is nothing in the history: the alerts are where to look.
            RunNotifications(
                context, runKey, script?.name ?: rule.metricName, by, RunNotify.of(rule.runbookNotify),
                channel = RunNotifications.Channel.ALERT_RUNS, link = NotificationLinks.alerts(),
            ).finished(result)
            return result
        }
        repository.setAlertRunbookRunKey(alert.id, runKey)
        return AutomationRunner(context, repository, transport, clock, runTimeoutMs).runScript(
            script!!, listOf(server), emptyMap(), FleetRunHistory.SOURCE_ALERT, RunNotify.of(rule.runbookNotify), by, runKey,
            channel = RunNotifications.Channel.ALERT_RUNS,
        )
    }
}

/** Runs an alert's runbook job. */
class AlertRunbookJobService : RunJobService() {
    override fun workFor(params: JobParameters): (suspend () -> Unit)? {
        val ruleId = params.extras.getInt(AlertRunbooks.KEY_RULE, 0).takeIf { it > 0 } ?: return null
        val serverId = params.extras.getInt(AlertRunbooks.KEY_SERVER, 0).takeIf { it > 0 } ?: return null
        return {
            val transport = JschSshTransport()
            try {
                AlertRunbookRunner(applicationContext, AutomationJobs.repository(applicationContext), transport).run(ruleId, serverId)
            } finally {
                transport.shutdown()
            }
        }
    }
}
