package com.jetsetslow.omniterm.automation

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.os.PersistableBundle
import android.util.Log
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.UnattendedScripts
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.ui.FleetTargets
import com.jetsetslow.omniterm.ui.NotificationLinks
import com.jetsetslow.omniterm.ui.commandDangerHits
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * Fleet's schedules: a saved script run on its targets at set times. Each schedule waits as one
 * JobScheduler job that survives a restart; when it has run, the next is counted from when it
 * started, so a phone asleep through several due times runs once, late, and does not catch up.
 * Android decides the exact moment, so a run may start some minutes after its time.
 *
 * Idea credit: Termix's Automations (scheduled runs across hosts).
 */
object FleetSchedules {
    // Automation's jobs use 0x4F4D_xxxx. A schedule's timer and its Run now are kept apart, so a
    // Run now never replaces the timer, and neither collides with automation's.
    private const val TIMER_BASE = 0x4F_4E_00_00
    private const val NOW_BASE = 0x4F_4F_00_00
    private const val ID_MASK = 0xFFFF
    internal const val KEY_SCHEDULE = "schedule"
    internal const val KEY_NOW = "now"

    private val running = ConcurrentHashMap.newKeySet<Int>()

    // What changes the jobs takes turns: the app start's [reconcile] reads the schedules, then drops
    // the jobs it did not see, so a schedule saved or switched on in between lost its job.
    private val jobs = Mutex()

    internal fun timerJobId(scheduleId: Int) = TIMER_BASE + (scheduleId and ID_MASK)
    internal fun nowJobId(scheduleId: Int) = NOW_BASE + (scheduleId and ID_MASK)

    /** Whether [scheduleId] is running in this process right now. */
    fun isRunning(scheduleId: Int): Boolean = scheduleId in running

    /** Marks [scheduleId] as running; false when it already is, so one schedule never overlaps itself. */
    internal fun claim(scheduleId: Int): Boolean = running.add(scheduleId)

    internal fun release(scheduleId: Int) {
        running.remove(scheduleId)
    }

    private fun scheduler(context: Context) = context.getSystemService(JobScheduler::class.java)

    /** Waits for [scheduleId]'s run at [at] (now, if that has passed), with a network, across restarts. */
    internal fun arm(context: Context, scheduleId: Int, at: Long, now: Long): Boolean {
        val scheduler = scheduler(context) ?: return false
        val info = JobInfo.Builder(timerJobId(scheduleId), ComponentName(context, FleetScheduleJobService::class.java))
            .setExtras(PersistableBundle().apply { putInt(KEY_SCHEDULE, scheduleId) })
            .setMinimumLatency((at - now).coerceAtLeast(0))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .build()
        return runCatching { scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS }
            .onFailure { Log.w(TAG, "Android refused the schedule's job", it) }
            .getOrDefault(false)
    }

    /** Runs [scheduleId] once, as soon as Android allows, leaving its timer as it is. */
    fun runNow(context: Context, scheduleId: Int): Boolean {
        val scheduler = scheduler(context) ?: return false
        val info = JobInfo.Builder(nowJobId(scheduleId), ComponentName(context, FleetScheduleJobService::class.java))
            .setExtras(PersistableBundle().apply { putInt(KEY_SCHEDULE, scheduleId); putBoolean(KEY_NOW, true) })
            .setOverrideDeadline(0)
            .build()
        return runCatching { scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS }.getOrDefault(false)
    }

    /** Stops waiting for [scheduleId], and stops a run of it in progress. */
    fun cancel(context: Context, scheduleId: Int) {
        val scheduler = scheduler(context) ?: return
        runCatching { scheduler.cancel(timerJobId(scheduleId)) }
        runCatching { scheduler.cancel(nowJobId(scheduleId)) }
    }

