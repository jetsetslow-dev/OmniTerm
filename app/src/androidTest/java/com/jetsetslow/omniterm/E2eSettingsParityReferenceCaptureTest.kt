package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.view.KeyEvent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in reference capture on the disposable Android fixture; never included in the app APK. */
class E2eSettingsParityReferenceCaptureTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun captureSettingsCardsAndPopups() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_settings_captures") == "yes")
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val baseline = mapOf(
            "flag_secure" to "false", "dark_mode" to "true", "amoled" to "false",
            "accessibility" to "false", "text_scale" to "normal", "app_lock_enabled" to "false",
            "biometrics_enabled" to "false", "battery_saver_enabled" to "false",
            "terminal_font_size" to "10", "terminal_scrollback_limit" to "10000",
            "terminal_theme" to "system", "sftp_large_batch_file_threshold" to "50",
            "sftp_large_batch_bytes_threshold" to "1000000000",
        )
        val saved = (baseline.keys + "app_pin").associateWith { repository.getSetting(it) }
        val orientation = composeRule.activity.requestedOrientation
        val locked = vm.isAppLocked
        val directory = File(context.getExternalFilesDir(null), "settings-parity-reference").apply { mkdirs() }
        try {
            baseline.forEach { (key, value) -> repository.insertSetting(key, value) }
            repository.deleteSetting("app_pin")
            withTimeout(10_000) {
                while (vm.isFlagSecureEnabled || vm.isAppLockEnabled || vm.savedPin != null) delay(50)
            }
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.settingsDirty = false
                composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            val headings = listOf(
                "SECURITY GATE APP LOCK", "DISPLAY BEHAVIOR", "METRICS DATA PRUNING",
                "TERMINAL", "ALERT HISTORY", "SFTP TRANSFER WARNINGS",
            )
            for ((name, dark, contrast, scale) in listOf(
                Variant("dark", true, false, "normal"),
                Variant("light", false, false, "normal"),
                Variant("contrast", true, true, "normal"),
                Variant("large", true, false, "large"),
            )) {
                composeRule.runOnUiThread { vm.navigateTo(Screen.Tools) }
                // Dispose the remembered drafts before changing the next baseline.
                composeRule.waitForIdle()
                composeRule.runOnUiThread {
                    vm.saveDarkModeToggle(dark)
                    vm.saveAccessibilityToggle(contrast)
                    vm.saveTextScale(scale)
                }
                withTimeout(10_000) {
                    while (vm.isDarkModeEnabled != dark || vm.isAccessibilityEnabled != contrast || vm.textScale != scale) delay(50)
                }
                composeRule.runOnUiThread { vm.navigateTo(Screen.Settings) }
                composeRule.waitUntil(10_000) {
                    composeRule.onAllNodesWithText(headings.first()).fetchSemanticsNodes().isNotEmpty()
                }
                capture(directory, "$name-top")
                headings.drop(1).forEachIndexed { index, heading ->
                    composeRule.onNodeWithText(heading).performScrollTo().assertIsDisplayed()
                    composeRule.onNodeWithText("Save changes").assertIsDisplayed()
                    capture(directory, "$name-card-${index + 1}")
                }
                composeRule.onNodeWithText("Require PIN to unlock").performScrollTo()
                val label = composeRule.onNodeWithText("Require PIN to unlock").fetchSemanticsNode().boundsInRoot
                composeRule.onNode(isToggleable() and SemanticsMatcher("in the Require PIN row") { node ->
                    node.boundsInRoot.center.y in label.top..label.bottom
                }).performClick()
                composeRule.onNodeWithText("Configure Security PIN").assertIsDisplayed()
                capture(directory, "$name-pin-setup")
                instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                composeRule.waitForIdle()
                composeRule.onNodeWithText("Theme App Appearance").performScrollTo()
                val themeLabel = composeRule.onNodeWithText("Theme App Appearance").fetchSemanticsNode().boundsInRoot
                composeRule.onNode(hasText(if (dark) "Dark" else "Light") and
                    SemanticsMatcher("in the app theme row, not the terminal palette") { node ->
                        node.boundsInRoot.top < themeLabel.bottom && node.boundsInRoot.bottom > themeLabel.top
                    }).performClick()
                try {
                    composeRule.waitUntil(5_000) {
                        composeRule.onAllNodesWithText("System Default").fetchSemanticsNodes().isNotEmpty()
                    }
                    composeRule.onNodeWithText("System Default").assertIsDisplayed()
                } catch (error: Throwable) {
                    capture(directory, "$name-menu-failure")
                    throw error
                }
                capture(directory, "$name-theme-menu")
                instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
                composeRule.waitForIdle()
            }
        } finally {
            composeRule.runOnUiThread {
                vm.settingsDirty = false
                vm.navigateTo(Screen.Tools)
                composeRule.activity.requestedOrientation = orientation
                vm.isAppLocked = locked
            }
            for ((key, value) in saved) {
                if (value == null) repository.deleteSetting(key) else repository.insertSetting(key, value)
            }
        }
    }

    private data class Variant(val name: String, val dark: Boolean, val contrast: Boolean, val scale: String)

    private suspend fun capture(directory: File, name: String) {
        composeRule.waitForIdle()
        delay(350)
        val image = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try {
            File(directory, "$name.png").outputStream().use {
                assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally {
            image.recycle()
        }
    }
}
