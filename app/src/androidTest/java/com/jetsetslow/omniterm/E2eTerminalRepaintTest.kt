package com.jetsetslow.omniterm

import android.app.Application
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.term.TermRow
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What the terminal draws after a real SSH host's output, on a device: the screen shown is the
 * snapshot the terminal canvas paints ([ShellSession.terminalScreen]), compared with what the
 * emulator holds. Uses only APIs the release before these fixes had, so the same test runs against
 * both builds.
 *
 * Opt in with `-e omniterm_e2e_repaint yes`; needs the lab host `E2E Foreground Demo`.
 * `-e rounds N` sets the burst rounds (default 200).
 */
@RunWith(AndroidJUnit4::class)
class E2eTerminalRepaintTest {

    /**
     * Bursts of 40 small chunks 1-9 ms apart (plus the remote's own delay), each ending on a marker
     * with nothing after it for 1 s: the way a TUI animates, sends its last frame and goes quiet.
     * The gaps vary, so the last chunk lands at a different point of the 16 ms publish cadence each
     * round. Every marker must be on screen while the remote is quiet, without any touch, key or
     * resize.
     */
    @Test
    fun theLastUpdateOfEveryBurstIsShown() = withLabShell { vm, session ->
        val rounds = InstrumentationRegistry.getArguments().getString("rounds")?.toIntOrNull() ?: 200
        vm.pasteText(
            "clear; r=1; while [ \$r -le $rounds ]; do i=1; while [ \$i -le 40 ]; do " +
                "printf '\\033[H%05d' \$i; sleep 0.00\$((RANDOM % 9 + 1)); i=\$((i+1)); done; " +
                "printf '\\033[HDONE%04d' \$r; sleep 1; r=\$((r+1)); done\n",
        )
        var missed = 0
        val missedRounds = mutableListOf<Int>()
        for (round in 1..rounds) {
            val marker = "DONE%04d".format(round)
            await("round $round reached the emulator", 30_000) { emulatorScreen(session).any { marker in it } }
            // The remote is quiet now for 1 s; look well inside that.
            delay(400)
            val drawn = withContext(Dispatchers.Main) { session.terminalScreen.rows.map(::text) }
            if (drawn.none { marker in it }) {
                missed++
                missedRounds += round
            }
        }
        Log.i(TAG, "repaint: $missed of $rounds bursts left their last update off the screen $missedRounds")
        assertEquals("bursts whose last update was not drawn: $missedRounds", 0, missed)
    }

    /** Emoji widths, DEC line drawing and a mode query, as drawn. */
    @Test
    fun widthsLineDrawingAndQueriesAreDrawnAsTuisExpect() = withLabShell { vm, session ->
        vm.pasteText("clear; printf 'W\\342\\234\\205x\\nP\\360\\237\\226\\245y\\nB\\033(0lqk\\033(B\\nQ\\033[?2026\$pOK\\nR\\033[>4;2mz\\n'; sleep 30\n")
        await("output reached the emulator", 20_000) { emulatorScreen(session).any { it.startsWith("R") } }
        delay(500)
        val rows = withContext(Dispatchers.Main) { session.terminalScreen.rows }
        fun row(prefix: String) = rows.firstOrNull { text(it).startsWith(prefix) && !text(it).contains("printf") }
        val emoji = requireNotNull(row("W")) { "no W row in ${rows.map(::text)}" }
        val pictograph = requireNotNull(row("P"))
        val box = requireNotNull(row("B"))
        val query = requireNotNull(row("Q"))
        val sgr = requireNotNull(row("R"))
        val report = "✅ widths ${widths(emoji)}, 🖥 widths ${widths(pictograph)}, box '${text(box)}', " +
            "query '${text(query)}', modifyOtherKeys dim=${sgr.spans.any { it.dim && 'z' in it.text }}"
        Log.i(TAG, "drawn: $report")
        assertEquals(report, listOf(1, 2, 1), widths(emoji))
        assertEquals(report, listOf(1, 1, 1), widths(pictograph))
        assertEquals(report, "B┌─┐", text(box))
        assertEquals(report, "QOK", text(query))
        assertEquals(report, false, sgr.spans.any { it.dim && 'z' in it.text })
    }

    /** 50,000 lines of mixed text, timed from sending the command to its end marker on screen. */
    @Test
    fun fiftyThousandLines() = withLabShell { vm, session ->
        val times = mutableListOf<Long>()
        repeat(3) { run ->
            val marker = "THROUGHPUT-END-$run"
            val started = SystemClock.elapsedRealtime()
            vm.pasteText(
                "awk 'BEGIN{for(i=1;i<=50000;i++) printf \"line %d abcdefghijklmnopqrstuvwxyz 0123456789 caf\\303\\251 \\346\\235\\261 \\342\\234\\205\\n\", i; " +
                    "print \"THROUGHPUT\" \"-END-$run\"}'\n",
            )
            await("$marker drawn", 180_000) {
                withContext(Dispatchers.Main) { session.terminalScreen.rows.any { text(it).startsWith(marker) } }
            }
            times += SystemClock.elapsedRealtime() - started
            delay(1_000)
        }
        Log.i(TAG, "throughput: 50,000 lines drawn in ${times.joinToString()} ms (median ${times.sorted()[1]} ms)")
    }

    private fun text(row: TermRow) = row.spans.joinToString("") { it.text }.trimEnd()

    private fun widths(row: TermRow) = row.spans.flatMap { it.cellLayout().second }.take(3)

    private fun emulatorScreen(session: ShellSession): List<String> = synchronized(session.emulator) {
        val e = session.emulator
        e.snapshotRange(e.scrollbackRowCount(), e.rows).rows.map(::text)
    }

    private fun withLabShell(block: suspend (AppViewModel, ShellSession) -> Unit) = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_repaint") == "yes")
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val vm = AppViewModel(app)
        TerminalSessionManager.clearAll()
        try {
            await("lab host", 15_000) { vm.servers.value.any { it.name == HOST } }
            val host = requireNotNull(vm.servers.value.find { it.name == HOST })
            withContext(Dispatchers.Main) {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = host.id
                vm.connectTerminal()
                if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
            }
            await("connected", 25_000) { !vm.isTerminalConnecting && vm.currentSession?.isConnected == true }
            assertNull(vm.terminalConnectError)
            val session = requireNotNull(vm.currentSession)
            await("prompt", 15_000) { vm.terminalBufferTextFor(session, full = true).isNotBlank() }
            block(vm, session)
        } finally {
            withContext(Dispatchers.Main) { TerminalSessionManager.clearAll() }
        }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(50) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not happen within ${timeoutMs}ms", failure)
        }
    }

    private companion object {
        const val TAG = "OmniTermRepaint"
        const val HOST = "E2E Foreground Demo"
    }
}