    /**
     * After [scheduleId] was saved, switched on or off: its next run counted from [now] when it
     * is on, nothing when off. A run in progress finishes, and sets its own next run when it does.
     */
    suspend fun apply(context: Context, repository: AppRepository, scheduleId: Int, now: Long = System.currentTimeMillis()): Unit = jobs.withLock {
        val schedule = repository.fleetSchedule(scheduleId)
        if (schedule == null) {
            cancel(context, scheduleId)
            return
        }
        val next = if (schedule.enabled) FleetScheduleTiming.nextRun(schedule, now) else null
        repository.setFleetScheduleNextRun(scheduleId, next)
        if (isRunning(scheduleId)) return
        if (next == null) runCatching { scheduler(context)?.cancel(timerJobId(scheduleId)) } else arm(context, scheduleId, next, now)
    }

    /**
     * After a run that started at [startedAt]: the next one, counted from then, or from [now] when
     * the run took longer than the gap between runs.
     */
    internal suspend fun armNext(context: Context, repository: AppRepository, scheduleId: Int, startedAt: Long, now: Long): Unit = jobs.withLock {
        val schedule = repository.fleetSchedule(scheduleId) ?: return
        if (!schedule.enabled) {
            repository.setFleetScheduleNextRun(scheduleId, null)
            runCatching { scheduler(context)?.cancel(timerJobId(scheduleId)) }
            return
        }
        val next = FleetScheduleTiming.nextRun(schedule, startedAt).let { if (it <= now) FleetScheduleTiming.nextRun(schedule, now) else it }
        repository.setFleetScheduleNextRun(scheduleId, next)
        arm(context, scheduleId, next, now)
    }

    /**
     * Matches the jobs Android holds to the saved schedules, when the app starts and after a
     * restore: a schedule that is on and has no job gets one (at once, if its time went by while
     * it had none), and a job whose schedule is off or gone is dropped. [schedulesOf] is the
     * tests' way in between reading the schedules and matching the jobs.
     */
    suspend fun reconcile(
        context: Context,
        repository: AppRepository,
        now: Long = System.currentTimeMillis(),
        schedulesOf: suspend () -> List<FleetScheduleEntity> = { repository.fleetSchedules() },
    ): Unit = jobs.withLock {
        val scheduler = scheduler(context) ?: return
        val schedules = schedulesOf()
        val wanted = schedules.filter { it.enabled }.mapTo(mutableSetOf()) { timerJobId(it.id) }
        runCatching { scheduler.allPendingJobs }.getOrDefault(emptyList())
            .filter { it.id and ID_MASK.inv() == TIMER_BASE && it.id !in wanted }
            .forEach { job -> runCatching { scheduler.cancel(job.id) } }
        for (schedule in schedules) {
            if (!schedule.enabled) {
                if (schedule.nextRunAt != null) repository.setFleetScheduleNextRun(schedule.id, null)
                continue
            }
            if (isRunning(schedule.id)) continue
            val pending = runCatching { scheduler.getPendingJob(timerJobId(schedule.id)) }.getOrNull()
            if (pending != null && schedule.nextRunAt != null) continue
            val next = schedule.nextRunAt ?: FleetScheduleTiming.nextRun(schedule, now).also { repository.setFleetScheduleNextRun(schedule.id, it) }
            arm(context, schedule.id, next, now)
        }
    }

    private const val TAG = "OmniTermSchedule"
}

/**
 * Runs one schedule with nobody there to confirm it, so it refuses what automation refuses: a
 * script on the danger list, a value with no default, a script gone. Its hosts are the targets'
 * hosts at the time it runs, online or not, so a host that is down fails and says so. The run is
 * in Fleet's history as Scheduled, and the schedule keeps how its last run went.
 */
