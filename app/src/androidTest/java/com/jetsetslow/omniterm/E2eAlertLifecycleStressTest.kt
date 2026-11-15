package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.alertNotificationId
import org.junit.Assert.assertTrue
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Opt-in physical lifecycle coverage for a real alert driven by disposable-lab telemetry. The suite
 * saves its own host at `network_host`, the address the phone's own network reaches the Docker
 * runtime fixture at (10.0.2.2 from the emulator), so that losing the network really takes the
 * host away; the shared lab host on 127.0.0.1 is carried by adb and never goes. Run with
 * `./scripts/test-hosts.sh suite E2eAlertLifecycleStressTest omniterm_e2e_alerts=yes network_host
 * port user pass`.
 */
class E2eAlertLifecycleStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun createFireNotifyMuteUnmuteAcknowledgeAndAutoRefreshSurviveChurn() {
        assumeTrue(E2eArgs.on("omniterm_e2e_alerts"))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val originalInterval = vm.telemetryIntervalMs / 1000L
        val originalAlertsEnabled = vm.alertsEnabled
        var offline: PhoneOffline? = null

        composeRule.runOnUiThread {
            composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        val host = runBlocking {
            E2eLabHosts.add(
                composeRule, vm, HOST, E2eArgs.require("network_host"), E2eArgs.get("port")?.toIntOrNull() ?: 2205,
                E2eArgs.require("user"), E2eArgs.require("pass"),
            ).also { E2eLabHosts.connectOnce(vm, it) }
        }

        try {
            // This opt-in lab test validates actual notifications.
            TestNotifications.allow()

            // Make reruns deterministic without disturbing non-E2E rules.
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(true)

            composeRule.runOnUiThread {
                vm.activeAlertsTab = 1
                vm.navigateTo(Screen.Alerts)
            }
            composeRule.onNodeWithContentDescription("Add").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("Add Alert Rule Trigger"))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithContentDescription("Choose hosts").performClick()
            composeRule.onNodeWithText(HOST).performClick()
            composeRule.onNodeWithText("Done").performClick()
            // Percentage validation intentionally rejects the old -1 sentinel. Memory usage is
            // always positive on the disposable host, so zero is both a real user-valid threshold
            // and a deterministic way to fire the rule without bypassing the visible form.
            composeRule.onNodeWithText("Memory Usage").performClick()
            val textFields = composeRule.onAllNodes(hasSetTextAction())
            textFields[0].performTextReplacement("0")
            textFields[1].performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }

            // The UI intentionally creates a five-minute rule. Shorten only this disposable rule so
            // the device test can exercise a genuine metrics refresh without wasting five minutes.
            val created = requireNotNull(vm.alertRules.value.find { it.notes == NOTE })
            vm.updateAlertRule(created.copy(triggerWindow = "0m"))
            composeRule.waitUntil(10_000) {
                vm.alertRules.value.find { it.id == created.id }?.triggerWindow == "0m"
            }

            vm.refreshServer(host.id)
            composeRule.waitUntil(30_000) {
                vm.activeAlerts.value.any { it.ruleId == created.id && it.serverId == host.id }
            }
            val firstAlert = requireNotNull(
                vm.activeAlerts.value.find { it.ruleId == created.id && it.serverId == host.id },
            )
            composeRule.waitUntil(10_000) { hasAlertNotification(created.id, host.id) }

            composeRule.runOnUiThread { vm.activeAlertsTab = 0 }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("Active (", substring = true))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("Active (", substring = true).performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("MUTE 1H"))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("MUTE 1H").performClick()
            composeRule.waitUntil(10_000) {
                vm.activeAlerts.value.find { it.id == firstAlert.id }?.mutedUntil?.let { it > System.currentTimeMillis() } == true
            }
            composeRule.waitUntil(10_000) { !hasAlertNotification(created.id, host.id) }
            composeRule.onNodeWithText("Muted incidents").fetchSemanticsNode()

            // Muted state and its recovery action must survive an Activity lifecycle recreation.
            composeRule.activityRule.scenario.recreate()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("UNMUTE"))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithText("UNMUTE").performClick()
            composeRule.waitUntil(10_000) {
                vm.activeAlerts.value.find { it.id == firstAlert.id }?.mutedUntil == 0L
            }
            composeRule.waitUntil(10_000) { hasAlertNotification(created.id, host.id) }

            // Losing the network (Wi-Fi and mobile data) takes the host away but must not discard
            // the incident. USB ADB stays available, and the finally block always turns the
            // networks back on even if an assertion fails.
            offline = PhoneOffline()
            vm.refreshServer(host.id)
            composeRule.waitUntil(20_000) {
                vm.servers.value.find { it.id == host.id }?.status == "offline"
            }
            assertTrue(vm.activeAlerts.value.any { it.id == firstAlert.id })

            offline?.close()
            offline = null
            Thread.sleep(3_000)
            vm.refreshServer(host.id)
            composeRule.waitUntil(40_000) {
                vm.servers.value.find { it.id == host.id }?.status == "online"
            }

            // Global disable/enable must keep database state but reconcile system notifications.
            vm.saveAlertsEnabled(false)
            composeRule.waitUntil(10_000) { !hasAlertNotification(created.id, host.id) }
            assertTrue(vm.activeAlerts.value.any { it.id == firstAlert.id })
            vm.saveAlertsEnabled(true)
            composeRule.waitUntil(10_000) { hasAlertNotification(created.id, host.id) }

            composeRule.onNodeWithText("ACKNOWLEDGE").performClick()
            composeRule.waitUntil(10_000) {
                vm.activeAlerts.value.find { it.id == firstAlert.id }?.acknowledged == true
            }
            composeRule.waitUntil(10_000) { !hasAlertNotification(created.id, host.id) }
            composeRule.runOnUiThread { vm.activeAlertsTab = 2 }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("ACKNOWLEDGED"))
                    .fetchSemanticsNodes().isNotEmpty()
            }

            // Updating closes the acknowledged incident and resets its breach timer. The restarted
            // five-second poller—not a direct per-host refresh—must then create a fresh incident.
            val currentRule = requireNotNull(vm.alertRules.value.find { it.id == created.id })
            vm.updateAlertRule(currentRule.copy(thresholdValue = 1f, triggerWindow = "0m"))
            composeRule.waitUntil(10_000) { vm.activeAlerts.value.none { it.ruleId == created.id } }
            vm.saveTelemetryInterval(5)
            vm.refreshAllServers()
            composeRule.waitUntil(30_000) {
                vm.activeAlerts.value.any { it.ruleId == created.id && it.serverId == host.id }
            }
            composeRule.runOnUiThread { vm.activeAlertsTab = 2 }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(androidx.compose.ui.test.hasText("RESOLVED"))
                    .fetchSemanticsNodes().isNotEmpty()
            }
        } finally {
            offline?.let {
                it.close()
                Thread.sleep(3_000)
            }
            vm.saveTelemetryInterval(originalInterval.toInt())
            vm.saveAlertsEnabled(originalAlertsEnabled)
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            runBlocking { E2eLabHosts.remove(composeRule, vm, HOST) }
        }
    }

    private fun hasAlertNotification(ruleId: Int, serverId: Int): Boolean =
        TestNotifications.posted(alertNotificationId(ruleId, serverId)) != null

    private companion object {
        const val HOST = "E2E alert lifecycle host"
        const val NOTE = "E2E alert lifecycle"
    }
}
