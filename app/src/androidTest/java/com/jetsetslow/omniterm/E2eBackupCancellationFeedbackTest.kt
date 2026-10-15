package com.jetsetslow.omniterm

import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.isDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.*
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Cancels real dialogs and DocumentsUI without creating a backup or touching a server. */
class E2eBackupCancellationFeedbackTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun cancelledBackupStepsExplainTheOutcomeAndRemainUsable() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_backup_cancellation") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val original = vm.backupExportSelection
        val originalScreen = vm.currentScreen
        val exportCancelled = "Backup cancelled. Nothing was written."
        val restoreCancelled = "Restore cancelled. Nothing was changed."
        fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand(command),
        ).bufferedReader().use { it.readText() }
        fun pickerFocused(): Boolean = instrumentation.uiAutomation.rootInActiveWindow
            ?.packageName?.toString()?.endsWith(".documentsui") == true
        suspend fun cancelPicker() {
            try {
                withTimeout(10_000) { while (!pickerFocused()) delay(50) }
            } catch (failure: TimeoutCancellationException) {
                throw AssertionError(
                    "The native picker must receive focus; active package=" +
                        instrumentation.uiAutomation.rootInActiveWindow?.packageName,
                    failure,
                )
            }
            repeat(3) {
                if (!pickerFocused()) return
                shell("input keyevent KEYCODE_BACK")
                delay(150)
            }
            assertTrue("The real document picker must close", !pickerFocused())
        }
        fun tap(text: String) {
            val node = composeRule.onNodeWithText(text)
            if (!node.isDisplayed()) node.performScrollTo()
            node.performClick()
        }
        fun expectFeedback(message: String) {
            try {
                composeRule.waitUntil(10_000) {
                    composeRule.onAllNodesWithText(message).fetchSemanticsNodes().isNotEmpty()
                }
            } catch (failure: androidx.compose.ui.test.ComposeTimeoutException) {
                throw AssertionError("Cancelling a backup step must visibly explain that no work was completed", failure)
            }
            composeRule.onNodeWithText(message).performScrollTo().assertIsDisplayed()
            composeRule.onNodeWithText(context.getString(R.string.backup)).assertIsEnabled()
        }
        try {
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.updateBackupExportSelection(BackupSelection())
                vm.navigateTo(Screen.Backup)
            }
            withTimeout(10_000) { while (vm.backupSelectionSaving) delay(20) }
            tap(context.getString(R.string.backup))
            tap(context.getString(R.string.cancel))
            expectFeedback(exportCancelled)

            tap(context.getString(R.string.backup))
            tap(context.getString(R.string.continue_label))
            composeRule.onNodeWithText(context.getString(R.string.encrypt_backup)).assertIsDisplayed()
            tap(context.getString(R.string.cancel))
            expectFeedback(exportCancelled)

            tap(context.getString(R.string.backup))
            tap(context.getString(R.string.continue_label))
            composeRule.onNodeWithText("Passphrase (min 12 chars)").performTextInput("fixture-passphrase")
            tap(context.getString(R.string.choose_location))
            cancelPicker()
            expectFeedback(exportCancelled)

            tap(context.getString(R.string.restore))
            cancelPicker()
            expectFeedback(restoreCancelled)
            composeRule.activityRule.scenario.recreate()
            expectFeedback(restoreCancelled)
        } finally {
            composeRule.runOnUiThread {
                vm.updateBackupExportSelection(original)
                vm.navigateTo(originalScreen)
            }
            withTimeout(10_000) { while (vm.backupSelectionSaving) delay(20) }
        }
    }
}
