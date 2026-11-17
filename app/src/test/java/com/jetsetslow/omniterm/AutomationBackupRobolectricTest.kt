package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.AutomationUseEntity
import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupHistory
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.FleetTargets
import org.json.JSONArray
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * A backup carries automation's tokens (user, Nov 9) but never its switch, either way: restoring a
 * backup on another phone leaves automation off, so no other app runs scripts there until the user
 * turns it on.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class AutomationBackupRobolectricTest {
    // The test host has a password, which the repository encrypts with the Keystore.
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aBackupBringsTheTokensBackWithAutomationOff() = withModel { model, main, repo ->
        val host = repo.insertServer(ServerEntity(name = "web", host = "web.lan", port = 22, username = "admin", authType = "password", authPassword = "pw")).toInt()
        repo.insertScript(QuickScriptEntity(emoji = "", name = "Uptime", command = "uptime", color = "cyan"))
        val script = repo.getAllScripts().single { it.name == "Uptime" }
        val token = Automation.hash(Automation.newToken())
        val grant = repo.insertAutomationGrant(
            AutomationGrantEntity(
                scriptId = script.id, serverIds = host.toString(), tokenHash = token, label = "Tasker", createdAt = 1L,
                notify = RunNotify.ALWAYS,
            ),
        )
        repo.recordAutomationUse(AutomationUseEntity(grantId = grant, at = 5L, outcome = UseOutcome.OK, detail = "web", runKey = "automation-run-a"))
        repo.recordAutomationUse(AutomationUseEntity(grantId = grant, at = 6L, outcome = UseOutcome.REFUSED, detail = "Automation is off"))
        repo.insertSetting(McpSettings.TOKEN_HASH, "b".repeat(64))
        repo.insertSetting(McpSettings.NOTIFY, RunNotify.OFF)
        repo.recordMcpCall(
            McpCallEntity(at = 7L, client = "Claude Code", tool = "run_script", outcome = UseOutcome.FAILED, detail = "web: Exited with status 1.", runKey = "automation-run-b"),
        )
        repo.insertSetting(Automation.SETTING_ENABLED, "true")
        repo.insertSetting(OTHER_SETTING, "kept")
        // A schedule on the host, and one on a tag; both are on, and run nightly at 02:30.
        repo.saveFleetSchedule(
            FleetScheduleEntity(
                name = "Nightly", scriptId = script.id, mode = "Servers", serverIds = "[$host]",
                repeat = FleetScheduleTiming.WEEKLY, dayOfWeek = 6, minuteOfDay = 150, notify = RunNotify.ALWAYS, createdAt = 3L,
                nextRunAt = 9L, lastRunAt = 8L, lastOutcome = UseOutcome.OK, lastRunKey = "schedule-run-a",
            ),
        )
        repo.saveFleetSchedule(FleetScheduleEntity(name = "Tagged", scriptId = script.id, mode = "Tags", tags = "[\"prod\"]", repeat = FleetScheduleTiming.EVERY, everyMinutes = 30))

        val uri = Uri.parse("content://backup-fixture/automation.json")
        val bytes = ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val exported = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.exportBackup(uri, PASSPHRASE, application, EVERYTHING) { ok, message -> exported.complete(ok to message) } }
        val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
        assertTrue(exportMessage, exportOk)
        waitWhileOnMain(main) { model.backupExportRunning }

        withContext(Dispatchers.IO) { AppDatabase.getDatabase(application).clearAllTables() }
        restore(model, main, bytes.toString(Charsets.UTF_8))

        assertEquals("other settings are restored", "kept", repo.getSetting(OTHER_SETTING))
        assertEquals("a restore leaves automation off", "false", repo.getSetting(Automation.SETTING_ENABLED))
        assertEquals("the token comes back", listOf(token), repo.automationGrantsFlow.first().map { it.tokenHash })
        assertEquals("the script itself is", listOf("Uptime"), repo.getAllScripts().map { it.name }.filter { it == "Uptime" })
        val restored = repo.automationGrantsFlow.first().single()
        assertEquals("the token keeps its notification choice", RunNotify.ALWAYS, restored.notify)
        val uses = { runBlocking { repo.automationUsesFlow(restored.id).first().map { Triple(it.outcome, it.detail, it.runKey) } } }
        assertEquals(
            "and its uses, each still opening its run",
            listOf(Triple(UseOutcome.REFUSED, "Automation is off", null), Triple(UseOutcome.OK, "web", "automation-run-a")),
            uses(),
        )
        assertEquals("the AI assistant keeps its choice", RunNotify.OFF, repo.getSetting(McpSettings.NOTIFY))
        assertEquals("a call still opens its run", "automation-run-b", repo.mcpCallsFlow.first().single().runKey)

        val schedules = repo.fleetSchedules().associateBy { it.name }
        assertEquals(setOf("Nightly", "Tagged"), schedules.keys)
        assertTrue("schedules come back paused", schedules.values.none { it.enabled || it.nextRunAt != null })
        val nightly = schedules.getValue("Nightly")
        assertEquals("on the restored script", restored.scriptId, nightly.scriptId)
        assertEquals("and the restored host", repo.getAllServers().filter { it.name == "web" }.map { it.id }, FleetTargets.of(nightly).serverIds.toList())
        assertEquals(listOf(FleetScheduleTiming.WEEKLY, 6, 150, RunNotify.ALWAYS, 3L), listOf(nightly.repeat, nightly.dayOfWeek, nightly.minuteOfDay, nightly.notify, nightly.createdAt))
        assertNull("a schedule's last run is this phone's to make", nightly.lastRunKey)
        assertEquals(listOf("prod"), FleetTargets.of(schedules.getValue("Tagged")).tags)
        assertEquals(30, schedules.getValue("Tagged").everyMinutes)

        restore(model, main, bytes.toString(Charsets.UTF_8))
        assertEquals("restoring twice adds no use twice", 2, uses().size)
        assertEquals("nor a schedule", 2, repo.fleetSchedules().size)
    }

    @Test
    fun aRunLinkInABackupIsReadOnlyWhenItHasARunsShape() {
        val uses = BackupHistory.usesFrom(
            JSONArray()
                .put(JSONObject().put("at", 1L).put("outcome", UseOutcome.OK).put("detail", "web").put("runKey", "automation-1f2e"))
                .put(JSONObject().put("at", 2L).put("outcome", "exploded").put("detail", "x").put("runKey", "../../settings"))
                .put(JSONObject().put("at", 0L).put("outcome", UseOutcome.OK)),
        )
        assertEquals(listOf("automation-1f2e", null), uses.map { it.runKey })
        assertEquals("an unknown outcome reads as a failure", listOf(UseOutcome.OK, UseOutcome.FAILED), uses.map { it.outcome })
    }

    @Test
    fun aBackupThatCarriesTheSwitchDoesNotTurnItOn() = withModel { model, main, repo ->
        val backup = JSONObject()
            .put("format", "omniterm-backup")
            .put("schema", 1)
            .put("settings", JSONObject().put(Automation.SETTING_ENABLED, "true").put(OTHER_SETTING, "restored"))
            .toString()
        restore(model, main, backup)
        assertEquals("restored", repo.getSetting(OTHER_SETTING))
        assertNull(repo.getSetting(Automation.SETTING_ENABLED))
    }

    private val application: Application get() = ApplicationProvider.getApplicationContext()

    private suspend fun restore(model: AppViewModel, main: CoroutineDispatcher, backup: String) {
        val restored = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, EVERYTHING) { ok, message -> restored.complete(ok to message) } }
        val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
        assertTrue(restoreMessage, restoreOk)
        waitWhileOnMain(main) { model.backupRestoreRunning }
    }

    private fun withModel(block: suspend (AppViewModel, CoroutineDispatcher, AppRepository) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("automation-backup", model)
            block(model, main, AppRepository(db))
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private companion object {
        const val PASSPHRASE = "automation-backup-passphrase"
        // A setting the backup copies as stored, not one it rewrites from the screen's state.
        const val OTHER_SETTING = "automation_backup_fixture"
        val EVERYTHING = BackupSelection(
            servers = true, sshKeys = true, credentialProfiles = true, scripts = true,
            alertRules = true, activeAlerts = true, alertHistory = true, wolTargets = true,
            networkShares = true, portForwards = true, settings = true,
        )
    }
}
