package com.jetsetslow.omniterm

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobScheduler
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.automation.FleetScheduleRunner
import com.jetsetslow.omniterm.automation.FleetSchedules
import com.jetsetslow.omniterm.automation.RunNotifications
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.FleetTargets
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A Fleet schedule: it runs its script on the hosts its targets match when it runs, is kept in
 * Fleet's history as Scheduled, refuses what automation refuses and says so, never overlaps
 * itself, and waits as one job that survives a restart.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FleetScheduleRobolectricTest {
    private val application: Application get() = ApplicationProvider.getApplicationContext()
    private lateinit var repository: AppRepository

    @Test
    fun itRunsOnTheHostsItsTagsMatchAndKeepsTheRun() = withLab { hosts ->
        hosts.replies[NAS] = "up 3 days\n"
        hosts.replies[PI] = "SSH Error: command failed (3): disk full\n"
        val id = schedule(script("uptime"), FleetTargets(FleetTargetMode.Tags, tags = listOf("storage")))

        val result = FleetScheduleRunner(application, repository, hosts).run(id)!!

        assertEquals("web has no storage tag", setOf("nas", "pi"), result.hosts.map { it.name }.toSet())
        assertTrue(hosts.commands.none { it.first.host == WEB })
        val run = repository.fleetRunsFlow.first().single()
        assertEquals(FleetRunHistory.SOURCE_SCHEDULE, run.run.source)
        assertEquals(SCRIPT_NAME, run.run.scriptName)
        assertEquals(1, run.succeeded)
        val kept = repository.fleetSchedule(id)!!
        assertEquals(UseOutcome.FAILED, kept.lastOutcome)
        assertEquals("the schedule's last run opens it", run.run.runKey, kept.lastRunKey)
        assertTrue(kept.lastDetail, kept.lastDetail.contains("pi"))
        val notice = notification(run.run.runKey)
        assertEquals("schedules have their own channel", RunNotifications.Channel.SCHEDULES.id, notice.channelId)
        assertEquals("Schedule “Nightly” ran $SCRIPT_NAME", notice.extras.getString(Notification.EXTRA_TITLE))
    }

    @Test
    fun itRefusesWhatAutomationRefusesAndSaysSo() = withLab { hosts ->
        val destructive = schedule(script("rm -rf /srv/data"), FleetTargets(FleetTargetMode.Servers, serverIds = setOf(nasId)))
        val refused = FleetScheduleRunner(application, repository, hosts).run(destructive)!!
        assertTrue(refused.error!!, refused.error!!.startsWith("A schedule runs it without asking, so it must only read"))
        assertTrue("no host was contacted", hosts.commands.isEmpty())
        assertTrue("nothing ran, so nothing is in the history", repository.fleetRunsFlow.first().isEmpty())
        val kept = repository.fleetSchedule(destructive)!!
        assertEquals(UseOutcome.REFUSED, kept.lastOutcome)
        assertNull(kept.lastRunKey)

        val nobody = schedule(script("uptime", "Uptime only"), FleetTargets(FleetTargetMode.Tags, tags = listOf("nowhere")), name = "Empty")
        assertEquals(
            "No saved host matches this schedule's hosts.",
            FleetScheduleRunner(application, repository, hosts).run(nobody)!!.error,
        )
        val shown = shadowOf(application.getSystemService(NotificationManager::class.java)).allNotifications
            .single { it.extras.getString(Notification.EXTRA_TITLE) == "Schedule “Empty” could not run Uptime only" }
        assertEquals(
            "a tap opens the schedules, since the history has nothing",
            "omniterm://notification/fleet-schedules",
            shadowOf(shown.contentIntent).savedIntent.dataString,
        )
    }

    @Test
    fun aScheduleNeverRunsTwiceAtOnce() = withLab { hosts ->
        val id = schedule(script("uptime"), FleetTargets(FleetTargetMode.Servers, serverIds = setOf(nasId)))
        val gate = CompletableDeferred<Unit>()
        hosts.held[NAS] = gate
        val first = async(Dispatchers.IO) { FleetScheduleRunner(application, repository, hosts).run(id) }
        withTimeout(10_000) { while (!FleetSchedules.isRunning(id)) delay(10) }
        assertNull("a second start while it runs does nothing", FleetScheduleRunner(application, repository, hosts).run(id))
        gate.complete(Unit)
        assertNotNull(withTimeout(10_000) { first.await() })
        assertFalse(FleetSchedules.isRunning(id))
        hosts.held.clear()
        assertNotNull("once it is done it runs again", FleetScheduleRunner(application, repository, hosts).run(id))

        // Paused, its timer runs nothing, and Run now still runs it once.
        repository.setFleetScheduleEnabled(id, false)
        val before = hosts.commands.size
        assertNull(FleetScheduleRunner(application, repository, hosts).run(id, evenIfPaused = false))
        assertEquals(before, hosts.commands.size)
        assertNotNull(FleetScheduleRunner(application, repository, hosts).run(id, evenIfPaused = true))
    }

    @Test
    fun aScheduleThatIsOnWaitsAsOneJobAcrossRestartsAndOneThatIsOffDoesNot() = withLab { _ ->
        val scheduler = application.getSystemService(JobScheduler::class.java)
        val now = 1_800_000_000_000L
        val id = schedule(script("uptime"), FleetTargets(FleetTargetMode.Servers, serverIds = setOf(nasId)), every = 30)

        FleetSchedules.apply(application, repository, id, now)
        val job = scheduler.getPendingJob(FleetSchedules.timerJobId(id))!!
        assertTrue("it survives a restart", job.isPersisted)
        assertEquals(30 * 60_000L, job.minLatencyMillis)
        assertEquals(JobInfo.NETWORK_TYPE_ANY, job.networkType)
        assertEquals(now + 30 * 60_000L, repository.fleetSchedule(id)!!.nextRunAt)

        // A run that started late counts the next one from when it started.
        FleetSchedules.armNext(application, repository, id, startedAt = now + 40 * 60_000L, now = now + 45 * 60_000L)
        assertEquals(now + 70 * 60_000L, repository.fleetSchedule(id)!!.nextRunAt)
        assertEquals(25 * 60_000L, scheduler.getPendingJob(FleetSchedules.timerJobId(id))!!.minLatencyMillis)

        // Run now is a job of its own, and leaves the timer as it was.
        assertTrue(FleetSchedules.runNow(application, id))
        assertFalse(scheduler.getPendingJob(FleetSchedules.nowJobId(id))!!.isPersisted)
        assertNotNull(scheduler.getPendingJob(FleetSchedules.timerJobId(id)))

        repository.setFleetScheduleEnabled(id, false)
        FleetSchedules.apply(application, repository, id, now)
        assertNull(scheduler.getPendingJob(FleetSchedules.timerJobId(id)))
        assertNull(repository.fleetSchedule(id)!!.nextRunAt)
    }

    @Test
    fun startingTheAppGivesBackTheJobsAndDropsTheOnesWithNoSchedule() = withLab { _ ->
        val scheduler = application.getSystemService(JobScheduler::class.java)
        val now = 1_800_000_000_000L
        val id = schedule(script("uptime"), FleetTargets(FleetTargetMode.Servers, serverIds = setOf(nasId)), every = 60)
        // Force-stopped while its run was due: the job is gone, and its time went by.
        repository.setFleetScheduleNextRun(id, now - 5 * 60_000L)
        val orphan = FleetSchedules.timerJobId(id + 1)
        FleetSchedules.arm(application, id + 1, now + 60_000L, now)
        assertNotNull(scheduler.getPendingJob(orphan))

        FleetSchedules.reconcile(application, repository, now)

        assertEquals("it runs once, at once", 0L, scheduler.getPendingJob(FleetSchedules.timerJobId(id))!!.minLatencyMillis)
        assertNull("a job whose schedule is gone is dropped", scheduler.getPendingJob(orphan))
        // Run again, nothing changes: a job that is waiting is left alone.
        FleetSchedules.reconcile(application, repository, now + 1)
        assertEquals(0L, scheduler.getPendingJob(FleetSchedules.timerJobId(id))!!.minLatencyMillis)
    }

    private fun notification(runKey: String): Notification =
        shadowOf(application.getSystemService(NotificationManager::class.java)).getNotification(RunNotifications.idFor(runKey))

    private suspend fun script(command: String, name: String = SCRIPT_NAME): QuickScriptEntity {
        repository.insertScript(QuickScriptEntity(emoji = "", name = name, command = command, color = "cyan", availableForFleet = true))
        return repository.getAllScripts().first { it.name == name && it.command == command }
    }

    private suspend fun schedule(script: QuickScriptEntity, targets: FleetTargets, name: String = "Nightly", every: Int = 60): Int {
        val picks = targets.toSet(name)
        return repository.saveFleetSchedule(
            FleetScheduleEntity(
                name = name, scriptId = script.id,
                mode = picks.mode, serverIds = picks.serverIds, groups = picks.groups, tags = picks.tags, allTags = picks.allTags,
                repeat = FleetScheduleTiming.EVERY, everyMinutes = every, notify = RunNotify.ALWAYS,
            ),
        )
    }

    private var nasId = 0

    private fun withLab(block: suspend kotlinx.coroutines.CoroutineScope.(FakeHosts) -> Unit) = runBlocking {
        val db = AppDatabase.getDatabase(application)
        withContext(Dispatchers.IO) { db.clearAllTables() }
        repository = AppRepository(db)
        nasId = repository.insertServer(ServerEntity(name = "nas", host = NAS, username = "fixture", tags = "storage")).toInt()
        repository.insertServer(ServerEntity(name = "pi", host = PI, username = "fixture", tags = "storage, pi"))
        repository.insertServer(ServerEntity(name = "web", host = WEB, username = "fixture"))
        try {
            block(FakeHosts())
        } finally {
            application.getSystemService(JobScheduler::class.java).cancelAll()
            withContext(Dispatchers.IO) { db.clearAllTables() }
        }
    }

    /** Hosts that answer the OS probe as Linux and each command with [replies]. */
    private class FakeHosts : SshTransport {
        val replies = ConcurrentHashMap<String, String>()
        val held = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        val commands = CopyOnWriteArrayList<Pair<SshCredentials, String>>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(creds to command)
            if (command == RemoteCommands.OS_PROBE) return "Linux\n/bin/bash"
            held[creds.host]?.await()
            return replies[creds.host] ?: ""
        }

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String =
            error("a schedule reads whole results")

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("a schedule opens no shell")
    }

    private companion object {
        const val NAS = "10.0.0.10"
        const val PI = "10.0.0.11"
        const val WEB = "10.0.0.12"
        const val SCRIPT_NAME = "schedule fixture"
    }
}
