package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationManager
import android.os.Build
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetRunSummary
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ScriptChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.NotificationLinks
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.flow.first
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Script Check and runbooks over real SSH to the repository's provisioned disposable host:
 * - In the rule editor, a script that looks destructive is refused; a reading one is picked as the
 *   check, and another script as the runbook.
 * - The check script exits 3 on the host: the rule list reads "exit 3" with its output, an
 *   incident opens, and the notification names the script and offers "Run <runbook>".
 * - That action's link opens Fleet with the runbook and asks for the usual confirmation; it runs
 *   only once Run is tapped, and its output comes back from the host.
 * - Fleet's History keeps that run, marked as a runbook's, with the host's output; "Use again"
 *   puts its script and host back into Broadcast without running it, and Delete removes it.
 */
class E2eScriptCheckTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aScriptCheckAlertsAndItsRunbookRunsOnlyAfterConfirmation() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_script_check") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // quickScripts only follows the database while a screen collects it; read the repository.
        val repository = AppRepository(AppDatabase.getDatabase(context))
        fun scripts(): List<QuickScriptEntity> = kotlinx.coroutines.runBlocking { repository.getAllScripts() }
        fun runbookRuns(): List<FleetRunSummary> =
            kotlinx.coroutines.runBlocking { repository.fleetRunsFlow.first() }.filter { it.run.scriptName == RUNBOOK }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab
        val originalFleetTab = vm.fleetTabIndex
        val originalCommand = vm.broadcastCommandText
        val originalPreset = vm.broadcastPreset
        val originalTargets = vm.broadcastTargetServerIds.toList()
        val originalMode = vm.broadcastTargetMode
        val restoreLaunchIntent = composeRule.keepLaunchIntent()
        var failure: Throwable? = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                instrumentation.uiAutomation.executeShellCommand(
                    "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS",
                ).close()
            }
            cleanUp(vm, repository, ::scripts)
            vm.addQuickScript("LIN", CHECK, "echo 'e2e check says no'; exit 3", "cyan", false)
            vm.addQuickScript("LIN", RUNBOOK, "echo e2e-runbook-ran", "cyan", false)
            vm.addQuickScript("LIN", DESTRUCTIVE, "rm -rf /tmp/e2e-script-check-nothing", "cyan", false)
            composeRule.waitUntil(10_000) { scripts().count { it.name in NAMES } == 3 }
            val check = scripts().single { it.name == CHECK }
            val runbook = scripts().single { it.name == RUNBOOK }
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
            composeRule.onNodeWithText(HostChecks.SCRIPT_CHECK).performScrollTo().performClick()
            composeRule.onNodeWithText("Runs a saved script on the host once a minute", substring = true).performScrollTo()

            pickScript("alertRule.script", DESTRUCTIVE)
            composeRule.onNodeWithTag("alertRule.script.note").performScrollTo()
            composeRule.onNodeWithText("looks destructive (recursive/forced delete)", substring = true).assertExists()
            composeRule.onNodeWithText("Confirm").assertIsNotEnabled()

            pickScript("alertRule.script", CHECK)
            // A reading script has nothing against it (the hint above mentions "looks destructive" too).
            composeRule.onNodeWithTag("alertRule.script.note").assertDoesNotExist()
            pickScript("alertRule.runbook", RUNBOOK)
            val fields = composeRule.onAllNodes(hasSetTextAction())
            assertEquals("only the notes field: a script check asks for no threshold", 1, fields.fetchSemanticsNodes().size)
            fields[0].performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").assertIsEnabled().performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }
            val saved = vm.alertRules.value.single { it.notes == NOTE }
            assertEquals(HostChecks.SCRIPT_CHECK, saved.metricName)
            assertEquals(check.id, ScriptChecks.scriptId(saved))
            assertEquals(runbook.id, saved.runbookScriptId)
            assertEquals("2m", saved.triggerWindow)
            composeRule.onNodeWithText("Script: $CHECK").assertExists()
            composeRule.onNodeWithText("Runbook: $RUNBOOK").assertExists()

            // Alert on the first failure rather than wait out the two-minute window.
            vm.updateAlertRule(saved.copy(triggerWindow = "0m"))
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.id == saved.id && it.triggerWindow == "0m" } }
            vm.refreshServer(host.id)
            composeRule.waitUntil(120_000) { vm.activeAlerts.value.any { it.ruleId == saved.id && it.serverId == host.id } }
            assertEquals("exit 3: e2e check says no", vm.hostCheckResults.getValue(saved.id to host.id).summary)
            assertEquals(3f, vm.activeAlerts.value.single { it.ruleId == saved.id }.currentValue)
            composeRule.waitUntil(10_000) { notification(saved.id, host.id) != null }
            val posted = notification(saved.id, host.id)!!
            assertEquals("$CHECK failed (exit 3): e2e check says no", posted.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
            val action = posted.actions?.singleOrNull()
            assertNotNull("the notification offers the runbook", action)
            assertEquals("Run $RUNBOOK", action!!.title.toString())
            // Its heads-up would sit over the top of the screen while Fleet is tapped below.
            context.getSystemService(NotificationManager::class.java)?.cancel("alert_${saved.id}_${host.id}".hashCode())

            assertEquals(context.packageName, action.actionIntent.creatorPackage)
            // The action's own link, delivered to this activity as a tap does when OmniTerm's task
            // is on top. (Sent as is, it starts a second activity in a task of its own, because the
            // test hosts this one in the test package's task.)
            composeRule.runOnUiThread {
                composeRule.activity.startActivity(
                    android.content.Intent(context, MainActivity::class.java)
                        .setData(android.net.Uri.parse(NotificationLinks.runbook(saved.id, host.id)))
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
            }
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodes(hasText("$ echo e2e-runbook-ran", substring = true) and hasAnyAncestor(isDialog()))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            assertEquals(Screen.Fleet, vm.currentScreen)
            assertEquals(listOf(host.id), vm.broadcastTargetServerIds.toList())
            assertTrue("nothing ran before the confirmation", vm.broadcastResults.none { it.output.contains("e2e-runbook-ran") })
            composeRule.onNode(hasText("Run") and hasAnyAncestor(isDialog())).performClick()
            composeRule.waitUntil(60_000) {
                vm.broadcastResults.any { it.serverId == host.id && it.output.contains("e2e-runbook-ran") }
            }

            // The run is in the history once it ends, marked as the runbook's.
            composeRule.waitUntil(60_000) { !vm.isBroadcastExecuting && runbookRuns().isNotEmpty() }
            val kept = runbookRuns().single()
            assertEquals(FleetRunHistory.SOURCE_RUNBOOK, kept.run.source)
            assertEquals("echo e2e-runbook-ran", kept.run.command)
            assertEquals(1, kept.hosts)
            assertEquals(1, kept.succeeded)
            composeRule.onNodeWithTag("fleet.history").performClick()
            composeRule.onNodeWithTag("fleet.history.run.${kept.run.id}").assertExists()
            composeRule.onNode(hasText("1 of 1 succeeded · Runbook", substring = true) and hasAnyAncestor(isDialog())).assertExists()
            composeRule.onNodeWithTag("fleet.history.run.${kept.run.id}").performClick()
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("$ echo e2e-runbook-ran") and hasAnyAncestor(isDialog())).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNode(hasText(HOST) and hasAnyAncestor(isDialog())).performClick()
            composeRule.waitUntil(10_000) {
                // The command line, and now the host's output under it.
                composeRule.onAllNodes(hasText("e2e-runbook-ran", substring = true) and hasAnyAncestor(isDialog()))
                    .fetchSemanticsNodes().size >= 2
            }
            composeRule.runOnUiThread {
                vm.broadcastCommandText = ""
                vm.broadcastPreset = null
                vm.broadcastTargetServerIds.clear()
            }
            val ranBefore = runbookRuns().size
            // Use again waits for the run's hosts and for no broadcast to be running: a tap a frame
            // early would land on a disabled button and do nothing.
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasTestTag("fleet.history.load") and isEnabled()).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("fleet.history.load").performClick()
            composeRule.waitUntil(10_000) { vm.broadcastCommandText == "echo e2e-runbook-ran" }
            assertEquals(RUNBOOK, vm.broadcastPreset?.name)
            assertEquals(listOf(host.id), vm.broadcastTargetServerIds.toList())
            composeRule.onNodeWithTag("fleet.history.details").assertDoesNotExist()
            assertTrue("Use again does not run it", !vm.isBroadcastExecuting && runbookRuns().size == ranBefore)

            composeRule.onNodeWithTag("fleet.history").performClick()
            composeRule.onNodeWithTag("fleet.history.run.${kept.run.id}").performClick()
            composeRule.onNodeWithTag("fleet.history.delete").performClick()
            composeRule.onNodeWithTag("fleet.history.delete.confirm").performClick()
            composeRule.waitUntil(10_000) { runbookRuns().isEmpty() }
            composeRule.onNodeWithTag("fleet.history.run.${kept.run.id}").assertDoesNotExist()
            composeRule.onNode(hasText("Close") and hasAnyAncestor(isDialog())).performClick()
        } catch (e: Throwable) {
            failure = e
            logWindows(vm)
            throw e
        } finally {
            // The activity's own intent first: without it the rule cannot close the activity, and
            // a later cleanup failure would hide why the test failed.
            restoreLaunchIntent()
            composeRule.runOnUiThread {
                vm.activeAlertsTab = originalTab
                vm.fleetTabIndex = originalFleetTab
                vm.broadcastCommandText = originalCommand
                vm.broadcastPreset = originalPreset
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(originalTargets)
                vm.broadcastTargetMode = originalMode
                vm.navigateTo(originalScreen)
            }
            val cleanup = runCatching {
                runbookRuns().forEach { kotlinx.coroutines.runBlocking { repository.deleteFleetRun(it.run.id) } }
                cleanUp(vm, repository, ::scripts)
                vm.saveAlertsEnabled(originalAlertsEnabled)
            }
            cleanup.exceptionOrNull()?.let { problem -> failure?.addSuppressed(problem) ?: throw problem }
        }
    }

    /**
     * Which window had focus, and whether the keyboard was up, when the test failed: the app
     * blocks screenshots, so this is what says whether a tap could have reached it.
     */
    private fun logWindows(vm: AppViewModel) {
        runCatching {
            val windows = DeviceShell.run("dumpsys window windows").lineSequence()
                .filter { it.contains("mCurrentFocus") || it.contains("mFocusedApp") || it.contains("imeLayeringTarget") || it.contains("Window #") }
            val ime = DeviceShell.run("dumpsys input_method").lineSequence().filter { it.contains("mInputShown") || it.contains("isInputViewShown") }
            android.util.Log.w("E2eScriptCheckTest", "executing=${vm.isBroadcastExecuting} command='${vm.broadcastCommandText}'")
            (windows + ime).forEach { android.util.Log.w("E2eScriptCheckTest", it.trim()) }
        }
    }

    /** Opens the script field tagged [tag] and picks [name] in the shared script picker. */
    private fun pickScript(tag: String, name: String) {
        composeRule.onNodeWithTag(tag).performScrollTo().performClick()
        composeRule.onNodeWithTag("scriptPicker.search").performTextReplacement(name)
        composeRule.onNodeWithText("LIN $name").performClick()
        composeRule.waitUntil(5_000) { composeRule.onAllNodes(hasText("LIN $name")).fetchSemanticsNodes().size == 1 }
    }

    // The rules come from the repository too: alertRules, like quickScripts, only follows the
    // database while a screen collects it.
    private fun cleanUp(vm: AppViewModel, repository: AppRepository, scripts: () -> List<QuickScriptEntity>) {
        fun ours() = kotlinx.coroutines.runBlocking { repository.getAllRules() }.filter { it.notes == NOTE }
        ours().forEach(vm::deleteAlertRule)
        scripts().filter { it.name in NAMES }.forEach(vm::deleteQuickScript)
        composeRule.waitUntil(10_000) { ours().isEmpty() && scripts().none { it.name in NAMES } }
    }

    private fun notification(ruleId: Int, serverId: Int): Notification? {
        val manager = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(NotificationManager::class.java)
        val expectedId = "alert_${ruleId}_$serverId".hashCode()
        return manager?.activeNotifications?.firstOrNull { it.id == expectedId }?.notification
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NOTE = "E2E script check"
        const val CHECK = "E2E check fails"
        const val RUNBOOK = "E2E runbook"
        const val DESTRUCTIVE = "E2E prune"
        val NAMES = setOf(CHECK, RUNBOOK, DESTRUCTIVE)
    }
}
