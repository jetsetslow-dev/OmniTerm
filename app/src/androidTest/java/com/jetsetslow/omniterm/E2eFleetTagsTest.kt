package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
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

/**
 * Tags typed in the host editor reach Fleet: the repository's provisioned disposable host is
 * tagged, Broadcast runs on it by its tags (every one of two), and the targets saved under a name
 * come back from Saved after being cleared.
 */
class E2eFleetTagsTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun hostTagsTargetAFleetRunAndSavedTargetsComeBack() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_fleet_tags") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        withTimeout(15_000) { while (vm.servers.value.none { it.name == HOST }) delay(20) }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalDraft = vm.broadcastCommandText
        val originalPreset = vm.broadcastPreset
        val originalMode = vm.broadcastTargetMode
        val originalServers = vm.broadcastTargetServerIds.toSet()
        val originalTags = vm.broadcastTargetTags.toList()
        val originalAll = vm.broadcastTagsMatchAll
        val originalTmux = vm.broadcastInTmux
        try {
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.navigateTo(Screen.Servers) }
            composeRule.waitForIdle()

            // Tag the host in its editor, as a user would.
            composeRule.onNodeWithTag("server.actions.${host.id}").performClick()
            composeRule.onNodeWithText("Edit Server Configuration").performClick()
            composeRule.onNodeWithTag("server.tags").performScrollTo().performTextClearance()
            composeRule.onNodeWithTag("server.tags").performTextInput("$TAG, $OTHER_TAG, ${TAG.uppercase()}")
            composeRule.onNodeWithText("Next").performClick()
            composeRule.onNodeWithText("Next").performClick()
            composeRule.onNodeWithText("Update Server").performClick()
            composeRule.waitForIdle()
            if (composeRule.onAllNodesWithText("Save anyway").fetchSemanticsNodes().isNotEmpty()) {
                composeRule.onNodeWithText("Save anyway").performClick()
            }
            withTimeout(15_000) { while (vm.servers.value.single { it.id == host.id }.tags != "$TAG, $OTHER_TAG") delay(20) }
            composeRule.waitForIdle()
            composeRule.onNodeWithText("#$TAG").assertExists()

            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            assertEquals("A real probe must establish reachability: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == host.id }.status)

            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(false)
                vm.broadcastCommandText = "echo tagged-run"
                vm.broadcastPreset = null
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetTags.clear()
                vm.broadcastTagsMatchAll = false
                vm.fleetTabIndex = 1
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()

            // Every one of two tags: this host has both.
            composeRule.onNodeWithTag("broadcast.targets.tags").performClick()
            composeRule.onNodeWithTag("broadcast.tag.$TAG").performClick()
            composeRule.onNodeWithTag("broadcast.tag.$OTHER_TAG").performClick()
            composeRule.onNodeWithTag("broadcast.tags.all").performClick()
            composeRule.waitForIdle()
            assertEquals(FleetTargetMode.Tags, vm.broadcastTargetMode)
            assertTrue("the tagged host is a target", vm.broadcastTargets.matches(vm.servers.value.single { it.id == host.id }))
            composeRule.onNodeWithTag("fleet.broadcast.run").performClick()
            composeRule.onNodeWithText("Run").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            val result = vm.broadcastResults.single { it.serverId == host.id }
            assertEquals("Fixture output: ${result.output.take(400)} ${result.note}", BroadcastStatus.Success, result.status)
            assertTrue(result.output, result.output.contains("tagged-run"))

            // Save these targets, clear them, and pick them again from Saved. Results collapse the
            // controls, so open them first, as a user would.
            composeRule.onNodeWithContentDescription("Expand controls").performClick()
            composeRule.onNodeWithTag("broadcast.targets.saved").performClick()
            composeRule.onNodeWithTag("saved_targets.name").performTextInput(SET_NAME)
            composeRule.onNodeWithTag("saved_targets.save").performClick()
            withTimeout(10_000) { while (vm.fleetTargetSets.value.none { it.name == SET_NAME }) delay(20) }
            val saved = vm.fleetTargetSets.value.single { it.name == SET_NAME }
            composeRule.onNodeWithText("Close").performClick()
            composeRule.runOnUiThread {
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetTags.clear()
                vm.broadcastTagsMatchAll = false
            }
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("broadcast.targets.saved").performClick()
            composeRule.onNodeWithTag("saved_targets.${saved.id}").performClick()
            composeRule.waitForIdle()
            assertEquals(FleetTargetMode.Tags, vm.broadcastTargetMode)
            assertEquals(listOf(TAG, OTHER_TAG), vm.broadcastTargetTags.toList())
            assertTrue("every tag, as saved", vm.broadcastTagsMatchAll)

            composeRule.onNodeWithTag("broadcast.targets.saved").performClick()
            composeRule.onNodeWithTag("saved_targets.${saved.id}.delete").performClick()
            withTimeout(10_000) { while (vm.fleetTargetSets.value.any { it.id == saved.id }) delay(20) }
            composeRule.onNodeWithText("Close").performClick()
        } finally {
            composeRule.runOnUiThread {
                if (vm.isBroadcastExecuting) vm.stopFleetBroadcast()
                vm.fleetTargetSets.value.filter { it.name == SET_NAME }.forEach { vm.deleteFleetTargetSet(it.id) }
                vm.servers.value.firstOrNull { it.id == host.id }?.let { vm.updateServer(it.copy(tags = host.tags)) }
                vm.updateBroadcastInTmux(originalTmux)
                vm.broadcastCommandText = originalDraft
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalServers)
                vm.broadcastTargetTags.clear()
                vm.broadcastTargetTags.addAll(originalTags)
                vm.broadcastTagsMatchAll = originalAll
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
            withTimeout(10_000) { while (vm.servers.value.firstOrNull { it.id == host.id }?.tags.orEmpty() != host.tags) delay(20) }
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val TAG = "e2e-tag"
        const val OTHER_TAG = "e2e-prod"
        const val SET_NAME = "E2E tagged hosts"
    }
}
