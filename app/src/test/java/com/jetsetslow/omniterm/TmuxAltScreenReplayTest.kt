package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Replays a real tmux client byte stream (captured around an inner alt-screen app exiting)
 * through the emulator and asserts the live screen ends clean. Diagnostic scaffold for the
 * "screen doesn't clear after exiting Claude Code" report: the capture file is produced by
 * scratchpad/capture_tmux.py and passed via TMUX_REPLAY_CAPTURE=<path>; the test is skipped
 * when no capture is supplied.
 */
class TmuxAltScreenReplayTest {

    private fun screenText(emulator: TerminalEmulator): String {
        val snap = emulator.snapshot()
        val screenRows = snap.rows.subList(snap.totalRows - emulator.rows, snap.totalRows)
        return screenRows.joinToString("\n") { row -> row.spans.joinToString("") { it.text } }
    }

    @Test
    fun altScreenExitClearsInnerAppContent() {
        val path = System.getenv("TMUX_REPLAY_CAPTURE")
        assumeTrue("no capture provided", !path.isNullOrBlank() && File(path!!).isFile)
        val bytes = File(path).readBytes()
        val emulator = TerminalEmulator(80, 24, scrollbackLimit = 10_000)
        emulator.setCaptureAlternateScreenScrollback(true)
        emulator.feed(bytes)
        emulator.finishInput()
        val screen = screenText(emulator)
        println("=== FINAL SCREEN ===")
        println(screen)
        println("=== END SCREEN (alt=${emulator.isAlternateScreenActive()}) ===")
        assertTrue("prompt after exit missing", screen.contains("AFTER_EXIT_MARKER"))
        assertTrue(
            "stale inner-app text remains on screen",
            !Regex("CLAUDE_STALE_LINE_\\d").containsMatchIn(screen),
        )
    }

    /**
     * Resume flow: OmniTerm paints the visible pane via capture-pane into a fresh emulator
     * (paintTmuxVisibleScreen), then attaches. The captures come from capture_resume.py:
     * the inner alt-screen app was left running at detach, so the paint IS its frame.
     */
    @Test
    fun resumeThenExitInnerAppClearsScreen() {
        val dir = System.getenv("TMUX_RESUME_CAPTURE_DIR")
        assumeTrue("no capture dir provided", !dir.isNullOrBlank() && File(dir!!).isDirectory)
        val paint = File(dir, "resume_paint.txt").readText()
        val cursor = File(dir, "resume_cursor.txt").readText().trim().split(' ')
        val clientBytes = File(dir, "resume_client.bin").readBytes()
        val cx = cursor.getOrNull(0)?.toIntOrNull() ?: 0
        val cy = cursor.getOrNull(1)?.toIntOrNull() ?: 0

        val emulator = TerminalEmulator(80, 24, scrollbackLimit = 10_000)
        emulator.setCaptureAlternateScreenScrollback(true)
        // Exactly what paintTmuxVisibleScreen feeds before the attach stream arrives.
        val repaint = "\u001B[r\u001B[0m\u001B[2J\u001B[H" +
            paint.trimEnd('\n').replace("\n", "\r\n") +
            "\u001B[${cy + 1};${cx + 1}H\u001B[0m"
        emulator.feed(repaint.toByteArray())
        emulator.feed(clientBytes)
        emulator.finishInput()

        val screen = screenText(emulator)
        println("=== RESUME FINAL SCREEN ===")
        println(screen)
        println("=== END SCREEN (alt=${emulator.isAlternateScreenActive()}) ===")
        assertTrue("prompt after exit missing", screen.contains("AFTER_EXIT_MARKER"))
        assertTrue(
            "stale inner-app text remains on screen",
            !Regex("CLAUDE_STALE_LINE_\\d").containsMatchIn(screen),
        )
    }
}
