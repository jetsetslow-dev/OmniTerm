package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Drives each real Fleet button over SSH to the repository's provisioned disposable host. */
class E2eFleetDiagnosticActionsTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun hostDiagnosticsKeepTheBroadcastDraftAndShowTheirOwnOutput() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_fleet_diagnostics") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        withTimeout(15_000) { while (vm.servers.value.none { it.name == "E2E Foreground Demo" }) delay(20) }
        val host = vm.servers.value.single { it.name == "E2E Foreground Demo" }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertEquals("Use the repository fixture port", (args.getString("port")?.toIntOrNull() ?: 2205), host.port)
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalDraft = vm.broadcastCommandText
        val originalMode = vm.broadcastTargetMode
        val originalTargets = vm.broadcastTargetServerIds.toSet()
        val selected = vm.selectedServerId
        val draft = "unsent fixture broadcast"
        try {
            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            assertEquals("A real probe must establish reachability: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == host.id }.status)
            composeRule.runOnUiThread {
                vm.broadcastCommandText = draft
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.fleetTabIndex = 0
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()
            for ((label, signature) in listOf("Uptime" to "load average", "DF" to "Filesystem", "PS" to "PID")) {
                val tag = "fleet.host.${host.id}.${label.lowercase()}"
                composeRule.onNode(hasScrollAction()).performScrollToNode(hasTestTag(tag))
                composeRule.onNodeWithTag(tag).performClick()
                assertEquals("A single-host diagnostic must leave the unsent broadcast untouched", draft, vm.broadcastCommandText)
                assertEquals(FleetTargetMode.Servers, vm.broadcastTargetMode)
                assertTrue("A diagnostic must leave the draft's targets untouched", vm.broadcastTargetServerIds.isEmpty())
                assertEquals("The Dashboard must remain selected", 0, vm.fleetTabIndex)
                assertEquals(selected, vm.selectedServerId)
                composeRule.waitForIdle()
                composeRule.onNodeWithText("$label · ${host.name}").assertIsDisplayed()
                withTimeout(20_000) { while (vm.actionStreamRunning) delay(20) }
                assertFalse(vm.actionStreamOutput.contains("SSH Error:"))
                assertFalse(vm.actionStreamOutput.contains("Command failed:"))
                assertTrue("$label must show its real fixture output: ${vm.actionStreamOutput.take(300)}", vm.actionStreamOutput.contains(signature))
                composeRule.onNodeWithText("Close").performClick()
            }
        } finally {
            composeRule.runOnUiThread {
                vm.closeActionStream()
                if (vm.isBroadcastExecuting) vm.stopFleetBroadcast()
                vm.broadcastCommandText = originalDraft
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }
}
