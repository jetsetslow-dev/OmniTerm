package com.jetsetslow.omniterm

import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastResultItem
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/**
 * Fleet with sudo, on the repository's provisioned disposable host, whose sudo asks its login for
 * no password: turned on in Broadcast, a command waits for the user's answer and then runs as root,
 * with no sudo password saved and with one saved; the same command without sudo is the login; a
 * file is pushed into /etc, where the login may not write, and belongs to root. sudo refusing is
 * FleetSudoRobolectricTest's: this host's sudo never does. Run with
 * `./scripts/test-hosts.sh suite E2eFleetSudoTest omniterm_e2e_fleet_sudo=yes pass`: `pass` is the
 * fixture's password, saved as the host's sudo password.
 */
class E2eFleetSudoTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aCommandAndAPushRunAsRootOnceTheUserSaysSo() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_fleet_sudo") == "yes")
        val pass = E2eArgs.require("pass")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        withTimeout(15_000) { while (vm.servers.value.none { it.name == HOST }) delay(20) }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val original = repository.getServerById(host.id)!!
        val originalScreen = vm.currentScreen
        val originalTab = vm.fleetTabIndex
        val originalDraft = vm.broadcastCommandText
        val originalPreset = vm.broadcastPreset
        val originalMode = vm.broadcastTargetMode
        val originalTargets = vm.broadcastTargetServerIds.toSet()
        val originalTmux = vm.broadcastInTmux
        val originalDestination = vm.fleetPushDestination
        val name = "omniterm-e2e-sudo-${System.currentTimeMillis().toString().takeLast(6)}.conf"
        val source = File(composeRule.activity.cacheDir, name).apply { writeText(CONTENT) }

        fun has(tag: String) = composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()

        suspend fun saveSudoPassword(password: String) {
            var saved: String? = "pending"
            composeRule.runOnUiThread { vm.updateServer(original.copy(sudoPassword = password)) { saved = it } }
            withTimeout(15_000) { while (saved == "pending") delay(20) }
            assertEquals(null, saved)
            withTimeout(15_000) { while (repository.getServerById(host.id)?.sudoPassword != password) delay(20) }
        }

        // Every sudo run asks first: nothing has started while the question is up.
        suspend fun answerAndWait(): BroadcastResultItem {
            composeRule.waitUntil(15_000) { has("sudo.confirm.continue") }
            assertFalse("nothing runs before the answer", vm.isBroadcastExecuting)
            composeRule.onNodeWithTag("sudo.confirm.continue").performClick()
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(120_000) { while (vm.isBroadcastExecuting) delay(50) }
            return vm.broadcastResults.single { it.serverId == host.id }
        }

        suspend fun asRoot(command: String): BroadcastResultItem {
            composeRule.runOnUiThread { vm.runFleetBroadcast(command, listOf(host.id), sudo = true) }
            return answerAndWait()
        }

        try {
            // Saved before the probe: saving a host sets it to "connecting" until it is probed again.
            saveSudoPassword("")
            val previousProbe = vm.lastTelemetryStartMs
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.refreshAllServers() }
            withTimeout(10_000) { while (!vm.isRefreshing && vm.lastTelemetryStartMs <= previousProbe) delay(20) }
            withTimeout(30_000) { while (vm.isRefreshing) delay(20) }
            assertEquals("A real probe must establish reachability: ${vm.manualRefreshError}", "online", vm.servers.value.single { it.id == host.id }.status)
            composeRule.runOnUiThread {
                vm.updateBroadcastInTmux(false)
                vm.updateBroadcastSudo(false)
                vm.broadcastPreset = null
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.add(host.id)
                vm.clearBroadcastOutputs()
                vm.broadcastCommandText = "id -u"
                vm.fleetTabIndex = 1
                vm.navigateTo(Screen.Fleet)
            }
            composeRule.waitForIdle()

            // Turned on in Broadcast, the confirmation shows root's prompt, and the question follows.
            composeRule.onNodeWithTag("fleet.broadcast.sudo").performScrollTo().performClick()
            composeRule.waitForIdle()
            assertTrue(vm.broadcastSudo)
            composeRule.onNodeWithTag("fleet.broadcast.run").assertIsEnabled().performClick()
            composeRule.waitUntil(10_000) { composeRule.onAllNodesWithText("# id -u", substring = true).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithText("# id -u", substring = true).assertIsDisplayed()
            composeRule.onNodeWithText("Run").performClick()
            // The lab host's sudo asks its login for no password, so with none saved it runs as root.
            val unasked = answerAndWait()
            assertEquals(unasked.output + unasked.note.orEmpty(), BroadcastStatus.Success, unasked.status)
            assertEquals("root is user 0: ${unasked.output}", "0", unasked.output.trim().lines().last().trim())

            // The same command without sudo is the login itself, and no question is asked.
            composeRule.runOnUiThread { vm.runFleetBroadcast("id -u", listOf(host.id)) }
            withTimeout(60_000) { while (!vm.isBroadcastExecuting) delay(20) }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            val plain = vm.broadcastResults.single { it.serverId == host.id }
            assertEquals(BroadcastStatus.Success, plain.status)
            assertTrue("the login is not root: ${plain.output}", plain.output.trim() != "0")
            assertFalse(has("sudo.confirm.continue"))

            // With a sudo password saved, it goes to sudo on the command's input, and the command runs as root.
            saveSudoPassword(pass)
            val root = asRoot("id -u")
            assertEquals(root.output + root.note.orEmpty(), BroadcastStatus.Success, root.status)
            assertEquals("root is user 0: ${root.output}", "0", root.output.trim().lines().last().trim())
            val kept = withTimeout(10_000) {
                repository.fleetRunsFlow.first { runs -> runs.any { it.run.command == "id -u" && it.succeeded == 1 } }
            }.first { it.run.command == "id -u" && it.succeeded == 1 }
            assertTrue("the history says it ran with sudo", kept.run.sudo)

            // A file goes into /etc, where the login may not write, and belongs to root there.
            composeRule.runOnUiThread { vm.pickFleetPushFile(Uri.fromFile(source)) }
            withTimeout(10_000) { while (vm.fleetPushReading || vm.fleetPushPick == null && vm.fleetPushError == null) delay(20) }
            assertEquals(vm.fleetPushError, name, vm.fleetPushPick?.fileName)
            composeRule.runOnUiThread {
                vm.fleetPushDestination = "/etc/"
                vm.runFleetPush(listOf(host.id))
            }
            val pushed = answerAndWait()
            assertEquals("Push: ${pushed.output} ${pushed.note}", BroadcastStatus.Success, pushed.status)
            assertTrue(pushed.output, pushed.output.endsWith("to /etc/$name"))
            val placed = asRoot("cat /etc/$name; stat -c 'owner=%U' /etc/$name; echo left=\$(ls -a ~${original.username} | grep -c omniterm-push)")
            assertTrue(placed.output, placed.output.contains(CONTENT.trim()))
            assertTrue(placed.output, placed.output.contains("owner=root"))
            assertTrue("nothing is left in the login's home: ${placed.output}", placed.output.contains("left=0"))
        } finally {
            composeRule.runOnUiThread { if (vm.isBroadcastExecuting) vm.stopFleetBroadcast() }
            withTimeout(60_000) { while (vm.isBroadcastExecuting) delay(50) }
            runCatching {
                composeRule.runOnUiThread { vm.cancelPendingSudoAction() }
                asRoot("rm -f /etc/$name")
            }
            composeRule.runOnUiThread {
                vm.cancelPendingSudoAction()
                vm.clearFleetPushPick()
                vm.clearBroadcastOutputs()
                vm.updateBroadcastSudo(false)
                vm.updateBroadcastInTmux(originalTmux)
                vm.fleetPushDestination = originalDestination
                vm.broadcastCommandText = originalDraft
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetMode = originalMode
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.fleetTabIndex = originalTab
                vm.navigateTo(originalScreen)
            }
            var restored: String? = "pending"
            composeRule.runOnUiThread { vm.updateServer(original) { restored = it } }
            withTimeout(15_000) { while (restored == "pending") delay(20) }
            source.delete()
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val CONTENT = "# written by OmniTerm's sudo push test\nlisten 8080\n"
    }
}
