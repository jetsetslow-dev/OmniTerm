package com.jetsetslow.omniterm

import android.app.job.JobScheduler
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.automation.FleetSchedules
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * A Fleet schedule made in its editor, on the repository's provisioned disposable host: it waits
 * as a job that survives a restart, Run now runs it in the background over SSH, the run is in the
 * history as Scheduled, its last run opens there, and pausing it drops the job.
 */
class E2eFleetScheduleTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun makeAScheduleRunItNowAndPauseIt() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_fleet_schedule") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val context = composeRule.activity.applicationContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val scheduler = context.getSystemService(JobScheduler::class.java)
        withTimeout(15_000) { while (vm.servers.value.none { it.name == HOST }) delay(20) }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalMode = vm.broadcastTargetMode
        val originalTargets = vm.broadcastTargetServerIds.toSet()
        repository.insertScript(QuickScriptEntity(emoji = "", name = SCRIPT, command = "echo $MARKER", color = "cyan", availableForFleet = true))
        val script = repository.getAllScripts().single { it.name == SCRIPT }
        var scheduleId = 0
        try {
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.add(host.id)
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("fleet.tab.schedules").performClick()
            composeRule.onNodeWithTag("fleet.schedules.new").performClick()
            composeRule.onNodeWithTag("fleet.schedule.name").performTextInput(NAME)
            composeRule.onNodeWithTag("fleet.schedule.script").performClick()
            composeRule.onNodeWithTag("fleet.schedule.script.${script.id}").performClick()
            composeRule.onNodeWithTag("fleet.schedule.targets").assertExists()
            composeRule.onNodeWithTag("fleet.schedule.repeat.${FleetScheduleTiming.EVERY}").performScrollTo().performClick()
            composeRule.onNodeWithTag("fleet.schedule.every.720").performScrollTo().performClick()
            composeRule.onNodeWithTag("fleet.schedule.save").performClick()

            withTimeout(10_000) { while (repository.fleetSchedules().none { it.name == NAME && it.nextRunAt != null }) delay(50) }
            val saved = repository.fleetSchedules().single { it.name == NAME }
            scheduleId = saved.id
            assertEquals("it takes Broadcast's picks", "[${host.id}]", saved.serverIds)
            assertEquals(script.id, saved.scriptId)
            // Saving sets the next run and then arms its job, so the job can follow a moment later.
            val job = withTimeoutOrNull(10_000) {
                var pending = scheduler.getPendingJob(FleetSchedules.timerJobId(saved.id))
                while (pending == null) {
                    delay(50)
                    pending = scheduler.getPendingJob(FleetSchedules.timerJobId(saved.id))
                }
                pending
            }
            assertNotNull("it waits as a job", job)
            assertTrue("one that survives a restart", job!!.isPersisted)

            composeRule.onNodeWithTag("fleet.schedule.${saved.id}.run").performClick()
            withTimeout(120_000) { while (repository.fleetSchedule(saved.id)?.lastRunKey == null) delay(100) }
            val ran = repository.fleetSchedule(saved.id)!!
            assertEquals(ran.lastDetail, UseOutcome.OK, ran.lastOutcome)
            val run = repository.fleetRunByKey(ran.lastRunKey!!)!!
            assertEquals(FleetRunHistory.SOURCE_SCHEDULE, run.source)
            val hostRow = repository.fleetRunHosts(run.id).single()
            assertEquals(BroadcastStatus.Success.name, hostRow.status)
            assertTrue(hostRow.output, hostRow.output.contains(MARKER))
            assertNotNull("Run now leaves the timer waiting", scheduler.getPendingJob(FleetSchedules.timerJobId(saved.id)))

            // Its last run opens in Broadcast's history.
            composeRule.onNodeWithTag("fleet.schedule.${saved.id}.last").performScrollTo().performClick()
            composeRule.waitUntil(10_000) { vm.fleetTabIndex == 1 }
            composeRule.waitUntil(10_000) { runCatching { composeRule.onNodeWithTag("fleet.history.details").assertExists() }.isSuccess }

            composeRule.runOnUiThread { vm.setFleetScheduleEnabled(saved.id, false) }
            withTimeout(10_000) { while (scheduler.getPendingJob(FleetSchedules.timerJobId(saved.id)) != null) delay(50) }
            assertNull(repository.fleetSchedule(saved.id)!!.nextRunAt)
        } finally {
            if (scheduleId > 0) {
                repository.deleteFleetSchedule(scheduleId)
                FleetSchedules.cancel(context, scheduleId)
            }
            repository.getAllScripts().filter { it.name == SCRIPT }.forEach { repository.deleteScript(it) }
            composeRule.runOnUiThread {
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NAME = "E2E schedule"
        const val SCRIPT = "E2E schedule probe"
        const val MARKER = "omniterm-e2e-scheduled"
    }
}
