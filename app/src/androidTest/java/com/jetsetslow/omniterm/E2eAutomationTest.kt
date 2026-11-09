package com.jetsetslow.omniterm

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Automation over real SSH to the repository's provisioned disposable host:
 * - Tools → Automation: the switch turns it on; a new token is made for a saved script and the
 *   host after the confirmation, and shown once.
 * - Tasker's fire broadcast with that token is answered "pending", and its completion intent
 *   brings back the host's output with %exit 0; a plain broadcast's reply brings back the same.
 * - Fleet's History keeps the run, marked as an automation's.
 * - Revoke on the screen stops the token: the next request gets no answer.
 */
class E2eAutomationTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aTokenMadeOnTheScreenRunsItsScriptAndCanBeRevoked() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_automation") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val probe = AutomationProbe(context)
        fun scripts(): List<QuickScriptEntity> = runBlocking { repository.getAllScripts() }
        fun grants(): List<AutomationGrantEntity> = runBlocking { repository.automationGrantsFlow.first() }.filter { it.label == LABEL }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val originalSwitch = vm.automationEnabled
        val originalScreen = vm.currentScreen
        var failure: Throwable? = null
        try {
            cleanUp(vm, repository, ::scripts, ::grants)
            vm.addQuickScript("LIN", SCRIPT, "echo e2e-automation-ran; uname -s", "cyan", false)
            composeRule.waitUntil(10_000) { scripts().any { it.name == SCRIPT } }
            if (vm.automationEnabled) vm.saveAutomationEnabled(false)

            composeRule.runOnUiThread { vm.navigateTo(Screen.Automation) }
            composeRule.onNodeWithTag("automation.enabled").performClick()
            composeRule.waitUntil(5_000) { vm.automationEnabled }
            composeRule.waitUntil(5_000) { runBlocking { repository.getSetting(Automation.SETTING_ENABLED) } == "true" }

            composeRule.onNodeWithContentDescription("Add").performClick()
            composeRule.onNodeWithTag("automation.new.make").assertIsNotEnabled()
            composeRule.onNodeWithTag("automation.new.label").performTextReplacement(LABEL)
            composeRule.onNodeWithTag("automation.new.script").performScrollTo().performClick()
            composeRule.onNodeWithTag("scriptPicker.search").performTextReplacement(SCRIPT)
            composeRule.onNodeWithText("LIN $SCRIPT").performClick()
            composeRule.onNodeWithContentDescription("Choose hosts").performClick()
            composeRule.onNodeWithText(HOST).performClick()
            composeRule.onNodeWithText("Done").performClick()
            composeRule.onNodeWithTag("automation.new.make").assertIsEnabled().performClick()
            // This emulator has no screen lock and App Lock is off, so the check is a plain question.
            composeRule.waitUntil(5_000) { composeRule.onAllNodes(hasTestTag("automation.new.confirm")).fetchSemanticsNodes().isNotEmpty() }
            assertTrue("nothing is made before the confirmation", grants().isEmpty())
            composeRule.onNodeWithTag("automation.new.confirm").performClick()
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasTestTag("automation.token")).fetchSemanticsNodes().isNotEmpty() }
            val token = composeRule.onNodeWithTag("automation.token").fetchSemanticsNode()
                .config[SemanticsProperties.Text].joinToString("") { it.text }
            assertTrue(token, Automation.looksLikeToken(token))
            val grant = grants().single()
            assertEquals(Automation.hash(token), grant.tokenHash)
            assertEquals(listOf(host.id), Automation.parseServerIds(grant.serverIds))
            composeRule.onNodeWithTag("automation.token.done").performClick()
            composeRule.onNodeWithTag("automation.token").assertDoesNotExist()
            composeRule.onNodeWithTag("automation.grant.${grant.id}").assertExists()

            // Tasker: "pending", then the result on the completion intent.
            var code: Int? = null
            val completion = probe.awaitBroadcast(AutomationProbe.COMPLETE, 120_000) { code = probe.fire(token) }
            assertEquals(Automation.Plugin.RESULT_PENDING, code)
            assertNotNull("Tasker hears back", completion)
            val vars = completion!!.getBundleExtra(Automation.Plugin.EXTRA_VARIABLES)!!
            assertEquals(vars.getString("%errmsg"), Automation.Plugin.RESULT_OK, completion.getIntExtra(Automation.Plugin.EXTRA_RESULT_CODE, 0))
            assertTrue(vars.getString("%output"), vars.getString("%output")!!.startsWith("e2e-automation-ran\nLinux"))
            assertEquals("0", vars.getString("%exit"))
            assertEquals("", vars.getString("%failed_hosts"))
            assertNull(vars.getString("%errmsg"))

            // A plain broadcast and its reply.
            val reply = probe.awaitBroadcast(AutomationProbe.REPLY, 120_000) { context.sendBroadcast(probe.plainRun(token)) }
            assertNotNull("the reply comes back", reply)
            assertEquals(reply!!.getStringExtra(Automation.EXTRA_ERROR), 0, reply.getIntExtra(Automation.EXTRA_EXIT, -9))
            assertTrue(reply.getStringExtra(Automation.EXTRA_OUTPUT)!!.contains("e2e-automation-ran"))
            assertEquals("r-42", reply.getStringExtra(Automation.EXTRA_REQUEST_ID))

            // Both runs are in Fleet's history.
            val runs = runBlocking { repository.fleetRunsFlow.first() }.filter { it.run.scriptName == SCRIPT }
            assertEquals(2, runs.size)
            runs.forEach { run ->
                assertEquals(FleetRunHistory.SOURCE_AUTOMATION, run.run.source)
                assertEquals("1 of 1 succeeded", "${run.succeeded} of ${run.hosts} succeeded")
            }
            assertNotNull(runBlocking { repository.automationGrantById(grant.id) }?.lastUsedAt)

            // Revoke: the token stops working.
            composeRule.onNodeWithTag("automation.grant.${grant.id}.revoke").performScrollTo().performClick()
            composeRule.onNodeWithTag("automation.revoke.confirm").performClick()
            composeRule.waitUntil(10_000) { grants().isEmpty() }
            composeRule.waitUntil(5_000) { composeRule.onAllNodes(hasTestTag("automation.grant.${grant.id}")).fetchSemanticsNodes().isEmpty() }
            assertNull(
                "a revoked token gets no answer",
                probe.awaitBroadcast(AutomationProbe.REPLY, AutomationProbe.QUIET_MS) { context.sendBroadcast(probe.plainRun(token)) },
            )
            assertTrue(composeRule.onAllNodes(hasText("No tokens yet", substring = true)).fetchSemanticsNodes().isNotEmpty())
        } catch (t: Throwable) {
            failure = t
            throw t
        } finally {
            try {
                cleanUp(vm, repository, ::scripts, ::grants)
                vm.saveAutomationEnabled(originalSwitch)
                composeRule.runOnUiThread { vm.navigateTo(originalScreen) }
            } catch (cleanup: Throwable) {
                failure?.addSuppressed(cleanup) ?: throw cleanup
            }
        }
    }

    private fun cleanUp(
        vm: AppViewModel,
        repository: AppRepository,
        scripts: () -> List<QuickScriptEntity>,
        grants: () -> List<AutomationGrantEntity>,
    ) {
        grants().forEach { vm.revokeAutomationGrant(it.id) }
        runBlocking { repository.fleetRunsFlow.first() }.filter { it.run.scriptName == SCRIPT }
            .forEach { runBlocking { repository.deleteFleetRun(it.run.id) } }
        scripts().filter { it.name == SCRIPT }.forEach(vm::deleteQuickScript)
        composeRule.waitUntil(10_000) { grants().isEmpty() && scripts().none { it.name == SCRIPT } }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val SCRIPT = "E2E automation"
        const val LABEL = "E2E Tasker"
    }
}
