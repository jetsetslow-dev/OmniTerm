package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Leaving the alternate screen must restore what the shell had before the TUI started.
 *
 * Reported symptom: exiting Claude/Codex left the TUI's text on screen with the cursor at the top,
 * so the next shell prompt painted over stale content. That happens when the primary buffer isn't
 * restored, or when the cursor saved on entry isn't put back.
 */
class TerminalAltScreenExitTest {

    /** CSI introducer, spelled out so the escape byte is never a literal control char in source. */
    private val csi = "\u001B["

    private fun TerminalSnapshot.text(): List<String> =
        rows.map { row -> row.spans.joinToString("") { it.text }.trimEnd() }

    private fun lines(e: TerminalEmulator) = e.snapshot().text().filter { it.isNotBlank() }

    /** 1049 is what Claude/Codex use: save cursor + switch + clear, all undone on exit. */
    @Test
    fun mode1049RestoresShellOutputAndCursorAfterTuiExits() {
        val e = TerminalEmulator(40, 10, scrollbackLimit = 100)
        e.feed("$ echo hello\r\nhello\r\n$ ".toByteArray())
        val cursorBefore = e.snapshot().let { it.cursorRow to it.cursorCol }

        // TUI takes the alt screen, paints, then leaves.
        e.feed("$csi?1049h".toByteArray())
        e.feed("CLAUDE FULLSCREEN UI".toByteArray())
        assertTrue("TUI text should be visible while on the alt screen",
            lines(e).any { it.contains("CLAUDE FULLSCREEN UI") })
        e.feed("$csi?1049l".toByteArray())

        val after = lines(e)
        assertFalse("Alt-screen text leaked into the restored primary screen: $after",
            after.any { it.contains("CLAUDE FULLSCREEN UI") })
        assertTrue("Shell output was not restored: $after", after.any { it.contains("hello") })

        val cursorAfter = e.snapshot().let { it.cursorRow to it.cursorCol }
        assertEquals("1049 must restore the cursor saved on entry", cursorBefore, cursorAfter)
    }

    /** New output after the TUI exits must continue from the prompt, not overwrite from row 0. */
    @Test
    fun outputAfterTuiExitDoesNotOverwriteRestoredScreen() {
        val e = TerminalEmulator(40, 10, scrollbackLimit = 100)
        e.feed("line one\r\nline two\r\n$ ".toByteArray())

        e.feed("$csi?1049h".toByteArray())
        e.feed("${csi}5;1Hsome tui chrome".toByteArray())
        e.feed("$csi?1049l".toByteArray())
        e.feed("next-command\r\n".toByteArray())

        val after = lines(e)
        assertTrue("Earlier scrollback was clobbered: $after", after.any { it.contains("line one") })
        assertTrue("Earlier scrollback was clobbered: $after", after.any { it.contains("line two") })
        assertTrue("New output missing: $after", after.any { it.contains("next-command") })
        assertFalse("TUI chrome survived the exit: $after", after.any { it.contains("some tui chrome") })
    }

    /**
     * 47/1047 switch buffers only. xterm clears the alternate buffer before switching back, so its
     * content must not reappear on a later entry, and the cursor must be left where it is — cursor
     * restore belongs to 1048/1049.
     */
    @Test
    fun mode1047ClearsAltBufferAndLeavesCursorAlone() {
        val e = TerminalEmulator(40, 10, scrollbackLimit = 100)
        e.feed("primary content\r\n".toByteArray())

        e.feed("$csi?1047h".toByteArray())
        e.feed("alt buffer text".toByteArray())
        e.feed("$csi?1047l".toByteArray())
        assertTrue("Primary screen was not restored", lines(e).any { it.contains("primary content") })

        // Re-entering must show a clean buffer, not the previous alt contents.
        e.feed("$csi?1047h".toByteArray())
        assertFalse("Stale alt-buffer text reappeared on re-entry: ${lines(e)}",
            lines(e).any { it.contains("alt buffer text") })
    }

    /** 1048 saves/restores the cursor with no buffer switch; used with 47 by some TUIs. */
    @Test
    fun mode1048RestoresCursorWithoutSwitchingBuffers() {
        val e = TerminalEmulator(40, 10, scrollbackLimit = 100)
        e.feed("${csi}3;7H".toByteArray())
        val saved = e.snapshot().let { it.cursorRow to it.cursorCol }

        e.feed("$csi?1048h".toByteArray())   // save
        e.feed("${csi}9;1H".toByteArray())     // move away
        e.feed("$csi?1048l".toByteArray())   // restore

        assertEquals("1048 must restore the saved cursor", saved,
            e.snapshot().let { it.cursorRow to it.cursorCol })
    }

    /** Leaving the alt screen without ever entering it must not blank the shell's screen. */
    @Test
    fun spuriousAltScreenExitDoesNotWipeTheScreen() {
        val e = TerminalEmulator(40, 10, scrollbackLimit = 100)
        e.feed("important output\r\n".toByteArray())
        e.feed("$csi?1049l".toByteArray())
        assertTrue("A stray exit wiped the screen", lines(e).any { it.contains("important output") })
    }
}