class FleetScheduleRunner(
    context: Context,
    private val repository: AppRepository,
    private val transport: SshTransport,
    private val clock: () -> Long = System::currentTimeMillis,
    private val runTimeoutMs: Long = Automation.RUN_TIMEOUT_MS,
) {
    private val context = context.applicationContext

    /**
     * Runs [scheduleId]; null when it is gone, already running, or paused and this is its timer
     * rather than a Run now ([evenIfPaused]).
     */
    suspend fun run(scheduleId: Int, evenIfPaused: Boolean = true): Automation.RunResult? {
        val schedule = repository.fleetSchedule(scheduleId) ?: return null
        if (!schedule.enabled && !evenIfPaused) return null
        if (!FleetSchedules.claim(scheduleId)) return null
        val at = clock()
        val runKey = "schedule-" + java.util.UUID.randomUUID()
        var outcome: Pair<String, Automation.RunResult>? = null
        try {
            val result = runSchedule(schedule, runKey)
            outcome = when {
                result.error != null && result.hosts.isEmpty() -> UseOutcome.REFUSED
                result.succeeded -> UseOutcome.OK
                else -> UseOutcome.FAILED
            } to result
            return result
        } finally {
            withContext(NonCancellable) {
                val (kind, result) = outcome ?: (
                    UseOutcome.FAILED to Automation.RunResult(emptyList(), context.getString(R.string.automation_stopped), runKey)
                )
                val ran = runCatching { repository.fleetRunByKey(runKey) }.getOrNull() != null
                runCatching { repository.recordFleetScheduleRun(scheduleId, at, kind, result.useDetail(), runKey.takeIf { ran }) }
                    .onFailure { Log.w("OmniTermSchedule", "Saving the schedule's last run failed", it) }
                FleetSchedules.release(scheduleId)
            }
        }
    }

    private suspend fun runSchedule(schedule: FleetScheduleEntity, runKey: String): Automation.RunResult {
        val by = context.getString(R.string.fleet_schedule_by, schedule.name)
        val script = repository.getAllScripts().find { it.id == schedule.scriptId }
        val problem = UnattendedScripts.problem(script, script?.let { commandDangerHits(it.command) }.orEmpty(), UnattendedScripts.Runner.SCHEDULE)
        val servers = if (problem == null) repository.getAllServers().filter(FleetTargets.of(schedule)::matches) else emptyList()
        val refusal = problem ?: context.getString(R.string.fleet_schedule_no_hosts).takeIf { servers.isEmpty() }
        if (refusal != null) {
            val result = Automation.RunResult(emptyList(), refusal)
            // Nobody saw it not run: say so, and open the schedules, since nothing is in the history.
            RunNotifications(
                context, runKey, script?.name ?: schedule.name, by, RunNotify.of(schedule.notify),
                channel = RunNotifications.Channel.SCHEDULES, link = NotificationLinks.fleetSchedules(),
            ).finished(result)
            return result
        }
        return AutomationRunner(context, repository, transport, clock, runTimeoutMs).runScript(
            script!!, servers, emptyMap(), FleetRunHistory.SOURCE_SCHEDULE, RunNotify.of(schedule.notify), by, runKey,
            channel = RunNotifications.Channel.SCHEDULES,
        )
    }
}

/** Runs a schedule's job, then sets its next run, however the run ends. */
class FleetScheduleJobService : RunJobService() {
    override fun workFor(params: JobParameters): (suspend () -> Unit)? {
        val scheduleId = params.extras.getInt(FleetSchedules.KEY_SCHEDULE, 0).takeIf { it > 0 } ?: return null
        val runNow = params.extras.getBoolean(FleetSchedules.KEY_NOW, false)
        val startedAt = System.currentTimeMillis()
        return {
            val repository = AutomationJobs.repository(applicationContext)
            val transport = JschSshTransport()
            try {
                // Stopped part-way, the schedule's last run says so.
                FleetScheduleRunner(applicationContext, repository, transport).run(scheduleId, evenIfPaused = runNow)
            } finally {
                transport.shutdown()
                withContext(NonCancellable) {
                    // A Run now leaves the timer where it was.
                    if (!runNow) {
                        runCatching { FleetSchedules.armNext(applicationContext, repository, scheduleId, startedAt, System.currentTimeMillis()) }
                            .onFailure { Log.w("OmniTermSchedule", "Setting the next run failed", it) }
                    }
                }
            }
        }
    }
}
