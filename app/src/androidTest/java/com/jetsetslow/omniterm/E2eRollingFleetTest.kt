package com.jetsetslow.omniterm

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.util.UUID

/**
 * A rolling Fleet run over SSH to the repository's provisioned disposable host, listed twice: one
 * host at a time, the first fails, so the second is not run; Retry runs both again; Share hands
 * the whole run to the share sheet as a file.
 */
class E2eRollingFleetTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aRollingRunStopsAtAFailureRetryRunsTheRestAndShareAttachesTheRun() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_rolling_fleet") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        withTimeout(15_000) { while (vm.servers.value.none { it.name == "E2E Foreground Demo" }) delay(20) }
        val host = vm.servers.value.single { it.name == "E2E Foreground Demo" }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertEquals("Use the repository fixture port", (args.getString("port")?.toIntOrNull() ?: 2205), host.port)
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalDraft = vm.broadcastCommandText
        val originalPreset = vm.broadcastPreset
        val originalMode = vm.broadcastTargetMode
        val originalTargets = vm.broadcastTargetServerIds.toSet()
        val originalTmux = vm.broadcastInTmux
        val originalBatch = vm.broadcastBatchSize
        val originalStop = vm.broadcastStopOnFailure
        // The same fixture under a second name: two hosts for the batches, one machine to clean up.
        val copyId = repository.insertServer(host.copy(id = 0, name = "E2E Rolling Copy")).toInt()
        val marker = "/tmp/omniterm-e2e-rolling-${UUID.randomUUID().toString().take(8)}"
        // Fails the first time anything runs it, succeeds every time after.
        val command = "f=$marker; if [ -f \"\$f\" ]; then echo again; else touch \"\$f\"; echo first; exit 3; fi"
        // Catches the share sheet's start, keeps its intent and stops it opening over the test.
        val shares = java.util.concurrent.CopyOnWriteArrayList<Intent>()
        val chooser = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? =
                if (intent.action == Intent.ACTION_CHOOSER) {
                    shares.add(intent)
                    Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
                } else {
                    null
                }
        }
        try {
            withTimeout(15_000) { while (vm.servers.value.none { it.id == copyId }) delay(20) }
            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            for (id in listOf(host.id, copyId)) {
                assertEquals("A real probe must reach the fixture: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == id }.status)
            }
            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(false)
                vm.updateBroadcastBatchSize(0)
                vm.broadcastCommandText = ""
                vm.broadcastPreset = null
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(listOf(host.id, copyId))
                vm.broadcastResults.clear()
                vm.fleetTabIndex = 1
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()

            composeRule.onNodeWithTag("fleet.broadcast.batch.1").performClick()
            composeRule.waitForIdle()
            assertEquals(1, vm.broadcastBatchSize)
            if (!vm.broadcastStopOnFailure) composeRule.onNodeWithTag("fleet.broadcast.stop_on_failure").performClick()
            composeRule.waitForIdle()
            assertTrue(vm.broadcastStopOnFailure)

            val field = composeRule.onNodeWithTag("fleet.broadcast.command")
            field.performTextClearance()
            field.performTextInput(command)
            composeRule.onNodeWithTag("fleet.broadcast.run").performClick()
            composeRule.onNodeWithText("Runs on 1 at a time, in this order, and stops after a batch with a failure.", substring = true)
                .assertIsDisplayed()
            composeRule.onNodeWithText("Run").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(90_000) { while (vm.isBroadcastExecuting) delay(50) }

            val first = vm.broadcastResults.toList()
            assertEquals(first.toString(), listOf(BroadcastStatus.Failure, BroadcastStatus.NotRun), first.map { it.status })
            assertTrue(first[0].output, first[0].output.contains("first"))
            assertEquals("Exited with status 3.", first[0].note)
            assertEquals("Not run: ${first[0].serverName} did not succeed, and the run stops on a failure.", first[1].note)
            composeRule.onNodeWithText("not run").assertIsDisplayed()

            composeRule.onNodeWithTag("fleet.broadcast.retry").performClick()
            composeRule.onNodeWithText("Run again on 2 hosts?").assertIsDisplayed()
            composeRule.onNodeWithText("Run").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(90_000) { while (vm.isBroadcastExecuting) delay(50) }
            val retried = vm.broadcastResults.toList()
            assertEquals(retried.toString(), listOf(BroadcastStatus.Success, BroadcastStatus.Success), retried.map { it.status })
            assertEquals("The cards keep their order", first.map { it.serverId }, retried.map { it.serverId })
            retried.forEach { assertTrue(it.output, it.output.contains("again")) }

            instrumentation.addMonitor(chooser)
            composeRule.onNodeWithTag("fleet.broadcast.share").performClick()
            withTimeout(10_000) { while (shares.isEmpty()) delay(50) }
            val send = checkNotNull(IntentCompat.getParcelableExtra(shares.single(), Intent.EXTRA_INTENT, Intent::class.java))
            assertEquals(Intent.ACTION_SEND, send.action)
            val shared = checkNotNull(send.getStringExtra(Intent.EXTRA_TEXT)) { "A short run goes in the message too" }
            assertTrue(shared, shared.startsWith("$ $command\n"))
            retried.forEach { card -> assertTrue(shared, shared.contains("== ${card.serverName} · complete\nagain")) }
            val uri = checkNotNull(IntentCompat.getParcelableExtra(send, Intent.EXTRA_STREAM, Uri::class.java))
            assertTrue("The receiving app may read the file", send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            val attached = context.contentResolver.openInputStream(uri)!!.use { it.readBytes().toString(Charsets.UTF_8) }
            assertEquals("The attached file is the same run, through the app's provider", shared, attached)
        } finally {
            instrumentation.removeMonitor(chooser)
            composeRule.runOnUiThread {
                if (vm.isBroadcastExecuting) vm.stopFleetBroadcast()
            }
            withTimeout(30_000) { while (vm.isBroadcastExecuting) delay(50) }
            // Removes the marker from the fixture with one more plain run on the original host.
            composeRule.runOnUiThread {
                vm.updateBroadcastBatchSize(0)
                vm.runFleetBroadcast("rm -f $marker", listOf(host.id))
            }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(originalTmux)
                vm.updateBroadcastBatchSize(originalBatch)
                vm.updateBroadcastStopOnFailure(originalStop)
                vm.broadcastResults.clear()
                vm.broadcastCommandText = originalDraft
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
            repository.deleteServerAndDependents(copyId)
        }
    }
}
