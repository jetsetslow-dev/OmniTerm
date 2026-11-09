package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
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
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * A backup never carries automation: not its tokens, and not its switch, either way. Restoring a
 * backup on another phone must not let other apps run scripts there.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class AutomationBackupRobolectricTest {

    @Test
    fun aBackupLeavesAutomationBehind() = withModel { model, main, repo ->
        repo.insertScript(QuickScriptEntity(emoji = "", name = "Uptime", command = "uptime", color = "cyan"))
        val script = repo.getAllScripts().single { it.name == "Uptime" }
        repo.insertAutomationGrant(
            AutomationGrantEntity(scriptId = script.id, serverIds = "1", tokenHash = Automation.hash(Automation.newToken()), label = "Tasker", createdAt = 1L),
        )
        repo.insertSetting(Automation.SETTING_ENABLED, "true")
        repo.insertSetting(OTHER_SETTING, "kept")

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
        assertNull("the switch stays on the phone it was turned on", repo.getSetting(Automation.SETTING_ENABLED))
        assertTrue("tokens are never in a backup", repo.automationGrantsFlow.first().isEmpty())
        assertEquals("the script itself is", listOf("Uptime"), repo.getAllScripts().map { it.name }.filter { it == "Uptime" })
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
