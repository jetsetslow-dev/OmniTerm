package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Replay of a REAL tmux client byte stream, captured from `tmux new-session` running a program that
 * enters and leaves the alternate screen (`tput smcup` / `tput rmcup`).
 *
 * This is the shape the app actually receives when attached to tmux, and it is NOT the plain
 * 1049h/1049l pair: tmux absorbs the inner program's alternate-screen switches entirely and instead
 * repaints its pane with `ESC[H` followed by per-row `ESC[K`, then positions the cursor with VPA
 * (`ESC[2d`). If any of those are mishandled, the old rows survive while the cursor sits at the top,
 * so the next shell output overlaps stale text.
 */
class TmuxInnerTuiExitReplayTest {

    private fun visible(e: TerminalEmulator): List<String> =
        e.snapshot().rows.map { r -> r.spans.joinToString("") { it.text }.trimEnd() }
            .filter { it.isNotBlank() }

    @Test
    fun innerTuiExitLeavesNoStaleTextAndTmuxRepaintLands() {
        val e = TerminalEmulator(80, 24, scrollbackLimit = 500)
        val stream =
            "\u001B[?1049h\u001B[?1h\u001B=\u001B[H\u001B[J\u001B[34h\u001B[?25h\u001B[?1000l\u001B[?1002l\u001B[" +
            "?1003l\u001B[?1006l\u001B[?1005l\u001B[m\u000F\u001B[34h\u001B[?25h\u001B[?1006l\u001B[?1000l\u001B[" +
            "?1002l\u001B[?1003l\u001B[?2004l\u001B[1;1H\u001B[1;24r\u001B[>c\u001B[>q\u001B[1;1H\u001B[?25l" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\u001B[30m\u001B[42m" +
            "\r\n[cap3] 0:bash*                                       \"escapepod\" 04:16 25-Jul-26\u001B[m" +
            "\u000F\u001B[34h\u001B[?25h\u001B[1;1H\u001B[m\u000F\u001B[34h\u001B[?25h\u001B[?1006l\u001B[?1000l" +
            "\u001B[?1002l\u001B[?1003l\u001B[?2004l\u001B[1;1H\u001B[1;24r\u001B[2;1H\u001B[?25l\u001B[Hshell-be" +
            "fore-line\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[" +
            "K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r" +
            "\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\u001B[30m\u001B[4" +
            "2m\r\n[cap3] 0:bash*                                       \"escapepod\" 04:16 25-Jul-26\u001B[m" +
            "\u000F\u001B[34h\u001B[?25h\u001B[2;1H\u001B[?25l\u001B[H\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[" +
            "K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r" +
            "\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\u001B[34h\u001B[?25h\u001B[2dINNERTUIPAINT\u001B[?25l\u001B[H" +
            "\u001B[K\r\nINNERTUIPAINT\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\u001B[3" +
            "0m\u001B[42m\r\n[cap3] 0:bash*                                       \"escapepod\" 04:16 25-Jul-26" +
            "\u001B[m\u000F\u001B[34h\u001B[?25h\u001B[2;14H\u001B[?25l\u001B[Hshell-before-line\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n" +
            "\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\r\n\u001B[K\u001B[34h\u001B[?25h\u001B[2dsh" +
            "ell-after-line"
        e.feed(stream.toByteArray())

        val rows = visible(e)
        // tmux erased its TUI paint during the repaint, so it must not survive in our grid.
        assertFalse("Inner TUI text survived tmux's repaint: $rows",
            rows.any { it.contains("INNERTUIPAINT") })
        assertTrue("tmux's post-exit shell output is missing: $rows",
            rows.any { it.contains("shell-after-line") })
    }
}
