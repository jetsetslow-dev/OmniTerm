package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TermKey
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Opt-in physical-device terminal soak against the disposable RPi lab.
 *
 * This deliberately combines a normal SSH session and a persistent tmux session because the mixed
 * leave-terminal decision is where background-vs-resumable behavior can otherwise drift apart.
 */
@RunWith(AndroidJUnit4::class)
class E2eTerminalStressTest {
    @Test
    fun mixedSplitBackgroundAndTmuxResumeSurviveHeavyOutputAndResizeChurn() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_terminal") == "yes")
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val vm = AppViewModel(app)
        TerminalSessionManager.clearAll()

        await("seeded hosts", 15_000) {
            vm.servers.value.any { it.name == DIRECT } && vm.servers.value.any { it.name == PERSISTENT }
        }
        val directHost = requireNotNull(vm.servers.value.find { it.name == DIRECT })
        val persistentHost = requireNotNull(vm.servers.value.find { it.name == PERSISTENT })

        try {
            vm.navigateTo(Screen.Shell)
            vm.selectedServerId = directHost.id
            vm.connectTerminal()
            await("normal SSH connect", 20_000) { !vm.isTerminalConnecting && vm.currentSession != null }
            assertNull(vm.terminalConnectError)
            val direct = requireNotNull(vm.currentSession)
            assertFalse(direct.persistent)
            await("normal shell prompt", 10_000) { vm.terminalBufferTextFor(direct, full = true).isNotBlank() }

            // Fast output, wide lines, ANSI colour, Unicode and a no-newline tail exercise the
            // emulator, UTF-8 chunk decoder, scrollback cap and full-buffer joining together.
            vm.pasteText(
                "printf 'DIRECT-BEGIN\\n'; " +
                    "i=1; while [ \$i -le 3500 ]; do " +
                    "printf '\\033[3%smD%04d | %s | café-東京-🙂 | %0120d\\033[0m\\n' " +
                    "\"\$((i % 7 + 1))\" \"\$i\" \"\$(printf x%04d \"\$i\")\" \"\$i\"; " +
                    "i=\$((i+1)); done; printf 'DIRECT-END-no-newline'\n"
            )
            await("normal SSH heavy output", 45_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("DIRECT-END-no-newline")
            }

            // Resize bursts model split orientation flips, IME show/hide and rotation. The
            // conflated resize channel must settle on the final dimensions without stale packets.
            repeat(120) { index ->
                val cols = listOf(24, 37, 80, 119, 160)[index % 5]
                val rows = listOf(6, 12, 24, 41, 60)[(index * 3) % 5]
                vm.resizeTerminalFor(direct, cols, rows)
            }
            vm.resizeTerminalFor(direct, 93, 31)
            await("normal SSH final resize", 10_000) { direct.termCols == 93 && direct.termRows == 31 }
            vm.pasteText("printf '\\nDIRECT-AFTER-RESIZE\\n'\n")
            await("normal SSH after resize", 10_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("DIRECT-AFTER-RESIZE")
            }

            // Connecting a second session must not disturb the first. Entering split afterwards
            // binds both live sessions, then one navigation decision applies the correct policy to
            // each: normal SSH -> background, persistent SSH -> detached/resumable.
            vm.selectedServerId = persistentHost.id
            vm.connectTerminal()
            await("persistent SSH connect", 25_000) {
                !vm.isTerminalConnecting && vm.activeSessions.count { it.serverId == persistentHost.id } == 1
            }
            assertNull(vm.terminalConnectError)
            val persistent = requireNotNull(vm.activeSessions.find { it.serverId == persistentHost.id })
            assertTrue(persistent.persistent)
            vm.attachSession(persistent.id)
            await("tmux initial paint", 15_000) { vm.terminalBufferTextFor(persistent, full = true).isNotBlank() }
            vm.pasteText(
                "printf 'TMUX-BEGIN\\n'; " +
                    "i=1; while [ \$i -le 4500 ]; do " +
                    "printf 'T%04d | %0160d | résumé-Δ-界\\n' \"\$i\" \"\$i\"; i=\$((i+1)); done; " +
                    "(sleep 4; printf 'TMUX-WHILE-PARKED\\n') & " +
                    "printf 'TMUX-BEFORE-PARK\\n'\n"
            )
            await("tmux heavy output", 55_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("TMUX-BEFORE-PARK")
            }

            vm.enterMultiSsh()
            val paneIds = setOfNotNull(vm.multiSshSessionId1, vm.multiSshSessionId2)
            assertEquals(setOf(direct.id, persistent.id), paneIds)
            vm.navigateTo(Screen.Infra)
            assertTrue(vm.showDisconnectTerminalDialog)
            assertEquals(2, vm.pendingTerminalNavigationSessions.size)
            vm.completeTerminalNavigation(disconnect = false)

            assertEquals(Screen.Infra, vm.currentScreen)
            assertFalse(vm.showDisconnectTerminalDialog)
            assertNotNull(vm.activeSessions.find { it.id == direct.id })
            await("tmux parked and restorable", 10_000) {
                vm.activeSessions.none { it.id == persistent.id } &&
                    vm.restorablePersistentSessions.any { it.tmuxName == persistent.tmuxName }
            }

            // The ordinary shell must still accept traffic while it is off-screen.
            vm.exitMultiSsh()
            vm.attachSession(direct.id)
            vm.pasteText("printf 'DIRECT-BACKGROUND-STILL-LIVE\\n'\n")
            await("background normal SSH remains live", 10_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("DIRECT-BACKGROUND-STILL-LIVE")
            }
            vm.sendSessionToBackground(direct.id)

            delay(5_000)
            vm.resumePersistentSession(persistent.tmuxName)
            // The live pane must become usable promptly; large historical scrollback hydrates in
            // the background and is checked separately below.
            await("tmux resume", 15_000) {
                !vm.isTerminalConnecting && vm.activeSessions.any { it.tmuxName == persistent.tmuxName }
            }
            assertNull(vm.terminalConnectError)
            val resumed = requireNotNull(vm.activeSessions.find { it.tmuxName == persistent.tmuxName })
            await("tmux history hydration", 90_000) {
                resumed.historyHydrationJob?.isCompleted == true
            }
            val resumedText = vm.terminalBufferTextFor(resumed, full = true)
            assertTrue(resumedText.contains("TMUX-BEGIN"))
            assertTrue(resumedText.contains("TMUX-BEFORE-PARK"))
            assertTrue(resumedText.contains("TMUX-WHILE-PARKED"))

            // Scroll state is session-local: scrolling tmux must not arm the ordinary pane.
            vm.terminalMouseWheelFor(resumed, wheelUp = true, ticks = 10)
            assertTrue(resumed.tmuxScrolledBack)
            assertFalse(direct.tmuxScrolledBack)
            vm.terminalJumpToLiveTailFor(resumed)
            assertFalse(resumed.tmuxScrolledBack)

            // Reverse the pane order and take the destructive branch. Both sessions must close,
            // including terminating (not merely parking) the resumed remote tmux session.
            vm.attachSession(direct.id)
            vm.enterMultiSsh()
            vm.assignMultiSshPane(1, direct.id)
            vm.assignMultiSshPane(2, resumed.id)
            vm.navigateTo(Screen.Tools)
            assertEquals(listOf(direct.id, resumed.id), vm.pendingTerminalNavigationSessions.map { it.id })
            vm.completeTerminalNavigation(disconnect = true)
            await("reverse mixed split disconnect", 20_000) { vm.activeSessions.isEmpty() }
            assertEquals(Screen.Tools, vm.currentScreen)
            assertFalse(vm.showDisconnectTerminalDialog)
        } finally {
            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal cleanup", 15_000) { vm.activeSessions.isEmpty() }
            TerminalSessionManager.clearAll()
        }
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
