package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationManager
import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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

    /**
     * Extends the proof above to demonstrate the service is ESSENTIAL, in the same single
     * foregrounded Activity (a separate prepare/record split cannot reliably bring the record
     * Activity to front). A live SSH session streams a monotonic heartbeat on camera; enabling
     * keep-alive raises the in-app disclosure and system permission prompt; Home backgrounds the
     * app; the foreground-service notification appears; returning shows the SAME session's counter
     * still advancing — continuity that is only possible because the service held the connection.
     *
     * Everything on camera is synthetic: a demo SSH container (hostname `atlas-prod`, user `demo`)
     * on the disposable lab, addressed through a documentation IP the driver NATs to the lab, so
     * no real endpoint renders. The demo container is created and torn down while FLAG_SECURE is
     * on (off camera), mirroring the proof flow's black setup window.
     */
    @Test
    fun recordsForegroundServiceKeepingASessionAliveAcrossBackgrounding() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_foreground_essential") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = E2eAccessibility(instrumentation)
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val previousKeepAlive = vm.isBackgroundKeepAlive
        val previousFlagSecure = vm.isFlagSecureEnabled
        var demoId: Int? = null
        TerminalSessionManager.clearAll()
        try {
            // ---- Off-camera setup under FLAG_SECURE: bring up the demo container. ----
            composeRule.runOnUiThread { vm.saveFlagSecureToggle(true) }
            await("private setup window", 5_000) { vm.isFlagSecureEnabled }
            await("sanitized fixture host", 15_000) { vm.servers.value.any { it.name == SAFE_HOST_LABEL } }
            val labHost = requireNotNull(vm.servers.value.find { it.name == SAFE_HOST_LABEL })
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = labHost.id
                vm.connectTerminal()
            }
            await("setup shell", 45_000) {
                if (vm.offlineConnectPromptServer != null) composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                if (vm.pendingHostKeyApproval != null) composeRule.runOnUiThread { vm.approveHostKey(true) }
                !vm.isTerminalConnecting && vm.currentSession != null
            }
            assertNull(vm.terminalConnectError)
            val setup = requireNotNull(vm.currentSession)
            await("setup prompt", 10_000) { vm.terminalBufferTextFor(setup, full = true).isNotBlank() }
            vm.pasteText(
                "docker rm -f omniterm-demo >/dev/null 2>&1; " +
                    "docker run -d --name omniterm-demo --hostname atlas-prod -p 2299:22 alpine:latest " +
                    "sh -c 'apk add --no-cache openssh >/dev/null 2>&1 && ssh-keygen -A && " +
                    "adduser -D demo && echo demo:omni-demo-pass | chpasswd && exec /usr/sbin/sshd -D' " +
                    "&& printf '%s%s\\n' 'DEMO-' 'STARTED'\n",
            )
            await("demo container", 120_000) { vm.terminalBufferTextFor(setup, full = true).contains("DEMO-STARTED") }
            vm.pasteText(
                "i=0; until docker exec omniterm-demo pgrep -x sshd >/dev/null 2>&1; " +
                    "do i=\$((i+1)); [ \$i -gt 90 ] && break; sleep 1; done; printf '%s%s\\n' 'DEMO-' 'READY'\n",
            )
            await("demo sshd", 120_000) { vm.terminalBufferTextFor(setup, full = true).contains("DEMO-READY") }

            repository.getAllServers().filter { it.name == "atlas-prod" }.forEach { repository.deleteServerAndDependents(it.id) }
            val id = repository.insertServer(
                ServerEntity(
                    name = "atlas-prod", host = "192.0.2.10", port = 2299, username = "demo",
                    authPassword = "omni-demo-pass", groupName = "Production", status = "online", lastLatency = 12,
                ),
            ).toInt()
            demoId = id
            composeRule.runOnUiThread { vm.removeKnownHost("192.0.2.10:2299") }
            await("demo row visible", 10_000) { vm.servers.value.any { it.id == id } }
            composeRule.runOnUiThread { vm.closeAllSessions() }
            await("setup session closed", 20_000) { vm.activeSessions.isEmpty() }
            TerminalSessionManager.clearAll()

            // ---- On-camera: connect the demo host and stream a heartbeat. ----
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = id
                vm.connectTerminal()
            }
            await("demo session", 45_000) {
                if (vm.offlineConnectPromptServer != null) composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                if (vm.pendingHostKeyApproval != null) composeRule.runOnUiThread { vm.approveHostKey(true) }
                !vm.isTerminalConnecting && vm.currentSession != null
            }
            assertNull(vm.terminalConnectError)
            val session = requireNotNull(vm.currentSession)
            val sessionId = session.id
            await("demo prompt", 15_000) { vm.terminalBufferTextFor(session, full = true).contains("atlas-prod") }
            vm.pasteText("clear; i=0; while true; do i=\$((i+1)); printf 'session heartbeat %04d\\n' \"\$i\"; sleep 1; done\n")
            await("heartbeat stream", 15_000) { vm.terminalBufferTextFor(session, full = true).contains("session heartbeat 0003") }

            // ---- Disclosure + permission, exactly as the proof flow (background to About). ----
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
            await("foreground-service disclosure", 10_000) { device.hasText("Keep sessions active in background?") }
            delay(4_000)
            device.clickText("Grant Permissions")
            await("Android notification permission", 10_000) { device.hasText("Allow") }
            delay(4_000)
            device.clickText("Allow")
            delay(1_000)
            shell("input keyevent KEYCODE_BACK")
            delay(3_000)
            val notificationManager = composeRule.activity.getSystemService(NotificationManager::class.java)
            await("foreground service notification post", 10_000) {
                notificationManager.activeNotifications.any { status ->
                    val title = status.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
                    title == "OmniTerm Service" || title.startsWith("Terminal: atlas-prod")
                }
            }

            // ---- Essentiality: re-attach so the heartbeat is on screen, then Home + return. ----
            composeRule.runOnUiThread {
                vm.attachSession(sessionId)
                vm.navigateTo(Screen.Shell)
            }
            await("heartbeat on screen", 15_000) {
                vm.currentSession?.id == sessionId && vm.terminalBufferTextFor(session, full = true).contains("session heartbeat 00")
            }
            delay(3_000)
            shell("input keyevent KEYCODE_HOME")
            delay(3_000)
            shell("cmd statusbar expand-notifications")
            await("shade shows service", 10_000) {
                device.hasText("OmniTerm Service") || device.hasText("atlas-prod", contains = true)
            }
            delay(4_000)
            shell("cmd statusbar collapse")
            delay(1_000)
            // Return to the SAME task (resume, not a fresh Activity) via the launcher intent, so the
            // compose rule's Activity handle stays valid for teardown. A bare component `am start`
            // could start a new task instance and null out the rule's handle at close().
            shell(
                "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER " +
                    "-n ${context.packageName}/com.jetsetslow.omniterm.MainActivity " +
                    "-f 0x10200000", // FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            )
            await("session still live after return", 15_000) {
                vm.currentSession?.id == sessionId && vm.terminalBufferTextFor(session, full = true).contains("session heartbeat 00")
            }
            val countBefore = latestHeartbeat(vm.terminalBufferTextFor(session, full = true))
            delay(6_000)
            val countAfter = latestHeartbeat(vm.terminalBufferTextFor(session, full = true))
            assertTrue("heartbeat did not keep advancing ($countBefore -> $countAfter)", countAfter > countBefore)
            delay(3_000)
        } finally {
            shell("cmd statusbar collapse")
            // Teardown runs on the main-thread executor directly (not composeRule.runOnUiThread),
            // because the on-camera Home+return may have left the rule's Activity handle stale — a
            // runOnUiThread against it can NPE. The ViewModel and repository work regardless.
            val mainExecutor = androidx.core.content.ContextCompat.getMainExecutor(
                InstrumentationRegistry.getInstrumentation().targetContext,
            )
            fun onMain(block: () -> Unit) {
                val done = java.util.concurrent.CountDownLatch(1)
                mainExecutor.execute { runCatching(block); done.countDown() }
                done.await(5, java.util.concurrent.TimeUnit.SECONDS)
            }
            // Stop the heartbeat loop and remove the demo container off camera.
            runCatching {
                val live = vm.currentSession ?: vm.activeSessions.firstOrNull { it.serverId == demoId }
                if (live != null) {
                    onMain { vm.attachSession(live.id) }
                    onMain { vm.isCtrlPressed = true; vm.typeText("c") }
                    delay(500)
                    vm.pasteText("docker rm -f omniterm-demo >/dev/null 2>&1; printf '%s%s\\n' 'DEMO-' 'GONE'\n")
                    runCatching { await("demo removed", 60_000) { vm.terminalBufferTextFor(live, full = true).contains("DEMO-GONE") } }
                }
            }
            onMain {
                vm.closeAllSessions()
                vm.saveBackgroundKeepAliveToggle(previousKeepAlive)
                vm.saveFlagSecureToggle(previousFlagSecure)
            }
            runCatching {
                demoId?.let { repository.getAllServers().filter { s -> s.id == it }.forEach { s -> repository.deleteServerAndDependents(s.id) } }
            }
            TerminalSessionManager.clearAll()
        }
    }

    private fun latestHeartbeat(buffer: String): Int =
        Regex("session heartbeat (\\d{4})").findAll(buffer).lastOrNull()?.groupValues?.get(1)?.toIntOrNull() ?: -1

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
