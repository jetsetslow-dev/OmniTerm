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
                    // Resources update before the old Activity/Compose root is destroyed. Await
                    // the replacement's rendered action rather than tapping during that gap.
                    composeRule.waitUntil(10_000) {
                        composeRule.onAllNodesWithContentDescription("Open terminal options")
                            .fetchSemanticsNodes().isNotEmpty()
                    }
                    composeRule.waitForIdle()
                    composeRule.onNodeWithContentDescription("Open terminal options").performClick()
                    composeRule.waitForIdle()
                    // No performScrollTo: clipping an action inside the scroll body is the bug.
                    for (label in listOf("Paste from clipboard", "Visible screen", "Full buffer", "Clear scrollback", "Cancel")) {
                        composeRule.onNodeWithText(label).assertIsDisplayed().assertIsEnabled()
                    }
                    composeRule.onNodeWithText("Cancel").performClick()
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
