package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.room.withTransaction
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.decodeBackupSelection
import kotlinx.coroutines.*
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class BackupSelectionPersistenceRobolectricTest {
    @Test fun failedSelectionKeepsTheDraftExplainsRetryAndCanBeSavedLater() = withModel { model, repo, db, main, uncaught ->
        withContext(Dispatchers.IO) {
            db.openHelper.writableDatabase.execSQL(
                "CREATE TRIGGER reject_backup_selection BEFORE INSERT ON app_settings " +
                    "WHEN NEW.`key` = 'backup_export_selection' " +
                    "BEGIN SELECT RAISE(ABORT, 'fixture selection unavailable'); END",
            )
        }
        val desired = BackupSelection(crashLogs = true)
        withContext(main) { model.updateBackupExportSelection(desired) }
        waitWhileOnMain(main) { model.backupSelectionError == null && uncaught.isEmpty() }
        assertTrue("Selection errors need feedback instead of escaping the UI: $uncaught", uncaught.isEmpty())
        assertFalse(model.backupSelectionSaving)
        assertTrue(checkNotNull(model.backupSelectionError).contains("could not be remembered"))
        assertEquals(desired, model.backupExportSelection)
        assertNull(repo.getSetting("backup_export_selection"))
        withContext(Dispatchers.IO) {
            db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_backup_selection")
        }
        repo.insertSetting("telemetry_interval", "80")
        waitWhileOnMain(main) { model.telemetryIntervalMs != 80_000L }
        assertEquals("Another settings emission cannot silently replace a failed draft", desired, model.backupExportSelection)
        withContext(main) { model.updateBackupExportSelection(desired) }
        waitWhileOnMain(main) { model.backupSelectionSaving }
        assertNull(model.backupSelectionError)
        assertEquals(desired, decodeBackupSelection(repo.getSetting("backup_export_selection")))
    }

    @Test fun queuedSelectionsShowProgressAndTheNewestChoiceWins() = withModel { model, repo, db, main, uncaught ->
        val held = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        coroutineScope {
            val transaction = async(Dispatchers.IO) {
                db.withTransaction { held.complete(Unit); release.await() }
            }
            try {
                held.await()
                withContext(main) {
                    model.updateBackupExportSelection(BackupSelection(crashLogs = true))
                    assertTrue("Remembering a pending choice must show progress", model.backupSelectionSaving)
                    model.updateBackupExportSelection(BackupSelection(crashLogs = false))
                    assertTrue(model.backupSelectionSaving)
                }
            } finally { release.complete(Unit); transaction.await() }
        }
        waitWhileOnMain(main) { model.backupSelectionSaving }
        assertTrue(uncaught.isEmpty())
        assertNull(model.backupSelectionError)
        assertEquals(BackupSelection(), decodeBackupSelection(repo.getSetting("backup_export_selection")))
        assertEquals(BackupSelection(), model.backupExportSelection)
    }

    private fun withModel(
        block: suspend (AppViewModel, AppRepository, AppDatabase, CoroutineDispatcher, List<Throwable>) -> Unit,
    ) = runBlocking {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val main = Executors.newSingleThreadExecutor { work ->
            Thread(work, "backup-selection-main").apply {
                uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, failure -> uncaught.add(failure) }
            }
        }.asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val repo = AppRepository(db)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            repo.insertSetting("telemetry_interval", "70")
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            waitWhileOnMain(main) { model.telemetryIntervalMs != 70_000L }
            block(model, repo, db, main, uncaught)
        } finally {
            withContext(Dispatchers.IO) { db.openHelper.writableDatabase.execSQL("DROP TRIGGER IF EXISTS reject_backup_selection") }
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            }
            finally { Dispatchers.resetMain(); main.close() }
        }
    }
}
