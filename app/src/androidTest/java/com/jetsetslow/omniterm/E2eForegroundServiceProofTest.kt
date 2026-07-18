package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationManager
import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.junit4.createAndroidComposeRule
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

/** Opt-in, sanitized Play-review recording flow for the connected-device foreground service. */
class E2eForegroundServiceProofTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun recordsDisclosurePermissionAndForegroundNotificationWithoutEndpointDetails() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_foreground_proof") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = E2eAccessibility(instrumentation)
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val previousKeepAlive = vm.isBackgroundKeepAlive
        val previousFlagSecure = vm.isFlagSecureEnabled
        TerminalSessionManager.clearAll()
        try {
            // Keep endpoint setup completely black in screenrecord. Only the endpoint-free About
            // screen is allowed to become capturable below.
            composeRule.runOnUiThread { vm.saveFlagSecureToggle(true) }
            await("private setup window", 5_000) { vm.isFlagSecureEnabled }
            await("sanitized fixture host", 15_000) {
                vm.servers.value.any { it.name == SAFE_HOST_LABEL }
            }
            val host = requireNotNull(vm.servers.value.find { it.name == SAFE_HOST_LABEL })
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = host.id
                vm.connectTerminal()
            }
            await("proof SSH session", 25_000) { !vm.isTerminalConnecting && vm.currentSession != null }
            val sessionId = requireNotNull(vm.currentSession).id
            composeRule.runOnUiThread {
                vm.saveBackgroundKeepAliveToggle(true)
                vm.sendSessionToBackground(sessionId)
                vm.navigateTo(Screen.About)
            }
            await("background keep-alive setting", 5_000) { vm.isBackgroundKeepAlive }
            composeRule.runOnUiThread { vm.saveFlagSecureToggle(false) }
            await("recording-safe About window", 5_000) { !vm.isFlagSecureEnabled }
            composeRule.waitForIdle()
            shell("input keyevent KEYCODE_WAKEUP")
            shell("wm dismiss-keyguard")
            await("foreground-service disclosure", 10_000) {
                device.hasText("Keep sessions active in background?")
            }
            delay(4_000)
            device.clickText("Grant Permissions")
            await("Android notification permission", 10_000) { device.hasText("Allow") }
            delay(4_000)
            device.clickText("Allow")

            // The app intentionally opens Android's neutral battery-optimization list. Return
            // immediately; the recording pipeline removes this transition so other app names are
            // never included in the uploadable proof.
            delay(1_000)
            shell("input keyevent KEYCODE_BACK")
            delay(3_000)
            val notificationManager = composeRule.activity.getSystemService(NotificationManager::class.java)
            await("foreground service notification post", 10_000) {
                notificationManager.activeNotifications.any { status ->
                    val title = status.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
                    title == "OmniTerm Service" || title.startsWith("Terminal: $SAFE_HOST_LABEL")
                }
            }
            shell("input keyevent KEYCODE_HOME")
            delay(2_000)
            shell("cmd statusbar expand-notifications")
            await("foreground service notification", 10_000) {
                device.hasText("OmniTerm Service") || device.hasText("Background SSH session", contains = true)
            }
            delay(5_000)
        } finally {
            shell("cmd statusbar collapse")
            composeRule.runOnUiThread {
                vm.closeAllSessions()
                vm.saveBackgroundKeepAliveToggle(previousKeepAlive)
                vm.saveFlagSecureToggle(previousFlagSecure)
            }
        }
    }

    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private companion object { const val SAFE_HOST_LABEL = "E2E Foreground Demo" }
}
