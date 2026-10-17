package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import com.jetsetslow.omniterm.ui.TerminalPasteFeedback
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Primary terminal actions must be discoverable without a first scroll gesture. */
class E2eTerminalOptionsTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun primaryAndCopyRangeActionsStayVisibleBeforeScrolling() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_options") == "yes")
        val originalScale = shellOutput("settings get system font_scale").trim()
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val originalOrientation = composeRule.activity.requestedOrientation
        TerminalSessionManager.clearAll()
        try {
            await("repository fixture host", 15_000) { vm.servers.value.any { it.name == HOST } }
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.selectedServerId = vm.servers.value.first { it.name == HOST }.id
                vm.navigateTo(Screen.Shell)
                vm.connectTerminal()
            }
            await("fixture shell", 30_000) {
                composeRule.runOnUiThread {
                    if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
                    if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
                }
                !vm.isTerminalConnecting && vm.currentSession?.isConnected == true
            }
            for (scale in listOf("1.0", "1.5", "2.0")) {
                val beforeScale = composeRule.activity
                val scaleChanged = beforeScale.resources.configuration.fontScale != scale.toFloat()
                instrumentation.uiAutomation.executeShellCommand("settings put system font_scale $scale").close()
                await("font scale $scale", 10_000) {
                    val activity = composeRule.activity
                    (!scaleChanged || activity !== beforeScale) &&
                        activity.resources.configuration.fontScale == scale.toFloat()
                }
                for (orientation in listOf(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE)) {
                    val expected = if (orientation == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT) {
                        android.content.res.Configuration.ORIENTATION_PORTRAIT
                    } else {
                        android.content.res.Configuration.ORIENTATION_LANDSCAPE
                    }
                    val beforeRotation = composeRule.activity
                    val orientationChanged = beforeRotation.resources.configuration.orientation != expected
                    composeRule.runOnUiThread { beforeRotation.requestedOrientation = orientation }
                    await("orientation $orientation", 10_000) {
                        val activity = composeRule.activity
                        val decor = activity.window.decorView
                        (!orientationChanged || activity !== beforeRotation) &&
                            activity.resources.configuration.orientation == expected &&
                            decor.width > 0 && decor.height > 0 &&
                            (decor.width < decor.height) == (expected == android.content.res.Configuration.ORIENTATION_PORTRAIT)
                    }
                    // This matrix checks the full viewport. Closing result dialogs restores the
                    // terminal's keyboard; landscape deliberately uses compact header chrome.
                    // Settle composition, then close the IME and await its actual inset before
                    // asking for the full-header menu instead of increasing the finder timeout.
                    composeRule.waitForIdle()
                    androidx.test.espresso.Espresso.closeSoftKeyboard()
                    await("full viewport without IME", 10_000) {
                        // Rotation can finish rebinding the IME after Espresso's first hide.
                        // Dismiss only an actually visible keyboard on the current Activity,
                        // using the same deadline and rejecting an unattached replacement root.
                        val activity = composeRule.activity
                        val ime = androidx.core.view.WindowInsetsCompat.Type.ime()
                        if (androidx.core.view.ViewCompat.getRootWindowInsets(activity.window.decorView)
                                ?.isVisible(ime) == true) {
                            androidx.test.espresso.Espresso.closeSoftKeyboard()
                        }
                        val insets = androidx.core.view.ViewCompat.getRootWindowInsets(activity.window.decorView)
                        activity === composeRule.activity && activity.hasWindowFocus() &&
                            insets != null && !insets.isVisible(ime)
                    }
                    // Resources update before the old Activity/Compose root is destroyed. Await
                    // the replacement's rendered action rather than tapping during that gap.
                    composeRule.waitUntil(10_000) {
                        composeRule.onAllNodesWithContentDescription("Open terminal options")
                            .fetchSemanticsNodes().isNotEmpty()
                    }
                    composeRule.waitForIdle()
                    composeRule.onNodeWithContentDescription("Open terminal options").performClick()
                    composeRule.waitForIdle()
                    val configuration = "font scale $scale, " +
                        if (expected == android.content.res.Configuration.ORIENTATION_PORTRAIT) "portrait" else "landscape"
                    try {
                        // No performScrollTo: clipping an action inside the scroll body is the bug.
                        for (label in listOf("Paste from clipboard", "Visible screen", "Full buffer", "Clear scrollback", "Cancel")) {
                            composeRule.onNodeWithText(label).assertIsDisplayed().assertIsEnabled()
                        }
                        // A section heading must stay with the controls it names, not scroll away from them.
                        composeRule.onNodeWithText("Copy terminal text").assertIsDisplayed()
                        if (scale == "1.0" && orientation == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT) {
                            // At default text size the dialog has room for every option without scrolling.
                            for (label in listOf("Swipe-typing", "Keep screen on")) {
                                composeRule.onNodeWithText(label).assertIsDisplayed()
                            }
                        }
                    } catch (failure: AssertionError) {
                        throw AssertionError("Terminal options at $configuration: ${failure.message}", failure)
                    }
                    composeRule.onNodeWithText("Cancel").performClick()
                    composeRule.waitForIdle()
                    // Held writer behavior is covered with the real IO worker in JVM tests.
                    // Exercise its session-owned pending/result UI on each actual configuration.
                    val shell = requireNotNull(TerminalSessionManager.activeSessions.firstOrNull())
                    composeRule.runOnUiThread {
                        shell.pasteFeedback = TerminalPasteFeedback("Sending text to fixture…", busy = true)
                    }
                    composeRule.onNodeWithText("Terminal paste").assertIsDisplayed()
                    composeRule.onNodeWithText("Hide progress").assertIsDisplayed().assertIsEnabled().performClick()
                    composeRule.runOnUiThread {
                        shell.pasteFeedback = TerminalPasteFeedback("Paste was interrupted. Some text may have been sent; check the terminal before retrying.")
                    }
                    composeRule.onNodeWithText("OK").assertIsDisplayed().assertIsEnabled().performClick()
                    composeRule.waitForIdle()
                }
            }
        } finally {
            instrumentation.uiAutomation.executeShellCommand("settings put system font_scale $originalScale").close()
            composeRule.runOnUiThread { composeRule.activity.requestedOrientation = originalOrientation }
            TerminalSessionManager.clearAll()
        }
    }

    private fun shellOutput(command: String): String {
        val fd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        return android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).bufferedReader().use { it.readText() }
    }

    private suspend fun await(label: String, timeoutMs: Long, ready: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!ready()) delay(100) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private companion object { const val HOST = "E2E Foreground Demo" }
}
