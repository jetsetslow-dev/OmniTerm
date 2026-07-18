package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Reproduces the field report "scroll history is missing / typing breaks after idling in tmux"
 * with an Ink-style workload (what the Claude CLI does): committed transcript lines above a
 * cursor-up + erase-down redrawn frame, followed by idle-then-type checks.
 *
 * Assertions are made against the emulator's full buffer and scrollback row counts — the exact
 * data the scroll viewport renders — so a "history missing completely" outcome is caught as
 * missing early lines or an empty scrollback, and an idle input stall is caught as a missing
 * echo marker.
 */
@RunWith(AndroidJUnit4::class)
class E2eTerminalScrollHistoryReproTest {
    @Test
    fun inkStyleRedrawKeepsHistoryAndIdleTypingStillEchoes() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_scroll_repro") == "yes")
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val vm = AppViewModel(app)
        TerminalSessionManager.clearAll()

        await("seeded hosts", 15_000) {
            vm.servers.value.any { it.name == DIRECT } && vm.servers.value.any { it.name == PERSISTENT }
        }
        val directHost = requireNotNull(vm.servers.value.find { it.name == DIRECT })
        val persistentHost = requireNotNull(vm.servers.value.find { it.name == PERSISTENT })

        try {
            // ---- Plain (non-tmux) session ----
            vm.navigateTo(Screen.Shell)
            vm.selectedServerId = directHost.id
            vm.connectTerminal()
            // A stale offline probe raises the confirm gate instead of dialing; take it.
            if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
            await("plain connect", 25_000) { !vm.isTerminalConnecting && vm.currentSession != null }
            assertNull(vm.terminalConnectError)
            val direct = requireNotNull(vm.currentSession)
            await("plain prompt", 10_000) { vm.terminalBufferTextFor(direct, full = true).isNotBlank() }

            vm.pasteText(inkWorkload(prefix = "P", doneMarker = "PLAIN-DONE"))
            await("plain ink workload", 60_000) {
                vm.terminalBufferTextFor(direct, full = true).contains("PLAIN-DONE")
            }
            val plainFull = vm.terminalBufferTextFor(direct, full = true)
            val plainDiag = diag(direct, plainFull, "P")
            assertTrue("plain: early history lost [$plainDiag]", plainFull.contains("PHIST-0001"))
            assertTrue("plain: first transcript line lost [$plainDiag]", plainFull.contains("PTRANS-001"))
            assertTrue("plain: last transcript line lost [$plainDiag]", plainFull.contains("PTRANS-050"))
            val plainScrollback = synchronized(direct.emulator) { direct.emulator.scrollbackRowCount() }
            assertTrue("plain: scrollback empty after workload ($plainScrollback rows)", plainScrollback > 0)

            // Idle, then type: the echo must come back promptly.
            delay(7_000)
            val lenBeforeIdlePaste = vm.terminalBufferTextFor(direct, full = true).length
            vm.pasteText("printf '%s%s\\n' 'IDLE-PLAIN' '-OK'\n")
            try {
                await("plain idle echo", 10_000) {
                    vm.terminalBufferTextFor(direct, full = true).contains("IDLE-PLAIN-OK")
                }
            } catch (e: AssertionError) {
                val after = vm.terminalBufferTextFor(direct, full = true)
                throw AssertionError(
                    "plain idle echo missing: lenBefore=$lenBeforeIdlePaste lenAfter=${after.length} " +
                        "active=${vm.activeSessions.any { it.id == direct.id }} " +
                        "current=${vm.currentSession?.id == direct.id} " +
                        "connecting=${vm.isTerminalConnecting} " +
                        "connectError=${vm.terminalConnectError != null} " +
                        "userClosed=${direct.userClosed} " +
                        "queueClosed=${direct.terminalInputQueue?.closed} " +
                        "queuedBytes=${direct.terminalInputQueue?.queuedBytes}",
                    e,
                )
            }

            // ---- tmux (persistent) session ----
            vm.selectedServerId = persistentHost.id
            vm.connectTerminal()
            if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
            await("tmux connect", 30_000) {
                !vm.isTerminalConnecting && vm.activeSessions.count { it.serverId == persistentHost.id } == 1
            }
            assertNull(vm.terminalConnectError)
            val tmux = requireNotNull(vm.activeSessions.find { it.serverId == persistentHost.id })
            assertTrue(tmux.persistent)
            vm.attachSession(tmux.id)
            await("tmux paint", 15_000) { vm.terminalBufferTextFor(tmux, full = true).isNotBlank() }

            vm.pasteText(inkWorkload(prefix = "T", doneMarker = "TMUXREPRO-DONE"))
            await("tmux ink workload", 90_000) {
                vm.terminalBufferTextFor(tmux, full = true).contains("TMUXREPRO-DONE")
            }
            val tmuxLiveFull = vm.terminalBufferTextFor(tmux, full = true)
            assertTrue("tmux live: early history lost", tmuxLiveFull.contains("THIST-0001"))
            assertTrue("tmux live: transcript lost", tmuxLiveFull.contains("TTRANS-050"))

            // The exact path a scroll-up takes: re-arm dirty and adopt capture-pane history.
            tmux.scrollbackDirty = true
            vm.resyncTmuxScrollbackFor(tmux)
            val tmuxResynced = vm.terminalBufferTextFor(tmux, full = true)
            val tmuxScrollback = synchronized(tmux.emulator) { tmux.emulator.scrollbackRowCount() }
            assertTrue("tmux resync: scrollback empty ($tmuxScrollback rows)", tmuxScrollback > 0)
            assertTrue("tmux resync: early history missing", tmuxResynced.contains("THIST-0001"))
            assertTrue("tmux resync: transcript missing", tmuxResynced.contains("TTRANS-050"))

            // Idle, then type — the reported break: input after a few quiet seconds in tmux.
            delay(7_000)
            vm.pasteText("printf '%s%s\\n' 'IDLE-TMUX' '-OK'\n")
            await("tmux idle echo", 10_000) {
                vm.terminalBufferTextFor(tmux, full = true).contains("IDLE-TMUX-OK")
            }

            // Second, longer idle with a scroll-up in between (mirrors the user flow: scroll,
            // read, come back and type).
            tmux.scrollbackDirty = true
            vm.resyncTmuxScrollbackFor(tmux)
            delay(10_000)
            vm.pasteText("printf '%s%s\\n' 'IDLE-TMUX' '-AGAIN'\n")
            await("tmux second idle echo", 10_000) {
                vm.terminalBufferTextFor(tmux, full = true).contains("IDLE-TMUX-AGAIN")
            }
        } finally {
            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal cleanup", 20_000) { vm.activeSessions.isEmpty() }
            TerminalSessionManager.clearAll()
        }
    }

    /**
     * Ink-style workload: 250 committed history lines, then 50 iterations that each commit one
     * transcript line and redraw an 8-line frame in place (cursor-up 7 + CR + erase-down), the
     * way Ink-based CLIs like Claude Code paint. Ends with [doneMarker].
     */
    private fun inkWorkload(prefix: String, doneMarker: String): String =
        "i=1; while [ \$i -le 250 ]; do printf '${prefix}HIST-%04d\\n' \"\$i\"; i=\$((i+1)); done; " +
            "j=1; while [ \$j -le 50 ]; do " +
            "printf '${prefix}TRANS-%03d\\n' \"\$j\"; " +
            "printf 'FA\\nFB\\nFC\\nFD\\nFE\\nFF\\nFG\\nSPIN-%03d' \"\$j\"; " +
            "sleep 0.05; " +
            "printf '\\033[7A\\r\\033[J'; " +
            // The marker is assembled from two printf args so the awaited string never appears in
            // the pasted command's own echo (which otherwise satisfies the await before execution).
            "j=\$((j+1)); done; printf '%s%s\\n' '${doneMarker.substringBefore("-")}-' '${doneMarker.substringAfter("-")}'\n"

    /** Sanitized state summary: marker presence + row counts only, never raw buffer content. */
    private fun diag(session: com.jetsetslow.omniterm.ui.ShellSession, text: String, prefix: String): String {
        val (scrollbackRows, totalRows, screenRows, limit) = synchronized(session.emulator) {
            listOf(
                session.emulator.scrollbackRowCount(),
                session.emulator.rowCount(),
                session.emulator.rows,
                -1,
            )
        }
        val markers = listOf(
            "${prefix}HIST-0001", "${prefix}HIST-0100", "${prefix}HIST-0250",
            "${prefix}TRANS-001", "${prefix}TRANS-025", "${prefix}TRANS-050", "SPIN-050",
        )
        return "scrollback=$scrollbackRows total=$totalRows screen=$screenRows limit=$limit len=${text.length} " +
            markers.joinToString(" ") { m -> "$m=${text.contains(m)}" }
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
