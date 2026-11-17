package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.automation.AlertRunbooks
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * An alert that fixes itself, on the repository's provisioned disposable host: a script check
 * fails and opens an incident, the rule's runbook runs on its own over SSH and repairs what the
 * check reads, the incident links to the run in Fleet's history, and the next checks close it.
 */
class E2eAlertRunbookTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aRunbookRunsOnItsOwnWhenTheIncidentOpensAndFixesIt() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_alert_runbook") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab
        AlertRunbooks.resetCooldowns()
        val (check, fix) = runBlocking {
            repository.getAllScripts().filter { it.name == CHECK || it.name == FIX }.forEach { repository.deleteScript(it) }
            repository.insertScript(QuickScriptEntity(emoji = "", name = CHECK, command = "test -f $DIR/ok", color = "cyan"))
            repository.insertScript(QuickScriptEntity(emoji = "", name = FIX, command = "mkdir -p $DIR && touch $DIR/ok && echo $MARKER", color = "cyan"))
            repository.getAllScripts().let { all -> all.single { it.name == CHECK } to all.single { it.name == FIX } }
        }
        fun ourRules() = runBlocking { repository.getAllRules().filter { it.notes == NOTE } }
        fun cleanHost() {
            composeRule.runOnUiThread { vm.runFleetBroadcast("rm -rf $DIR", listOf(host.id)) }
            composeRule.waitUntil(60_000) { vm.isBroadcastExecuting }
            composeRule.waitUntil(60_000) { !vm.isBroadcastExecuting }
            composeRule.runOnUiThread { vm.clearBroadcastOutputs() }
        }
        try {
            TestNotifications.allow()
            // The rules are read from the database: the model's list only follows it while a screen shows it.
            ourRules().forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { ourRules().isEmpty() }
            vm.saveAlertsEnabled(true)
            cleanHost()

            vm.addAlertRule(
                host.id, HostChecks.SCRIPT_CHECK, "/", 0f, "WARNING", "0m", NOTE, check.id.toString(),
                runbookScriptId = fix.id, runbookAuto = true, runbookNotify = RunNotify.ALWAYS,
            )
            composeRule.waitUntil(10_000) { ourRules().isNotEmpty() }
            val rule = ourRules().single()
            assertTrue(rule.runbookAuto)

            // The check fails, the incident opens, and its runbook runs on its own.
            poll(120_000, poke = { vm.refreshServer(host.id) }) {
                runBlocking { repository.getActiveAlerts().any { it.ruleId == rule.id && it.runbookRunKey != null } }
            }
            val runKey = runBlocking { repository.getActiveAlerts().single { it.ruleId == rule.id }.runbookRunKey!! }
            composeRule.waitUntil(120_000) {
                runBlocking { repository.fleetRunByKey(runKey)?.let { run -> repository.fleetRunHosts(run.id).none { it.status == BroadcastStatus.Running.name } } == true }
            }
            val run = runBlocking { repository.fleetRunByKey(runKey)!! }
            assertEquals(FleetRunHistory.SOURCE_ALERT, run.source)
            val ranOn = runBlocking { repository.fleetRunHosts(run.id).single() }
            assertEquals(ranOn.output, BroadcastStatus.Success.name, ranOn.status)
            assertTrue(ranOn.output, ranOn.output.contains(MARKER))

            // The incident says so, and opens the run.
            composeRule.runOnUiThread {
                vm.activeAlertsTab = 0
                vm.navigateTo(Screen.Alerts)
            }
            composeRule.waitUntil(10_000) { runCatching { composeRule.onNodeWithTag("alert.runbook.ran").assertExists() }.isSuccess }
            composeRule.onNodeWithTag("alert.runbook.ran").performClick()
            composeRule.waitUntil(10_000) { vm.currentScreen == Screen.Fleet && vm.fleetTabIndex == 1 }
            composeRule.waitUntil(10_000) { runCatching { composeRule.onNodeWithTag("fleet.history.details").assertExists() }.isSuccess }

            // What it fixed, the next checks see (a minute apart, two clean ones): the incident closes.
            poll(240_000, poke = { vm.refreshServer(host.id) }) {
                runBlocking { repository.getActiveAlerts().none { it.ruleId == rule.id } }
            }
        } finally {
            ourRules().forEach(vm::deleteAlertRule)
            runCatching { cleanHost() }
            runBlocking { repository.getAllScripts().filter { it.name == CHECK || it.name == FIX }.forEach { repository.deleteScript(it) } }
            AlertRunbooks.resetCooldowns()
            vm.saveAlertsEnabled(originalAlertsEnabled)
            composeRule.runOnUiThread {
                vm.activeAlertsTab = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    /** Asks [poke] every few seconds until [done], for checks that run on their own minute. */
    private fun poll(timeoutMs: Long, poke: () -> Unit, done: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!done()) {
            check(System.currentTimeMillis() < end) { "Timed out after $timeoutMs ms" }
            poke()
            Thread.sleep(5_000)
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NOTE = "E2E alert runbook"
        const val CHECK = "E2E runbook check"
        const val FIX = "E2E runbook fix"
        const val DIR = "/tmp/omniterm-e2e-runbook"
        const val MARKER = "omniterm-e2e-fixed"
    }
}
