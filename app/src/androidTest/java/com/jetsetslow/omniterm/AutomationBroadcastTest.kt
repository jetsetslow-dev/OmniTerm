package com.jetsetslow.omniterm

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Automation's broadcasts on a real device, with no host needed: a token OmniTerm does not know
 * gets no answer on either path; a known one is told why nothing ran, on the plain reply and on
 * Tasker's completion intent after a "pending" result code, as the plug-in protocol has it.
 */
class AutomationBroadcastTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val repository = AppRepository(AppDatabase.getDatabase(context))
    private val probe = AutomationProbe(context)
    private var scriptId = 0
    private var grantId = 0
    private val token = Automation.newToken()
    private var originalSwitch: String? = null

    @Before fun setUp(): Unit = runBlocking {
        originalSwitch = repository.getSetting(Automation.SETTING_ENABLED)
        repository.insertScript(QuickScriptEntity(emoji = "", name = SCRIPT, command = "uptime", color = "cyan"))
        scriptId = repository.getAllScripts().last { it.name == SCRIPT }.id
        // A host id nothing has, so no run can reach a network.
        grantId = repository.insertAutomationGrant(
            AutomationGrantEntity(scriptId = scriptId, serverIds = "987654", tokenHash = Automation.hash(token), label = "device test", createdAt = 1L),
        )
    }

    @After fun tearDown(): Unit = runBlocking {
        repository.deleteAutomationGrant(grantId)
        repository.getAllScripts().filter { it.name == SCRIPT }.forEach { repository.deleteScript(it) }
        repository.insertSetting(Automation.SETTING_ENABLED, originalSwitch ?: "false")
    }

    @Test fun anUnknownTokenGetsNoAnswerOnEitherPath() {
        repository.setSwitch(true)
        val unknown = Automation.newToken()
        assertNull("no plain reply", probe.awaitBroadcast(REPLY, QUIET_MS) { context.sendBroadcast(probe.plainRun(unknown)) })
        var code: Int? = null
        val completion = probe.awaitBroadcast(COMPLETE, QUIET_MS) { code = probe.fire(unknown) }
        assertEquals(Automation.Plugin.RESULT_FAILED, code)
        assertNull("no completion intent", completion)
    }

    @Test fun aKnownTokenIsToldAutomationIsOff() {
        repository.setSwitch(false)
        val reply = answer(probe.awaitBroadcast(REPLY, ANSWER_MS) { context.sendBroadcast(probe.plainRun(token)) })
        assertEquals(OFF, reply.getStringExtra(Automation.EXTRA_ERROR))
        assertEquals(1, reply.getIntExtra(Automation.EXTRA_EXIT, -9))
        assertEquals("r-42", reply.getStringExtra(Automation.EXTRA_REQUEST_ID))

        var code: Int? = null
        val completion = answer(probe.awaitBroadcast(COMPLETE, ANSWER_MS) { code = probe.fire(token) })
        assertEquals("the result follows on the completion intent", Automation.Plugin.RESULT_PENDING, code)
        assertEquals(Automation.Plugin.RESULT_FAILED, completion.getIntExtra(Automation.Plugin.EXTRA_RESULT_CODE, 0))
        val vars = completion.getBundleExtra(Automation.Plugin.EXTRA_VARIABLES)!!
        assertEquals(OFF, vars.getString("%errmsg"))
        assertEquals("1", vars.getString("%exit"))
    }

    @Test fun anOnTokenWhoseHostsAreGoneSaysSo() {
        repository.setSwitch(true)
        val reply = answer(probe.awaitBroadcast(REPLY, ANSWER_MS) { context.sendBroadcast(probe.plainRun(token)) })
        assertEquals("None of this token's hosts are saved in OmniTerm any more.", reply.getStringExtra(Automation.EXTRA_ERROR))
        assertNotNull("the grant was used", runBlocking { repository.automationGrantById(grantId) }?.lastUsedAt)
    }

    private fun AppRepository.setSwitch(on: Boolean) = runBlocking { insertSetting(Automation.SETTING_ENABLED, on.toString()) }

    private fun <T> answer(value: T?): T = value.also { assertNotNull("an answer came", it) }!!

    private companion object {
        const val SCRIPT = "automation broadcast fixture"
        const val OFF = "Automation is off in OmniTerm. Turn it on in Tools → Automation."
        const val REPLY = AutomationProbe.REPLY
        const val COMPLETE = AutomationProbe.COMPLETE
        const val ANSWER_MS = AutomationProbe.ANSWER_MS
        const val QUIET_MS = AutomationProbe.QUIET_MS
    }
}
