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
import com.jetsetslow.omniterm.data.ServerEntity
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
        repo.insertAutomationGrant(
            AutomationGrantEntity(scriptId = script.id, serverIds = host.toString(), tokenHash = token, label = "Tasker", createdAt = 1L),
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
        assertEquals("a restore leaves automation off", "false", repo.getSetting(Automation.SETTING_ENABLED))
        assertEquals("the token comes back", listOf(token), repo.automationGrantsFlow.first().map { it.tokenHash })
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
