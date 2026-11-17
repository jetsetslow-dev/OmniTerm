package com.jetsetslow.omniterm

import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.BackupChecks
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.alertNotificationId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import kotlin.math.abs

/**
 * Backup Age over real SSH to the repository's Docker runtime fixture, which holds a restic and a
 * Borg repository and a vzdump folder, each with backups from 2026-01-01 00:00 UTC (see
 * scripts/test-hosts/fixtures/runtime-host/start.sh). The repositories' password is passed as the
 * `backup_pass` argument, never committed: `./scripts/test-hosts.sh suite E2eBackupChecksTest
 * omniterm_e2e_backup_checks=yes backup_pass`.
 * - A restic rule made in the editor reads the old snapshot and alerts, naming it.
 * - Borg and vzdump rules with a high limit read the same age and stay quiet.
 * - A wrong password and a missing repository each alert with what went wrong.
 * - The password is stored encrypted, and a rule switched off in the list says so.
 */
class E2eBackupChecksTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun backupChecksReadTheFixtureRepositories() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_backup_checks") == "yes")
        val password = E2eArgs.require("backup_pass")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the Docker runtime fixture", (args.getString("port")?.toIntOrNull() ?: 2205), host.port)
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab
        fun rule(metric: String = HostChecks.BACKUP_AGE, match: (BackupChecks.Target) -> Boolean) =
            vm.alertRules.value.single { it.notes == NOTE && it.metricName == metric && BackupChecks.decode(it.target)?.let(match) == true }
        try {
            TestNotifications.allow()
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
            // The chip, not a rule card of that name behind the dialog.
            composeRule.onNode(hasText(HostChecks.BACKUP_AGE) and hasClickAction()).performScrollTo().performClick()
            composeRule.onNodeWithText("read on the host with the backup tool every 15 minutes", substring = true).performScrollTo()
            assertTrue("a fact that holds until fixed has no window", composeRule.onAllNodes(hasText("Trigger after breaching", substring = true)).fetchSemanticsNodes().isEmpty())
            composeRule.onNodeWithTag("alertRule.threshold").performScrollTo()
            assertTrue("26 hours by default", composeRule.onAllNodes(hasTestTag("alertRule.threshold") and hasText("26")).fetchSemanticsNodes().isNotEmpty())
            composeRule.onNodeWithTag("alertRule.backup.repository").performScrollTo().performTextReplacement("$BACKUPS/restic")
            composeRule.onNodeWithTag("alertRule.backup.password").performScrollTo().performTextReplacement(password)
            composeRule.onNodeWithText("Notes (optional)", substring = true).performScrollTo().performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }
            val restic = rule { it.tool == BackupChecks.Tool.RESTIC }
            assertEquals(BackupChecks.Target(BackupChecks.Tool.RESTIC, "$BACKUPS/restic"), BackupChecks.decode(restic.target))
            assertEquals(password, restic.secret)
            assertEquals(26f, restic.thresholdValue)
            val stored = kotlinx.coroutines.runBlocking { AppDatabase.getDatabase(context).alertRuleDao().getAllRules() }.single { it.id == restic.id }
            assertTrue("stored encrypted", stored.secret.startsWith("enc:v1:") && password !in stored.secret)

            // A limit no fixture backup reaches: these only have to read.
            fun add(target: BackupChecks.Target, threshold: Float, secret: String = password) = vm.addAlertRule(
                host.id, HostChecks.BACKUP_AGE, "/", threshold, "WARNING", "0m", NOTE,
                target = BackupChecks.encode(target), secret = secret,
            )
            add(BackupChecks.Target(BackupChecks.Tool.BORG, "$BACKUPS/borg", "fixture-*"), 1_000_000f)
            add(BackupChecks.Target(BackupChecks.Tool.VZDUMP, "$BACKUPS/dump", "101"), 1_000_000f, secret = "")
            add(BackupChecks.Target(BackupChecks.Tool.RESTIC, "$BACKUPS/restic", "elsewhere"), 1_000_000f, secret = "wrong-$password")
            add(BackupChecks.Target(BackupChecks.Tool.BORG, "$BACKUPS/missing"), 1_000_000f)
            composeRule.waitUntil(10_000) { vm.alertRules.value.count { it.notes == NOTE } == 5 }
            val borg = rule { it.tool == BackupChecks.Tool.BORG && it.filter.isNotEmpty() }
            val vzdump = rule { it.tool == BackupChecks.Tool.VZDUMP }
            val wrong = rule { it.tool == BackupChecks.Tool.RESTIC && it.filter == "elsewhere" }
            val missing = rule { it.tool == BackupChecks.Tool.BORG && it.filter.isEmpty() }
            val all = listOf(restic, borg, vzdump, wrong, missing)

            vm.refreshServer(host.id)
            composeRule.waitUntil(120_000) { all.all { vm.hostCheckResults[it.id to host.id] != null } }
            val expectedHours = (System.currentTimeMillis() / 1000 - JAN_1) / 3600f
            fun reading(id: Int) = vm.hostCheckResults.getValue(id to host.id)
            fun near(expected: Float, id: Int) {
                val value = reading(id).value
                assertTrue("${reading(id).summary}: expected about $expected h", value != null && abs(value - expected) < 1.5f)
            }
            near(expectedHours, restic.id)
            near(expectedHours, borg.id)
            near(expectedHours + 7 * 24, vzdump.id)
            assertTrue(reading(borg.id).summary, reading(borg.id).summary.endsWith("(archive fixture-2026-01-01)"))
            assertTrue(reading(vzdump.id).summary, reading(vzdump.id).summary.endsWith("(vzdump-lxc-101-2025_12_25-00_00_00.tar.zst)"))
            assertEquals(BackupChecks.AUTH_FAILED, reading(wrong.id).value)
            assertEquals(BackupChecks.REPO_MISSING, reading(missing.id).value)

            composeRule.waitUntil(30_000) {
                listOf(restic, wrong, missing).all { r -> vm.activeAlerts.value.any { it.ruleId == r.id && it.serverId == host.id } }
            }
            assertTrue("a backup within its limit is quiet", vm.activeAlerts.value.none { it.ruleId == borg.id || it.ruleId == vzdump.id })
            composeRule.waitUntil(10_000) { notificationText(restic.id, host.id)?.startsWith("Newest restic backup is ") == true }
            assertTrue(notificationText(restic.id, host.id)!!, notificationText(restic.id, host.id)!!.endsWith("old (limit 26 h): snapshot ${reading(restic.id).summary.substringAfter("(snapshot ").substringBefore(')')}"))
            composeRule.waitUntil(10_000) { notificationText(wrong.id, host.id) == "restic refused the password for $BACKUPS/restic" }
            composeRule.waitUntil(10_000) { notificationText(missing.id, host.id)?.startsWith("Borg repository not found: $BACKUPS/missing") == true }
            assertFalse("the password is in no notification", listOf(restic, wrong, missing).any { password in notificationText(it.id, host.id).orEmpty() })
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("Newest backup", substring = true)).fetchSemanticsNodes().isNotEmpty()
            }

            // Switched off in the list: it says so, and its incident closes.
            val ruleList = composeRule.onNode(hasScrollToNodeAction() and hasAnyDescendant(hasText("Newest backup", substring = true)))
            ruleList.performScrollToNode(hasTestTag("alertRule.enabled.${wrong.id}"))
            composeRule.onNodeWithTag("alertRule.enabled.${wrong.id}").performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.single { it.id == wrong.id }.enabled.not() }
            composeRule.waitUntil(10_000) { vm.activeAlerts.value.none { it.ruleId == wrong.id } }
            ruleList.performScrollToNode(hasText("Off: not checked"))
            assertNull(vm.hostCheckResults[wrong.id to host.id])
        } finally {
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            // Deleting runs in the model's scope, which ends with the activity: wait for it.
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(originalAlertsEnabled)
            composeRule.runOnUiThread {
                vm.activeAlertsTab = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    private fun notificationText(ruleId: Int, serverId: Int): String? = TestNotifications.text(alertNotificationId(ruleId, serverId))

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NOTE = "E2E backup checks"
        const val BACKUPS = "/home/omniterm/backups"
        const val JAN_1 = 1_767_225_600L
    }
}
