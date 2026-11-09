package com.jetsetslow.omniterm

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.automation.TaskerEditActivity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * The Tasker/Locale plug-in's edit screen: it checks a pasted token, says what it runs and which
 * app will keep it, and only then saves the token in the plug-in bundle, asking Tasker to wait for
 * the result and naming the variables it sets.
 */
class TaskerEditActivityTest {
    @get:Rule val composeRule = createEmptyComposeRule()

    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val repository = AppRepository(AppDatabase.getDatabase(context))
    private val token = Automation.newToken()
    private var grantId = 0
    private var serverId = 0

    @Before fun setUp(): Unit = runBlocking {
        repository.insertScript(QuickScriptEntity(emoji = "", name = SCRIPT, command = "uptime", color = "cyan"))
        val scriptId = repository.getAllScripts().last { it.name == SCRIPT }.id
        serverId = repository.insertServer(ServerEntity(name = HOST, host = "192.0.2.10", username = "fixture")).toInt()
        grantId = repository.insertAutomationGrant(
            AutomationGrantEntity(scriptId = scriptId, serverIds = "$serverId", tokenHash = Automation.hash(token), label = "Tasker", createdAt = 1L),
        )
    }

    @After fun tearDown(): Unit = runBlocking {
        repository.deleteAutomationGrant(grantId)
        repository.getAllScripts().filter { it.name == SCRIPT }.forEach { repository.deleteScript(it) }
        repository.getServerById(serverId)?.let { repository.deleteServer(it) }
    }

    @Test fun aPastedTokenIsCheckedThenSavedForTheCallingApp() {
        val edit = Intent(Automation.Plugin.ACTION_EDIT_SETTING)
            .setClassName(context, TaskerEditActivity::class.java.name)
            .putExtra(
                Automation.Plugin.EXTRA_HOST_CAPABILITIES,
                Automation.Plugin.CAPABILITY_SYNCHRONOUS or Automation.Plugin.CAPABILITY_RELEVANT_VARIABLES,
            )
        ActivityScenario.launchActivityForResult<TaskerEditActivity>(edit).use { scenario ->
            composeRule.onNodeWithTag("automation.plugin.caller").assertExists()
            composeRule.onNodeWithTag("automation.plugin.save").assertIsNotEnabled()

            composeRule.onNodeWithTag("automation.plugin.token").performTextReplacement(Automation.newToken())
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasTestTag("automation.plugin.unknown")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("automation.plugin.save").assertIsNotEnabled()

            composeRule.onNodeWithTag("automation.plugin.token").performTextReplacement(token)
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasTestTag("automation.plugin.grant")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("automation.plugin.grant").assertExists()
            composeRule.onNodeWithTag("automation.plugin.save").assertIsEnabled().performClick()

            val result = scenario.result
            assertEquals(Activity.RESULT_OK, result.resultCode)
            val data = result.resultData
            assertEquals(token, Automation.Plugin.tokenFrom(data.getBundleExtra(Automation.Plugin.EXTRA_BUNDLE)))
            assertEquals("$SCRIPT on $HOST", data.getStringExtra(Automation.Plugin.EXTRA_BLURB))
            assertEquals(Automation.TASKER_TIMEOUT_MS, data.getIntExtra(Automation.Plugin.EXTRA_REQUESTED_TIMEOUT, 0))
            val variables = data.getStringArrayExtra(Automation.Plugin.EXTRA_RELEVANT_VARIABLES)!!.map { it.substringBefore('\n') }
            assertEquals(listOf("%output", "%exit", "%failed_hosts"), variables)
        }
    }

    @Test fun anAppNotWaitingForAResultGetsNothingToSave() {
        val edit = Intent(Automation.Plugin.ACTION_EDIT_SETTING)
            .setClassName(context, TaskerEditActivity::class.java.name)
            .putExtra(Automation.Plugin.EXTRA_BUNDLE, Automation.Plugin.bundleFor(token))
        ActivityScenario.launch<TaskerEditActivity>(edit).use {
            // The saved token is checked on opening, and still cannot be saved anywhere.
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasTestTag("automation.plugin.grant")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("automation.plugin.caller").assertDoesNotExist()
            composeRule.onNodeWithTag("automation.plugin.save").assertIsNotEnabled()
        }
    }

    private companion object {
        const val SCRIPT = "tasker edit fixture"
        const val HOST = "tasker-edit-host"
    }
}
