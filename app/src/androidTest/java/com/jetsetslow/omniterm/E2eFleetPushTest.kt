package com.jetsetslow.omniterm

import android.net.Uri
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
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
import java.io.File

/**
 * Fleet's Push a file, over SFTP to the repository's provisioned disposable host: the file arrives
 * whole, replaces an older copy, and a missing folder fails the host without leaving anything.
 */
class E2eFleetPushTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun pushAFileToTheLabHostThroughBroadcast() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_fleet_push") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        withTimeout(15_000) { while (vm.servers.value.none { it.name == HOST }) delay(20) }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalDraft = vm.broadcastCommandText
        val originalPreset = vm.broadcastPreset
        val originalMode = vm.broadcastTargetMode
        val originalTargets = vm.broadcastTargetServerIds.toSet()
        val originalTmux = vm.broadcastInTmux
        val originalDestination = vm.fleetPushDestination
        val source = File(composeRule.activity.cacheDir, FILE).apply { writeText(CONTENT) }
        suspend fun run(command: String): String {
            composeRule.runOnUiThread { vm.runFleetBroadcast(command, listOf(host.id)) }
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            return vm.broadcastResults.single { it.serverId == host.id }.output
        }
        try {
            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            assertEquals("A real probe must establish reachability: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == host.id }.status)
            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(false)
                vm.broadcastPreset = null
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.add(host.id)
            }
            // An older copy to replace.
            run("mkdir -p $DIR && printf 'old copy' > $DIR/$FILE && echo ready")
            composeRule.runOnUiThread {
                vm.clearBroadcastOutputs()
                vm.broadcastCommandText = ""
                vm.fleetTabIndex = 1
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()

            // The system file picker is not the app's to drive; the picked file is handed over as it would be.
            composeRule.onNodeWithTag("fleet.broadcast.push").performScrollTo().performClick()
            composeRule.onNodeWithTag("fleet.push.choose").assertExists()
            composeRule.runOnUiThread { vm.pickFleetPushFile(Uri.fromFile(source)) }
            withTimeout(10_000) { while (vm.fleetPushReading || vm.fleetPushPick == null && vm.fleetPushError == null) delay(20) }
            assertEquals(vm.fleetPushError, FILE, vm.fleetPushPick?.fileName)
            composeRule.onNodeWithTag("fleet.push.destination").performTextClearance()
            composeRule.onNodeWithTag("fleet.push.destination").performTextInput("$DIR/")
            composeRule.onNodeWithTag("fleet.push.next").performClick()
            composeRule.onNodeWithText("Push").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(120_000) { while (vm.isBroadcastExecuting) delay(50) }
            val pushed = vm.broadcastResults.single { it.serverId == host.id }
            assertEquals("Push: ${pushed.output} ${pushed.note}", BroadcastStatus.Success, pushed.status)
            assertTrue(pushed.output, pushed.output.contains("$DIR/$FILE"))

            val listing = run("cat $DIR/$FILE; echo; ls -a $DIR")
            assertTrue("the new copy replaced the old: $listing", listing.contains(CONTENT.trim()) && !listing.contains("old copy"))
            assertTrue("no part file is left: $listing", !listing.contains("omniterm-part"))

            // A folder that is not there fails the host, and leaves nothing behind.
            composeRule.runOnUiThread {
                vm.clearBroadcastOutputs()
                vm.fleetPushDestination = "$DIR/missing/"
            }
            composeRule.runOnUiThread { vm.pickFleetPushFile(Uri.fromFile(source)) }
            withTimeout(10_000) { while (vm.fleetPushReading || vm.fleetPushPick == null) delay(20) }
            composeRule.runOnUiThread { vm.runFleetPush(listOf(host.id)) }
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(120_000) { while (vm.isBroadcastExecuting) delay(50) }
            val missing = vm.broadcastResults.single { it.serverId == host.id }
            assertEquals(BroadcastStatus.Failure, missing.status)
            assertTrue(missing.note.orEmpty(), missing.note.orEmpty().contains("$DIR/missing"))
        } finally {
            composeRule.runOnUiThread {
                if (vm.isBroadcastExecuting) vm.stopFleetBroadcast()
                vm.clearFleetPushPick()
            }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            runCatching { run("rm -rf $DIR") }
            composeRule.runOnUiThread {
                vm.clearBroadcastOutputs()
                vm.fleetPushDestination = originalDestination
                vm.updateBroadcastInTmux(originalTmux)
                vm.broadcastCommandText = originalDraft
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
            source.delete()
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val DIR = "/tmp/omniterm-e2e-push"
        const val FILE = "e2e-push.conf"
        const val CONTENT = "pushed by E2eFleetPushTest\n"
    }
}
