package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ScriptChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * A Script Check's script and a rule's runbook survive a backup restored on another device, where
 * the same scripts have other ids: the backup names them by category and name, not by id.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class ScriptRefsBackupRobolectricTest {
    @Test
    fun aRuleKeepsItsScriptsAcrossABackupRestoredWithOtherIds() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val repo = AppRepository(db)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            val check = save(repo, "Backups fresh", "test -n \"\$(find /srv/backup -mtime -1)\"")
            val runbook = save(repo, "Restart backups", "systemctl restart backup.service")
            repo.insertRule(
                AlertRuleEntity(
                    serverId = 0, metricName = HostChecks.SCRIPT_CHECK, thresholdValue = 0f, severity = "WARNING",
                    triggerWindow = "2m", target = check.id.toString(), runbookScriptId = runbook.id,
                ),
            )
            val selection = BackupSelection.NONE.copy(scripts = true, alertRules = true)

            val uri = Uri.parse("content://backup-fixture/scripts.json")
            val bytes = ByteArrayOutputStream()
            shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
            val exported = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.exportBackup(uri, PASSPHRASE, application, selection) { ok, message -> exported.complete(ok to message) } }
            val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
            assertTrue(exportMessage, exportOk)
            waitWhileOnMain(main) { model.backupExportRunning }
            val backup = bytes.toString(Charsets.UTF_8)
            assertTrue("scripts and rules are exported encrypted", JSONObject(backup).has("data"))

            // Another device: the same scripts arrive after one of its own, so their ids differ.
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val other = save(repo, "Uptime", "uptime")
            val restored = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, selection) { ok, message -> restored.complete(ok to message) } }
            val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
            assertTrue(restoreMessage, restoreOk)

            val scripts = repo.getAllScripts()
            val newCheck = scripts.single { it.name == "Backups fresh" }
            val newRunbook = scripts.single { it.name == "Restart backups" }
            assertNotEquals("the restore really did give the scripts other ids", check.id, newCheck.id)
            // Had the backup carried the old id, the rule would point at no script, or another one.
            val rule = repo.getAllRules().single { it.metricName == HostChecks.SCRIPT_CHECK }
            assertEquals(newCheck.id, ScriptChecks.scriptId(rule))
            assertEquals(newRunbook.id, rule.runbookScriptId)
            assertTrue(other.id != newCheck.id && other.id != newRunbook.id)
            waitWhileOnMain(main) { model.backupRestoreRunning }
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
        const val PASSPHRASE = "script-refs-passphrase"
    }

    private suspend fun save(repo: AppRepository, name: String, command: String): QuickScriptEntity {
        repo.insertScript(QuickScriptEntity(emoji = "LIN", name = name, command = command, color = "cyan"))
        return repo.getAllScripts().single { it.name == name }
    }
}
