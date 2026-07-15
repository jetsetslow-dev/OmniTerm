package com.jetsetslow.omniterm

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
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
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Activity/task lifecycle stress for a mixed normal+tmux split terminal. */
class E2eTerminalLifecycleStressTest {
    @Test
    fun mixedSplitSurvivesHomeScreenOffRecreationAndActivityClose() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_lifecycle") == "yes")
        TerminalSessionManager.clearAll()
        var scenario = ActivityScenario.launch(MainActivity::class.java)
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

            // A Recents swipe destroys the task's Activity/ViewModel while the foreground service
            // keeps the process and sessions. Closing and relaunching ActivityScenario models the
            // same ownership boundary deterministically.
            val oldVm = vm
            scenario.close()
            await("sessions after Activity close", 10_000) { TerminalSessionManager.activeSessions.size == 2 }
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = scenario.viewModel()
            assertNotSame(oldVm, vm)
            assertEquals(1, vm.activeSshTab)
            assertEquals(direct.id, vm.multiSshSessionId1)
            assertEquals(persistent.id, vm.multiSshSessionId2)
            assertEquals(MultiSshLayout.Stacked, vm.multiSshLayout)
            assertEquals(2, vm.multiSshFocusedPane)
            vm.navigateTo(Screen.Shell)

            vm.pasteText("printf 'TMUX-AFTER-ACTIVITY-CLOSE\\n'\n")
            await("tmux usable after Activity close", 10_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("TMUX-AFTER-ACTIVITY-CLOSE")
            }
            vm.setMultiSshFocus(1)
            vm.pasteText("printf 'NORMAL-AFTER-ACTIVITY-CLOSE\\n'\n")
            await("normal usable after Activity close", 10_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("NORMAL-AFTER-ACTIVITY-CLOSE")
            }
        } finally {
            TerminalSessionManager.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal cleanup", 20_000) { TerminalSessionManager.activeSessions.isEmpty() }
            scenario.close()
            TerminalSessionManager.clearAll()
        }
    }

    private fun ActivityScenario<MainActivity>.viewModel(): AppViewModel {
        val result = AtomicReference<AppViewModel>()
        onActivity { result.set(ViewModelProvider(it)[AppViewModel::class.java]) }
        return result.get()
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
