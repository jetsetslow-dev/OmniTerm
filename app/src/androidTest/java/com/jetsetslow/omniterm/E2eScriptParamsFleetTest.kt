package com.jetsetslow.omniterm

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * A Fleet run of a multi-line command with a `{{placeholder}}`, over SSH to the repository's
 * provisioned disposable host: the value is asked for, reaches the host as one quoted word, and a
 * script meant for another OS leaves the host out instead of failing on it.
 */
class E2eScriptParamsFleetTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @OptIn(ExperimentalTestApi::class)
    @Test fun fleetAsksForValuesQuotesThemAndSkipsHostsTheScriptDoesNotTarget() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_script_params") == "yes")
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
        try {
            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            assertEquals("A real probe must establish reachability: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == host.id }.status)
            withTimeout(30_000) { while (vm.hostMetricsById[host.id] == null) delay(50) }
            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(false)
                vm.broadcastCommandText = ""
                vm.broadcastPreset = null
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.add(host.id)
                vm.fleetTabIndex = 1
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()

            // Enter starts a second line. The single-line field it replaced took Enter as "done", so a
            // script could only be pasted in, and then showed as one long line.
            val field = composeRule.onNodeWithTag("fleet.broadcast.command")
            field.performTextClearance()
            field.performTextInput("printf 'first line\\n'")
            field.performKeyInput { pressKey(Key.Enter) }
            field.performTextInput("printf '[%s]\\n' {{msg}}")
            assertEquals("printf 'first line\\n'\nprintf '[%s]\\n' {{msg}}", vm.broadcastCommandText)
            composeRule.onNodeWithTag("fleet.broadcast.run").performClick()

            // The values form comes first, and a value is one word however it is written.
            composeRule.onNodeWithTag("script.param.msg").performTextInput("it's; echo INJECTED")
            composeRule.onNodeWithTag("script.params.next").performClick()
            composeRule.onNodeWithText("Run").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            val result = vm.broadcastResults.single { it.serverId == host.id }
            assertEquals("Fixture output: ${result.output.take(400)} ${result.note}", BroadcastStatus.Success, result.status)
            assertTrue(result.output, result.output.contains("first line"))
            assertTrue(result.output, result.output.contains("[it's; echo INJECTED]"))
            assertFalse("The value must not run as a command", result.output.lines().any { it.trim() == "INJECTED" })

            // A script for Windows leaves this Linux host out, so nothing runs.
            val windowsOnly = QuickScriptEntity(
                emoji = "WIN", name = "Windows only", command = "ver", color = "cyan",
                availableForQuick = false, availableForFleet = true, targetOs = "Windows",
            )
            composeRule.runOnUiThread {
                vm.broadcastCommandText = windowsOnly.command
                vm.broadcastPreset = windowsOnly
            }
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("fleet.broadcast.run").performClick()
            composeRule.onNodeWithText("No host matches").assertIsDisplayed()
            composeRule.onNodeWithText("Close").performClick()
            assertFalse(vm.isBroadcastExecuting)
            assertEquals("Nothing ran on the skipped host", BroadcastStatus.Success, vm.broadcastResults.single().status)
        } finally {
            composeRule.runOnUiThread {
                if (vm.isBroadcastExecuting) vm.stopFleetBroadcast()
                vm.updateBroadcastInTmux(originalTmux)
                vm.broadcastCommandText = originalDraft
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }
}
