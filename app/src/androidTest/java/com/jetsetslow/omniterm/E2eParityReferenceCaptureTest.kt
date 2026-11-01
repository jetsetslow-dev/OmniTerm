package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in Kotlin reference frames for comparing the Flutter port on the same Android runtime. */
class E2eParityReferenceCaptureTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun captureTerminalKeyboardReference() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_parity_captures") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val keys = listOf("flag_secure", "dark_mode", "amoled", "accessibility", "text_scale", "background_keep_alive")
        val saved = keys.associateWith { repository.getSetting(it) }
        val originalOrientation = composeRule.activity.requestedOrientation
        val originalReadOnly = vm.terminalReadOnly
        val directory = File(context.getExternalFilesDir(null), "parity-reference").apply { mkdirs() }
        val createdSessions = mutableSetOf<String>()
        try {
            // The provisioner uses only scripts/test-hosts.sh. Refuse another saved connection.
            await("repository fixture host loaded") { vm.servers.value.any { it.name == "E2E Foreground Demo" } }
            val host = vm.servers.value.single { it.name == "E2E Foreground Demo" }
            assertTrue("Use the disposable repository fleet", host.host == "10.0.2.2" && host.port == 2201)
            repository.insertSetting("flag_secure", "false")
            repository.insertSetting("background_keep_alive", "false")
            repository.insertSetting("amoled", "false")
            await("capture settings applied") { !vm.isFlagSecureEnabled && !vm.isBackgroundKeepAlive && !vm.isAmoledEnabled }
            composeRule.runOnUiThread {
                composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                vm.selectedServerId = host.id
                vm.navigateTo(Screen.Shell)
                vm.connectTerminal()
            }
            await("fixture SSH connected") {
                if (vm.offlineConnectPromptServer != null) {
                    composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                }
                !vm.isTerminalConnecting && vm.currentSession != null
            }
            assertNull(vm.terminalConnectError)
            createdSessions += requireNotNull(vm.currentSession).id
            await("fixture terminal output") { vm.terminalBufferTextFor(vm.currentSession, full = true).isNotBlank() }
            for ((name, dark, contrast, scale) in listOf(
                Variant("dark", true, false, "normal"),
                Variant("light", false, false, "normal"),
                Variant("contrast", true, true, "normal"),
                Variant("large", true, false, "large"),
            )) {
                composeRule.runOnUiThread {
                    vm.saveDarkModeToggle(dark)
                    vm.saveAccessibilityToggle(contrast)
                    vm.saveTextScale(scale)
                    vm.updateTerminalReadOnly(false)
                }
                hideKeyboard()
                capture(directory, "portrait-$name-nav")
                composeRule.onNodeWithText("FN").performClick()
                capture(directory, "portrait-$name-function")
                composeRule.onNodeWithText("SYM").performClick()
                capture(directory, "portrait-$name-symbol")
                composeRule.onNodeWithText("SYM").performClick()
                composeRule.runOnUiThread { vm.updateTerminalReadOnly(true) }
                hideKeyboard()
                capture(directory, "portrait-$name-readonly")
            }
            composeRule.runOnUiThread {
                vm.saveDarkModeToggle(true)
                vm.saveAccessibilityToggle(false)
                vm.saveTextScale("normal")
                vm.updateTerminalReadOnly(false)
                composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
            await("landscape orientation") { context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            composeRule.runOnUiThread { insetsController().show(WindowInsetsCompat.Type.ime()) }
            await("keyboard shown") { imeVisible() }
            capture(directory, "landscape-nav")
            composeRule.onNodeWithText("FN").performClick()
            capture(directory, "landscape-function")
            composeRule.onNodeWithText("SYM").performClick()
            capture(directory, "landscape-symbol")
            composeRule.onNodeWithText("SYM").performClick()
            hideKeyboard()
            capture(directory, "landscape-no-ime")
        } finally {
            composeRule.runOnUiThread {
                createdSessions.forEach(vm::disconnectSession)
                vm.updateTerminalReadOnly(originalReadOnly)
                composeRule.activity.requestedOrientation = originalOrientation
            }
            for ((key, value) in saved) {
                if (value == null) repository.deleteSetting(key) else repository.insertSetting(key, value)
            }
        }
    }

    private data class Variant(val name: String, val dark: Boolean, val contrast: Boolean, val scale: String)

    private fun insetsController() = WindowInsetsControllerCompat(
        composeRule.activity.window, composeRule.activity.window.decorView,
    )

    private fun imeVisible() = ViewCompat.getRootWindowInsets(composeRule.activity.window.decorView)
        ?.isVisible(WindowInsetsCompat.Type.ime()) == true

    private suspend fun hideKeyboard() {
        composeRule.runOnUiThread { insetsController().hide(WindowInsetsCompat.Type.ime()) }
        await("keyboard hidden") { !imeVisible() }
    }

    private suspend fun capture(directory: File, name: String) {
        composeRule.waitForIdle()
        // Let the platform keyboard animation finish after the Compose frame is ready.
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

    private suspend fun await(label: String, predicate: () -> Boolean) {
        try {
            withTimeout(30_000) { while (!predicate()) delay(50) }
        } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not complete", error)
        }
    }
}
