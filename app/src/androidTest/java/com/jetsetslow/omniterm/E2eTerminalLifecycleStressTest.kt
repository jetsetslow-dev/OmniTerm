package com.jetsetslow.omniterm

import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.MultiSshLayout
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertSame
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Activity/task lifecycle stress for a mixed normal+tmux split terminal. */
class E2eTerminalLifecycleStressTest {
    @Test
    fun quietRegularTmuxResumeShowsItsExistingScreenBeforeAnyInput() = checkQuietResume(controlMode = false)

    @Test
    fun quietControlTmuxResumeShowsItsExistingScreenBeforeAnyInput() = checkQuietResume(controlMode = true)

    private fun checkQuietResume(controlMode: Boolean) = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_lifecycle") == "yes")
        TerminalSessionManager.clearAll()
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val vm = scenario.viewModel()
        try {
            await("fixture host", 15_000) { vm.servers.value.any { it.name == PERSISTENT } }
            scenario.onActivity {
                vm.isAppLocked = false
                vm.saveTmuxControlMode(controlMode)
                vm.selectedServerId = vm.servers.value.first { it.name == PERSISTENT }.id
                vm.navigateTo(Screen.Shell)
                vm.connectTerminal()
            }
            await("initial shell", 30_000) {
                scenario.onActivity {
                    if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
                    if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
                }
                !vm.isTerminalConnecting && vm.currentSession?.isConnected == true
            }
            val original = requireNotNull(vm.currentSession)
            if (controlMode) await("initial control ready", 15_000) { original.controlReady }
            val nonce = System.nanoTime()
            val token = "quiet-$nonce"
            scenario.onActivity { vm.pasteText("printf 'quiet-%s\\n' '$nonce'\n") }
            await("quiet screen content", 10_000) { vm.terminalBufferTextFor(original, full = true).contains(token) }
            scenario.onActivity { vm.leaveSessionResumable(original.id) }
            await("detached with recovery pointer", 10_000) {
                vm.activeSessions.none { it.id == original.id } &&
                    vm.restorablePersistentSessions.any { it.tmuxName == original.tmuxName }
            }
            val started = android.os.SystemClock.elapsedRealtime()
            scenario.onActivity { vm.resumePersistentSession(original.tmuxName) }
            await("resumed shell", 15_000) { !vm.isTerminalConnecting && vm.currentSession?.isConnected == true }
            val resumed = requireNotNull(vm.currentSession)
            assertEquals(original.tmuxName, resumed.tmuxName)
            assertEquals(controlMode, resumed.controlMode)
            if (controlMode) await("resumed control ready", 15_000) { resumed.controlReady }
            // No typing or explicit resize after resume: tmux's attach redraw must suffice.
            await("quiet redraw without input", 10_000) {
                synchronized(resumed.emulator) {
                    vm.terminalBufferTextFor(
                        resumed, full = false,
                        firstRow = resumed.emulator.scrollbackRowCount(), rowCount = resumed.emulator.rows,
                    ).contains(token)
                }
            }
            android.util.Log.i("OmniTermResumeTest", "Quiet tmux resume (control=$controlMode) ready in ${android.os.SystemClock.elapsedRealtime() - started}ms")
            scenario.onActivity { vm.disconnectSession(resumed.id) }
            await("session removed", 10_000) { vm.activeSessions.none { it.id == resumed.id } }
        } finally {
            TerminalSessionManager.clearAll()
            scenario.close()
        }
    }

    @Test
    fun windowSwitchesKeepTheSameSshChannels() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_lifecycle") == "yes")
        TerminalSessionManager.clearAll()
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val vm = scenario.viewModel()
        try {
            await("fixture hosts", 15_000) {
                vm.servers.value.any { it.name == DIRECT } && vm.servers.value.any { it.name == PERSISTENT }
            }
            for ((persistent, control) in listOf(false to false, true to false, true to true)) {
                val host = vm.servers.value.first { it.name == if (persistent) PERSISTENT else DIRECT }
                scenario.onActivity {
                    vm.isAppLocked = false
                    vm.saveTmuxControlMode(control)
                    vm.selectedServerId = host.id
                    vm.navigateTo(Screen.Shell)
                    vm.connectTerminal()
                }
                await("shell connected", 30_000) {
                    scenario.onActivity {
                        if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
                        if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
                    }
                    !vm.isTerminalConnecting && vm.currentSession?.persistent == persistent &&
                        vm.currentSession?.controlMode == control && vm.currentSession?.isConnected == true
                }
                val session = requireNotNull(vm.currentSession)
                val channel = session.session
                if (control) await("control client ready", 20_000) { session.controlReady }
                repeat(3) { cycle ->
                    scenario.onActivity { vm.pasteText("printf 'switch-%s-ok\\n' '$cycle'\n") }
                    await("shell output", 10_000) {
                        vm.terminalBufferTextFor(session, full = true).contains("switch-$cycle-ok")
                    }
                    scenario.moveToState(Lifecycle.State.CREATED)
                    delay(1_000)
                    scenario.moveToState(Lifecycle.State.RESUMED)
                    scenario.recreate()
                    assertSame("App switching reopened SSH (tmux=$persistent control=$control)", channel, session.session)
                    assertTrue("App switching disconnected SSH", session.isConnected)
                    assertFalse("App switching started reconnect", session.reconnecting)
                }
                scenario.onActivity { vm.disconnectSession(session.id) }
                await("shell removed", 10_000) { vm.activeSessions.none { it.id == session.id } }
            }
        } finally {
            TerminalSessionManager.clearAll()
            scenario.close()
        }
    }

    @Test
    fun mixedSplitSurvivesHomeScreenOffRecreationAndLiteralRecentsSwipe() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = E2eAccessibility(instrumentation)
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_lifecycle") == "yes")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            instrumentation.targetContext.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            instrumentation.uiAutomation.executeShellCommand(
                "pm grant ${instrumentation.targetContext.packageName} android.permission.POST_NOTIFICATIONS",
            ).close()
        }
        val originalAutoRotation = shellOutput("settings get system accelerometer_rotation").trim()
        val originalUserRotation = shellOutput("settings get system user_rotation").trim()
        instrumentation.uiAutomation.executeShellCommand("settings put system accelerometer_rotation 0").close()
        instrumentation.uiAutomation.executeShellCommand("settings put system user_rotation 0").close()
        delay(1_000)
        TerminalSessionManager.clearAll()
        var scenario = ActivityScenario.launch(MainActivity::class.java)
        var scenarioClosed = false
        var resumedAfterSwipe: MainActivity? = null
        var vm = scenario.viewModel()

        await("seeded hosts", 15_000) {
            vm.servers.value.any { it.name == DIRECT } && vm.servers.value.any { it.name == PERSISTENT }
        }
        val directHost = requireNotNull(vm.servers.value.find { it.name == DIRECT })
        val persistentHost = requireNotNull(vm.servers.value.find { it.name == PERSISTENT })

        try {
            vm.navigateTo(Screen.Shell)
            vm.selectedServerId = directHost.id
            vm.connectTerminal()
            await("normal connect", 20_000) { !vm.isTerminalConnecting && vm.currentSession != null }
            val direct = requireNotNull(vm.currentSession)
            assertFalse(direct.persistent)

            vm.selectedServerId = persistentHost.id
            vm.connectTerminal()
            await("tmux connect", 25_000) {
                !vm.isTerminalConnecting && vm.activeSessions.any { it.serverId == persistentHost.id }
            }
            val persistent = requireNotNull(vm.activeSessions.find { it.serverId == persistentHost.id })
            assertTrue(persistent.persistent)
            vm.attachSession(persistent.id)
            vm.enterMultiSsh()
            if (vm.multiSshSessionId1 != direct.id) vm.swapMultiSshPanes()
            vm.multiSshLayout = MultiSshLayout.Stacked
            vm.setMultiSshFocus(2)
            assertEquals(listOf(direct.id, persistent.id), listOf(vm.multiSshSessionId1, vm.multiSshSessionId2))

            // The toolbar exposes the correct non-destructive action directly for each focused
            // pane. Disconnect is a separate, destructive gate and must never hide Background or
            // Leave-resumable choices inside its confirmation dialog.
            await("tmux leave toolbar action", 10_000) {
                device.hasDescription("Leave current tmux session resumable")
            }
            device.clickDescription("Disconnect current session")
            await("pure tmux disconnect gate", 5_000) { device.hasText("Terminate tmux session?") }
            assertFalse(device.hasText("Leave resumable"))
            device.clickText("Cancel")

            vm.setMultiSshFocus(1)
            await("ordinary background toolbar action", 10_000) {
                device.hasDescription("Send current session to background")
            }
            device.clickDescription("Disconnect current session")
            await("pure ordinary disconnect gate", 5_000) { device.hasText("Disconnect session?") }
            assertFalse(device.hasText("Send to background"))
            device.clickText("Cancel")
            vm.setMultiSshFocus(2)

            vm.pasteText("(sleep 2; printf 'TMUX-DURING-HOME\\n') &\n")
            scenario.moveToState(Lifecycle.State.CREATED)
            delay(3_000)
            assertEquals(2, TerminalSessionManager.activeSessions.size)
            scenario.moveToState(Lifecycle.State.RESUMED)
            await("tmux output after Home", 10_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("TMUX-DURING-HOME")
            }

            // Display sleep/wake tears down and rebuilds IME/window focus without destroying SSH.
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_POWER").close()
            delay(1_000)
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_POWER").close()
            instrumentation.uiAutomation.executeShellCommand("wm dismiss-keyguard").close()
            delay(1_000)
            scenario.moveToState(Lifecycle.State.RESUMED)
            assertEquals(2, vm.activeSessions.size)

            // Configuration recreation must retain pane order, layout, focus, and live streams.
            val beforeRecreate = vm
            scenario.recreate()
            vm = scenario.viewModel()
            assertEquals(beforeRecreate, vm)
            assertEquals(1, vm.activeSshTab)
            assertEquals(direct.id, vm.multiSshSessionId1)
            assertEquals(persistent.id, vm.multiSshSessionId2)
            assertEquals(MultiSshLayout.Stacked, vm.multiSshLayout)
            assertEquals(2, vm.multiSshFocusedPane)

            // Literal system Recents path on this physical device. Locking portrait makes
            // Quickstep and ADB share the same coordinate space; the accessibility snapshot's
            // disappearance is the authoritative swipe-dismiss signal even if ActivityScenario
            // retains its controlled Activity instance for instrumentation.
            val (displayWidth, displayHeight) = physicalDisplaySize()
            instrumentation.uiAutomation.executeShellCommand("input keyevent KEYCODE_APP_SWITCH").close()
            delay(1_000)
            assertTrue("OmniTerm card missing before Recents swipe", recentsContainsOmniTermCard())
            instrumentation.uiAutomation.executeShellCommand(
                "input swipe ${displayWidth / 2} ${(displayHeight * 2) / 3} " +
                    "${displayWidth / 2} ${displayHeight / 12} 200",
            ).close()
            await("OmniTerm card dismissed from Recents", 10_000) { !recentsContainsOmniTermCard() }
            await("sessions after Recents swipe", 10_000) { TerminalSessionManager.activeSessions.size == 2 }

            // Retire the old scenario's lifecycle monitor BEFORE the notification creates a new
            // Activity of the same class. Otherwise it observes that unrelated Activity's STARTED
            // event with no owned instance, and close() fails with a null-current-state NPE.
            scenario.close()
            scenarioClosed = true

            val notifications = instrumentation.targetContext.getSystemService(NotificationManager::class.java)
            val persistentNotification = requireNotNull(
                notifications.activeNotifications.find { it.id == persistent.id.hashCode() },
            ) { "Persistent terminal notification missing after Recents swipe" }
            requireNotNull(persistentNotification.notification.contentIntent) {
                "Persistent terminal notification has no resume action"
            }.send()
            await("notification resumed Activity", 15_000) {
                resumedAfterSwipe = resumedMainActivity()
                resumedAfterSwipe != null
            }
            vm = ViewModelProvider(requireNotNull(resumedAfterSwipe))[AppViewModel::class.java]
            assertEquals(1, vm.activeSshTab)
            assertEquals(direct.id, vm.multiSshSessionId1)
            assertEquals(persistent.id, vm.multiSshSessionId2)
            assertEquals(MultiSshLayout.Stacked, vm.multiSshLayout)
            assertEquals(2, vm.multiSshFocusedPane)
            vm.navigateTo(Screen.Shell)

            vm.pasteText("printf 'TMUX-AFTER-RECENTS-SWIPE\\n'\n")
            await("tmux usable after Recents swipe", 10_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("TMUX-AFTER-RECENTS-SWIPE")
            }
            vm.setMultiSshFocus(1)
            vm.pasteText("printf 'NORMAL-AFTER-RECENTS-SWIPE\\n'\n")
            await("normal usable after Recents swipe", 10_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("NORMAL-AFTER-RECENTS-SWIPE")
            }
        } finally {
            TerminalSessionManager.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal cleanup", 20_000) { TerminalSessionManager.activeSessions.isEmpty() }
            if (!scenarioClosed) scenario.close()
            resumedAfterSwipe?.let { activity ->
                instrumentation.runOnMainSync { activity.finishAndRemoveTask() }
            }
            TerminalSessionManager.clearAll()
            instrumentation.uiAutomation.executeShellCommand(
                "settings put system user_rotation ${originalUserRotation.ifBlank { "0" }}",
            ).close()
            instrumentation.uiAutomation.executeShellCommand(
                "settings put system accelerometer_rotation ${originalAutoRotation.ifBlank { "1" }}",
            ).close()
        }
    }

    private fun ActivityScenario<MainActivity>.viewModel(): AppViewModel {
        val result = AtomicReference<AppViewModel>()
        onActivity { result.set(ViewModelProvider(it)[AppViewModel::class.java]) }
        return result.get()
    }

    private fun resumedMainActivity(): MainActivity? {
        val result = AtomicReference<MainActivity?>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            result.set(
                ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>()
                    .firstOrNull(),
            )
        }
        return result.get()
    }

    private fun physicalDisplaySize(): Pair<Int, Int> {
        val output = shellOutput("wm size")
        val match = requireNotNull(Regex("Physical size: (\\d+)x(\\d+)").find(output)) {
            "Could not parse physical display size: $output"
        }
        return match.groupValues[1].toInt() to match.groupValues[2].toInt()
    }

    private fun recentsContainsOmniTermCard(): Boolean {
        val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow ?: return false
        fun containsCard(node: android.view.accessibility.AccessibilityNodeInfo): Boolean {
            if (node.contentDescription?.toString() == "OmniTerm") return true
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                if (containsCard(child)) return true
            }
            return false
        }
        return containsCard(root)
    }

    private fun shellOutput(command: String): String {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                while (!predicate()) delay(100)
            }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", timeout)
        }
    }

    private companion object {
        const val DIRECT = "E2E Foreground Demo"
        const val PERSISTENT = "E2E Split Persistent"
    }
}
