package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationManager
import android.os.Build
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Host checks over real SSH to the repository's provisioned disposable host (Alpine, with the
 * Docker CLI and its fixture engine), and Host Offline on a copy of it pointed at a closed port:
 * - Reboot Required, made in the editor, asks for no threshold or window, and on Alpine reads
 *   "Not available on this host" in the rule list.
 * - Container Problems reads a number, because the fixture's Docker answers.
 * - The copy opens a Host Offline incident and posts "Not reachable over SSH".
 */
class E2eHostChecksTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun hostChecksReadTheFixtureAndAnUnreachableCopyAlerts() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_host_checks") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertEquals("Use the repository fixture port", (args.getString("port")?.toIntOrNull() ?: 2205), host.port)
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab
        // Port 1 on the device refuses at once: an unreachable host without waiting on a timeout.
        val copyId = kotlinx.coroutines.runBlocking {
            repository.insertServer(host.copy(id = 0, name = COPY, host = "127.0.0.1", port = 1)).toInt()
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                instrumentation.uiAutomation.executeShellCommand(
                    "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS",
                ).close()
            }
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(true)

            composeRule.runOnUiThread {
                vm.activeAlertsTab = 1
                vm.navigateTo(Screen.Alerts)
            }
            composeRule.onNodeWithContentDescription("Add").performClick()
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasText("Add Alert Rule Trigger")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithContentDescription("Choose hosts").performClick()
            composeRule.onNodeWithText(HOST).performClick()
            composeRule.onNodeWithText("Done").performClick()
            composeRule.onNodeWithText(HostChecks.REBOOT_REQUIRED).performScrollTo().performClick()
            composeRule.onNodeWithText("Alerts when installed updates need a reboot", substring = true).performScrollTo()
            assertTrue("no threshold for a yes-or-no check", composeRule.onAllNodes(hasText("Threshold value", substring = true)).fetchSemanticsNodes().isEmpty())
            assertTrue("no window for a fact that holds until fixed", composeRule.onAllNodes(hasText("Trigger after breaching", substring = true)).fetchSemanticsNodes().isEmpty())
            val fields = composeRule.onAllNodes(hasSetTextAction())
            assertEquals("only the notes field is left", 1, fields.fetchSemanticsNodes().size)
            fields[0].performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }
            val reboot = vm.alertRules.value.single { it.notes == NOTE }
            assertEquals(HostChecks.REBOOT_REQUIRED, reboot.metricName)
            assertEquals(0f, reboot.thresholdValue)
            assertEquals("0m", reboot.triggerWindow)

            // A threshold no fixture reaches: this rule only has to read.
            vm.addAlertRule(host.id, HostChecks.CONTAINER_PROBLEMS, "/", 1000f, "WARNING", "5m", NOTE)
            vm.addAlertRule(copyId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m", NOTE)
            composeRule.waitUntil(10_000) { vm.alertRules.value.count { it.notes == NOTE } == 3 }
            val containers = vm.alertRules.value.single { it.notes == NOTE && it.metricName == HostChecks.CONTAINER_PROBLEMS }
            val offline = vm.alertRules.value.single { it.notes == NOTE && it.metricName == HostChecks.HOST_OFFLINE }

            vm.refreshServer(host.id)
            vm.refreshServer(copyId)
            composeRule.waitUntil(90_000) {
                vm.hostCheckResults[reboot.id to host.id] != null && vm.hostCheckResults[containers.id to host.id] != null
            }
            val rebootReading = vm.hostCheckResults.getValue(reboot.id to host.id)
            assertNull("Alpine has no way to tell", rebootReading.value)
            assertEquals("Not available on this host", rebootReading.summary)
            assertNotNull("the fixture's Docker answers", vm.hostCheckResults.getValue(containers.id to host.id).value)
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("Not available on this host")).fetchSemanticsNodes().isNotEmpty()
            }

            composeRule.waitUntil(60_000) { vm.activeAlerts.value.any { it.ruleId == offline.id && it.serverId == copyId } }
            composeRule.waitUntil(10_000) { notificationText(offline.id, copyId) == "Not reachable over SSH" }
            assertTrue(vm.activeAlerts.value.none { it.ruleId == containers.id || it.ruleId == reboot.id })
        } finally {
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            kotlinx.coroutines.runBlocking { repository.deleteServerAndDependents(copyId) }
            vm.saveAlertsEnabled(originalAlertsEnabled)
            composeRule.runOnUiThread {
                vm.activeAlertsTab = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    private fun notificationText(ruleId: Int, serverId: Int): String? {
        val manager = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(NotificationManager::class.java)
        val expectedId = "alert_${ruleId}_$serverId".hashCode()
        return manager?.activeNotifications?.firstOrNull { it.id == expectedId }
            ?.notification?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val COPY = "E2E Offline Copy"
        const val NOTE = "E2E host checks"
    }
}
