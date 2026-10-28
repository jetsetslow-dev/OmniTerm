package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** A written file remains a successful export even when recording its timestamp fails. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class BackupExportOutcomeRobolectricTest {
    @Test fun writtenFileStillReportsSuccessWhenTimestampCannotBeRecorded() = export(rejectTimestamp = true)
    @Test fun writtenFileRecordsItsTimestampAndReportsSuccessOnce() = export()
    @Test fun failedFileWriteReportsFailureWithoutRecordingAnExport() = export(rejectFile = true)

    private fun export(rejectTimestamp: Boolean = false, rejectFile: Boolean = false) = runBlocking {
        // AppViewModel uses real IO. Capture any uncaught coroutine error rather than allowing a
        // worker death to masquerade as an unrelated test timeout.
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val main = Executors.newSingleThreadExecutor { work ->
            Thread(work, "backup-outcome-main").apply {
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
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            if (rejectTimestamp) withContext(Dispatchers.IO) {
                db.openHelper.writableDatabase.execSQL(
                    "CREATE TRIGGER reject_backup_timestamp BEFORE INSERT ON app_settings " +
                        "WHEN NEW.`key` = 'backup_last_export_time' " +
                        "BEGIN SELECT RAISE(ABORT, 'fixture metadata unavailable'); END",
                )
            }
            val uri = Uri.parse("content://backup-fixture/export.json")
            val bytes = ByteArrayOutputStream()
            val output: OutputStream = if (rejectFile) object : OutputStream() {
                override fun write(value: Int) { throw IOException("fixture document unavailable") }
            } else bytes
            shadowOf(application.contentResolver).registerOutputStream(uri, output)
            val result = CompletableDeferred<Pair<Boolean, String>>()
            val calls = AtomicInteger()
            val selection = BackupSelection(
                servers = false, sshKeys = false, credentialProfiles = false, scripts = false,
                alertRules = false, activeAlerts = false, alertHistory = false, wolTargets = false,
                networkShares = false, portForwards = false, settings = false,
            )
            withContext(main) {
                model.exportBackup(uri, "", application, selection) { ok, message ->
                    calls.incrementAndGet()
                    result.complete(ok to message)
                }
            }
            withTimeout(5_000) {
                while (!result.isCompleted && uncaught.isEmpty()) delay(10)
            }
            if (!rejectFile) {
                assertEquals("omniterm-backup", JSONObject(bytes.toString(Charsets.UTF_8)).getString("format"))
            }
            assertTrue(
                "Every completed file write needs its result; metadata errors must not lose it: $uncaught",
                result.isCompleted,
            )
            val (ok, message) = result.await()
            assertEquals(1, calls.get())
            assertTrue("No backup operation may escape without feedback: $uncaught", uncaught.isEmpty())
            waitWhileOnMain(main) { model.backupExportRunning }
            assertEquals(!rejectFile, ok)
            val recorded = repo.getSetting("backup_last_export_time")
            if (rejectFile) {
                assertNull(recorded)
                assertEquals(0L, model.lastBackupExportTime)
            } else {
                assertEquals("omniterm-backup", JSONObject(bytes.toString(Charsets.UTF_8)).getString("format"))
                assertTrue(model.lastBackupExportTime > 0)
                if (rejectTimestamp) {
                    assertNull(recorded)
                    assertTrue(message, message.contains("time", ignoreCase = true))
                    assertTrue(message, message.contains("record", ignoreCase = true))
                    val writtenAt = model.lastBackupExportTime
                    repo.insertSetting("telemetry_interval", "70")
                    waitWhileOnMain(main) { model.telemetryIntervalMs != 70_000L }
                    assertEquals("Other settings must not erase a backup actually written in this run", writtenAt, model.lastBackupExportTime)
                } else {
                    assertEquals(model.lastBackupExportTime.toString(), recorded)
                }
            }
        } finally {
            withContext(Dispatchers.IO) {
                db.openHelper.writableDatabase.execSQL("DROP TRIGGER IF EXISTS reject_backup_timestamp")
            }
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
