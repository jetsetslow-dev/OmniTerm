package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.printToString
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.alertNotificationId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Image updates against the repository's own registry fixture (`./scripts/test-hosts.sh
 * registry`), on the Docker runtime host (2205) and the Podman one (2206). Each holds
 * omniterm/steady:1 as the registry has it and omniterm/app:latest one push behind it.
 * - Containers → Images: Check for updates marks app:latest "Update available" and steady:1
 *   "Up to date", and the button rests for 10 minutes.
 * - Stacks says how many images have updates and leads to Images.
 * - An Image Updates rule alerts naming app:latest, reusing that check instead of asking the
 *   registry again.
 * The Podman run adds its own host for 2206 (`-e user`, `-e pass`) and removes it afterwards.
 */
class E2eImageUpdatesTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun dockerHostShowsTheUpdateAndItsRuleAlerts() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_image_updates") == "yes")
        val vm = model()
        await("lab host loaded", 15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the Docker runtime fixture", 2205, host.port)
        val originalAlertsEnabled = vm.alertsEnabled
        // The rule and alert lists are shared only while something collects them, and the
        // Containers screen does not: collect them here for the length of the test.
        val hot = CoroutineScope(Dispatchers.Default).launch {
            launch { vm.alertRules.collect {} }
            launch { vm.activeAlerts.collect {} }
        }
        try {
            TestNotifications.allow()
            // Read from the database: the model's list may not have loaded yet.
            val rules = AppDatabase.getDatabase(composeRule.activity).alertRuleDao()
            rules.getAllRules().filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            val until = System.currentTimeMillis() + 10_000
            while (rules.getAllRules().any { it.notes == NOTE } && System.currentTimeMillis() < until) delay(100)
            assertTrue("leftover rules deleted", rules.getAllRules().none { it.notes == NOTE })
            withContainers(vm, host, "docker") {
                val checkedAt = checkImages(vm, host, "docker")

                // Stacks: the count, and a tap leads to Images.
                composeRule.runOnUiThread { vm.activeInfraTab = 0 }
                composeRule.waitForIdle()
                composeRule.onNodeWithTag("stacks.imageUpdates").assertTextEquals("1 image has an update. See Images.").performClick()
                composeRule.waitUntil(5_000) { vm.activeInfraTab == 2 }

                // The rule reads the check just made, and names the image.
                vm.saveAlertsEnabled(true)
                vm.addAlertRule(host.id, HostChecks.IMAGE_UPDATES, "/", 0f, "WARNING", "0m", NOTE)
                await("rule saved", 10_000) { vm.alertRules.value.any { it.notes == NOTE } }
                val rule = vm.alertRules.value.single { it.notes == NOTE }
                vm.refreshServer(host.id)
                await("rule checked", 120_000) { vm.hostCheckResults[rule.id to host.id] != null }
                val reading = vm.hostCheckResults.getValue(rule.id to host.id)
                assertEquals(reading.summary, 1f, reading.value)
                assertEquals("the rule asked no registry again", checkedAt, vm.imageUpdateReports.getValue(host.id).checkedAt)
                await("incident opened", 30_000) { vm.activeAlerts.value.any { it.ruleId == rule.id && it.serverId == host.id } }
                await("notification posted", 10_000) { TestNotifications.text(alertNotificationId(rule.id, host.id)) != null }
                assertEquals("Updates for $APP", TestNotifications.text(alertNotificationId(rule.id, host.id)))
            }
        } finally {
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(originalAlertsEnabled)
            hot.cancel()
        }
    }

    @Test fun podmanHostShowsTheUpdate() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_image_updates") == "yes")
        val user = requireNotNull(args.getString("user")) { "-e user <name> is required" }
        val pass = requireNotNull(args.getString("pass")) { "-e pass <password> is required" }
        val vm = model()
        vm.servers.value.filter { it.name == PODMAN_HOST }.forEach { vm.deleteServer(it) }
        await("old Podman host removed", 10_000) { vm.servers.value.none { it.name == PODMAN_HOST } }
        var added: String? = "pending"
        composeRule.runOnUiThread {
            vm.addServer(PODMAN_HOST, "127.0.0.1", 2206, user, null, "password", "", 0, false, "", password = pass) { added = it }
        }
        await("Podman host added", 10_000) { vm.servers.value.any { it.name == PODMAN_HOST } }
        assertEquals(null, added)
        val host = vm.servers.value.single { it.name == PODMAN_HOST }
        try {
            // The fixture's own host key, on first use; only for this host's port.
            val approve = CoroutineScope(Dispatchers.Main).launch {
                while (true) {
                    vm.pendingHostKeyApproval?.let { if ("2206" in it.host || it.host == "127.0.0.1") vm.approveHostKey(true) }
                    delay(100)
                }
            }
            try {
                assertTrue(vm.executeSshCommand(host, "printf 'OT-READY\\n'").contains("OT-READY"))
            } finally {
                approve.cancel()
            }
            withContainers(vm, host, "podman") { checkImages(vm, host, "podman") }
        } finally {
            composeRule.runOnUiThread { vm.selectedServerId = null }
            vm.deleteServer(host)
            await("Podman host removed", 10_000) { vm.servers.value.none { it.name == PODMAN_HOST } }
        }
    }

    /** Creates (never starts) one container per fixture image on [host], runs [block], removes them. */
    private suspend fun withContainers(vm: AppViewModel, host: ServerEntity, runtime: String, block: suspend () -> Unit) {
        val names = listOf("ot-e2e-img-app" to APP, "ot-e2e-img-steady" to STEADY)
        fun rm() = names.joinToString(" ") { RemoteCommands.shellQuote(it.first) }
        vm.executeSshCommand(host, "$runtime rm -f ${rm()} >/dev/null 2>&1; true")
        try {
            for ((name, image) in names) {
                val out = vm.executeSshCommand(host, "$runtime create --name ${RemoteCommands.shellQuote(name)} ${RemoteCommands.shellQuote(image)} /f 2>&1 && echo OT-CREATED")
                assertTrue("run ./scripts/test-hosts.sh registry first: $out", out.contains("OT-CREATED"))
            }
            block()
        } finally {
            vm.executeSshCommand(host, "$runtime rm -f ${rm()} >/dev/null 2>&1; true")
        }
    }

    /** Containers → Images on [host]: checks now and reads each fixture image's line. Returns when it was checked. */
    private suspend fun checkImages(vm: AppViewModel, host: ServerEntity, runtime: String): Long {
        composeRule.runOnUiThread {
            vm.imageUpdateReports.remove(host.id)
            vm.selectedServerId = host.id
            vm.navigateTo(Screen.Infra)
            vm.activeInfraTab = 2
            vm.loadDocker()
        }
        await("images listed", 60_000) { !vm.dockerLoading && vm.dockerImages.any { it.runtime == runtime && it.repository == "$REG/omniterm/app" } }
        composeRule.waitForIdle()
        val header = composeRule.onNodeWithTag("images.updates", useUnmergedTree = true).printToString()
        assertTrue(header, "Image updates not checked yet" in header)
        composeRule.onNodeWithTag("images.updates.check").performClick()
        await("images checked", 90_000) { vm.imageUpdateReports[host.id] != null && host.id !in vm.imageUpdatesChecking }
        val report = vm.imageUpdateReports.getValue(host.id)
        assertEquals(null, report.problem)
        composeRule.waitForIdle()
        composeRule.onNode(hasText("1 image has an update"), useUnmergedTree = true).assertExists()
        composeRule.onNodeWithTag("images.updates.check").assertIsNotEnabled()
        val list = composeRule.onNode(hasScrollToNodeAction())
        for ((image, expected) in listOf(APP to "Update available", STEADY to "Up to date")) {
            val tag = "images.update.$runtime.${image.substringBeforeLast(':')}:${image.substringAfterLast(':')}"
            list.performScrollToNode(hasTestTag(tag))
            composeRule.onNodeWithTag(tag, useUnmergedTree = true).assertTextEquals(expected)
        }
        assertEquals(listOf(APP), report.updates.map { it.display })
        assertFalse("nothing was pulled", vm.dockerImages.count { it.runtime == runtime && it.repository == "$REG/omniterm/app" } > 1)
        return report.checkedAt
    }

    private fun model() = ViewModelProvider(composeRule.activity)[AppViewModel::class.java].also { vm ->
        composeRule.runOnUiThread { vm.isAppLocked = false }
    }

    private suspend fun await(what: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$what: not within ${timeoutMs}ms", e)
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val PODMAN_HOST = "E2E Podman Images"
        const val NOTE = "E2E image updates"
        const val REG = "omniterm-test-registry:5000"
        const val APP = "$REG/omniterm/app:latest"
        const val STEADY = "$REG/omniterm/steady:1"
    }
}
