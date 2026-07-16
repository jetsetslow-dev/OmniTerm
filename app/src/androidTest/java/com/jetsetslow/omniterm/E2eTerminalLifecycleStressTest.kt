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
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Activity/task lifecycle stress for a mixed normal+tmux split terminal. */
class E2eTerminalLifecycleStressTest {
    @Test
    fun mixedSplitSurvivesHomeScreenOffRecreationAndLiteralRecentsSwipe() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
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
            scenario.close()
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
