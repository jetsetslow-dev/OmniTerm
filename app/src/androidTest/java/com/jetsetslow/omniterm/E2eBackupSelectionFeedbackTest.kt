package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.room.withTransaction
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.decodeBackupSelection
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Uses only a synthetic local settings failure; no server connection or document is touched. */
class E2eBackupSelectionFeedbackTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun choosingSectionsShowsProgressFailureAndAWorkingRetry() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_backup_selection") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val db = AppDatabase.getDatabase(context)
        val repo = AppRepository(db)
        val original = repo.getSetting("backup_export_selection")
        val originalScreen = vm.currentScreen
        try {
            composeRule.runOnUiThread { vm.isAppLocked = false; vm.navigateTo(Screen.Backup) }
            composeRule.waitForIdle()
            composeRule.onNodeWithText(context.getString(R.string.backup)).performScrollTo().performClick()
            composeRule.onNodeWithText(context.getString(R.string.backup_sections)).assertIsDisplayed()
            coroutineScope {
                val held = CompletableDeferred<Unit>()
                val release = CompletableDeferred<Unit>()
                val transaction = async(Dispatchers.IO) {
                    db.withTransaction { held.complete(Unit); release.await() }
                }
                try {
                    held.await()
                    composeRule.onAllNodes(isToggleable())[0].performClick()
                    try {
                        composeRule.waitUntil(10_000) {
                            composeRule.onAllNodesWithText("Remembering backup selection…").fetchSemanticsNodes().isNotEmpty()
                        }
                    } catch (e: androidx.compose.ui.test.ComposeTimeoutException) {
                        throw AssertionError("Remembering backup selection… must be visible while Room is blocked", e)
                    }
                    val progress = composeRule.onAllNodesWithText("Remembering backup selection…")
                    progress[progress.fetchSemanticsNodes().lastIndex].assertIsDisplayed()
                    composeRule.onNodeWithText(context.getString(R.string.continue_label)).assertIsDisplayed().assertIsEnabled()
                    assertTrue(vm.backupSelectionSaving)
                } finally { release.complete(Unit); transaction.await() }
            }
            await { !vm.backupSelectionSaving }
            assertNull(vm.backupSelectionError)
            assertEquals(vm.backupExportSelection, decodeBackupSelection(repo.getSetting("backup_export_selection")))
            withContext(Dispatchers.IO) {
                db.openHelper.writableDatabase.execSQL(
                    "CREATE TRIGGER e2e_reject_backup_selection BEFORE INSERT ON app_settings " +
                        "WHEN NEW.`key` = 'backup_export_selection' " +
                        "BEGIN SELECT RAISE(ABORT, 'synthetic settings failure'); END",
                )
            }
            composeRule.onAllNodes(isToggleable())[0].performClick()
            await { !vm.backupSelectionSaving && vm.backupSelectionError != null }
            val failure = checkNotNull(vm.backupSelectionError)
            val messages = composeRule.onAllNodesWithText(failure)
            messages[messages.fetchSemanticsNodes().lastIndex].assertIsDisplayed()
            composeRule.onNodeWithText(context.getString(R.string.continue_label)).assertIsDisplayed().assertIsEnabled()
            composeRule.onNodeWithText(context.getString(R.string.cancel)).assertIsDisplayed().assertIsEnabled()
            val draft = vm.backupExportSelection
            assertNotEquals(draft, decodeBackupSelection(repo.getSetting("backup_export_selection")))
            withContext(Dispatchers.IO) { db.openHelper.writableDatabase.execSQL("DROP TRIGGER e2e_reject_backup_selection") }
            composeRule.runOnUiThread { vm.updateBackupExportSelection(draft) }
            await { !vm.backupSelectionSaving }
            assertNull(vm.backupSelectionError)
            assertEquals(draft, decodeBackupSelection(repo.getSetting("backup_export_selection")))
            composeRule.onNodeWithText(context.getString(R.string.cancel)).performClick()
        } finally {
            withContext(Dispatchers.IO) {
                db.openHelper.writableDatabase.execSQL("DROP TRIGGER IF EXISTS e2e_reject_backup_selection")
            }
            composeRule.runOnUiThread { vm.updateBackupExportSelection(decodeBackupSelection(original)) }
            await { !vm.backupSelectionSaving }
            if (original == null) repo.deleteSetting("backup_export_selection")
            else repo.insertSetting("backup_export_selection", original)
            composeRule.runOnUiThread { vm.navigateTo(originalScreen) }
        }
    }

    private suspend fun await(predicate: () -> Boolean) {
        withTimeout(10_000) { while (!predicate()) delay(20) }
        composeRule.waitForIdle()
    }
}
