package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic unit tests for the pure-Kotlin ANSI emulator. No Android/network deps. */
class TerminalEmulatorTest {

    private val esc = "\u001B"

    private fun TerminalEmulator.feedStr(s: String) = feed(s.toByteArray(Charsets.UTF_8))

    private fun rowText(e: TerminalEmulator, row: Int): String =
        e.snapshot().rows[row].spans.joinToString("") { it.text }

    @Test
    fun plainTextAndCursorAdvance() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("hello")
        assertEquals("hello", rowText(e, 0))
        assertEquals(5, e.snapshot().cursorCol)
        assertEquals(0, e.snapshot().cursorRow)
    }

    @Test
    fun carriageReturnOverwrites() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("abc\rX")
        assertEquals("Xbc", rowText(e, 0))
    }

    @Test
    fun lineFeedMovesDown() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("one\r\ntwo")
        assertEquals("one", rowText(e, 0))
        assertEquals("two", rowText(e, 1))
        assertEquals(1, e.snapshot().cursorRow)
    }

    @Test
    fun cursorPositionCsi() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("$esc[2;3HX") // row 2, col 3 (1-based) → screen[1][2]
        assertEquals("  X", rowText(e, 1))
        assertEquals(1, e.snapshot().cursorRow)
        assertEquals(3, e.snapshot().cursorCol)
    }

    @Test
    fun eraseLine() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("abcdef")
        e.feedStr("\r$esc[2K") // CR then erase whole line
        assertEquals("", rowText(e, 0))
    }

    @Test
    fun sgrColorProducesDistinctSpan() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("$esc[31mRED$esc[0mX")
        val spans = e.snapshot().rows[0].spans
        val red = spans.first { it.text.startsWith("RED") }
        assertEquals(TerminalEmulator.PALETTE_256[1], red.fg) // ANSI red
        assertTrue(spans.any { it.text.contains("X") && it.fg == TerminalEmulator.DEFAULT_FG })
    }

    @Test
    fun backspaceMovesCursorLeft() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("ab\bX") // a,b then BS over b, write X
        assertEquals("aX", rowText(e, 0))
    }

    @Test
    fun lineWrapAtRightEdge() {
        val e = TerminalEmulator(3, 4)
        e.feedStr("abcd") // 3 cols → "abc" then wrap "d"
        assertEquals("abc", rowText(e, 0))
        assertEquals("d", rowText(e, 1))
    }

    @Test
    fun scrollbackGrowsOnOverflow() {
        val e = TerminalEmulator(10, 2)
        e.feedStr("L0\r\nL1\r\nL2") // third line forces scroll; "L0" goes to scrollback
        val rows = e.snapshot().rows
        assertEquals(3, rows.size) // 1 scrollback + 2 screen
        assertEquals("L0", rows[0].spans.joinToString("") { it.text })
        assertEquals("L2", rows[2].spans.joinToString("") { it.text })
    }

    @Test
    fun snapshotRangeReturnsAbsoluteViewportRows() {
        val e = TerminalEmulator(10, 2)
        e.feedStr("L0\r\nL1\r\nL2\r\nL3")
        val snap = e.snapshotRange(firstRow = 1, count = 2)
        assertEquals(1, snap.firstRow)
        assertEquals(4, snap.totalRows)
        assertEquals(2, snap.rows.size)
        assertEquals("L1", snap.rows[0].spans.joinToString("") { it.text })
        assertEquals("L2", snap.rows[1].spans.joinToString("") { it.text })
    }

    @Test
    fun scrollbackLimitTrimsOldRows() {
        val e = TerminalEmulator(10, 2, scrollbackLimit = 2)
        e.feedStr("L0\r\nL1\r\nL2\r\nL3\r\nL4")
        val rows = e.snapshot().rows
        assertEquals(4, rows.size) // 2 scrollback + 2 visible rows
        assertEquals("L1", rows[0].spans.joinToString("") { it.text })
        assertEquals("L4", rows[3].spans.joinToString("") { it.text })
    }

    @Test
    fun clearScrollbackKeepsVisibleScreen() {
        val e = TerminalEmulator(10, 2)
        e.feedStr("L0\r\nL1\r\nL2")
        assertEquals(3, e.snapshot().rows.size)
        e.clearScrollback()
        val rows = e.snapshot().rows
        assertEquals(2, rows.size)
        assertEquals("L1", rows[0].spans.joinToString("") { it.text })
        assertEquals("L2", rows[1].spans.joinToString("") { it.text })
    }

    @Test
    fun resizeNarrowerReflowsLongLineByWrapping() {
        // A 12-char line on a 12-wide terminal: shrinking to 6 cols must wrap, not truncate.
        val e = TerminalEmulator(12, 4)
        e.feedStr("ABCDEFGHIJKL")
        e.resize(6, 4)
        val rows = e.snapshot().rows
        assertEquals("ABCDEF", rows[0].spans.joinToString("") { it.text })
        assertEquals("GHIJKL", rows[1].spans.joinToString("") { it.text })
    }

    @Test
    fun resizeWiderRejoinsSoftWrappedLine() {
        // Wrap a long line at 6 cols, then widen to 12: it should rejoin into one logical line.
        val e = TerminalEmulator(6, 4)
        e.feedStr("ABCDEFGHIJKL") // wraps to ABCDEF / GHIJKL
        e.resize(12, 4)
        assertEquals("ABCDEFGHIJKL", rowText(e, 0))
    }

    @Test
    fun resizePreservesHardNewlines() {
        // Two distinct lines (explicit CRLF) must remain two lines after a width change, never merged.
        val e = TerminalEmulator(12, 4)
        e.feedStr("ABC\r\nDEF")
        e.resize(6, 4)
        val rows = e.snapshot().rows
        assertEquals("ABC", rows[0].spans.joinToString("") { it.text })
        assertEquals("DEF", rows[1].spans.joinToString("") { it.text })
    }

    @Test
    fun resizeRoundTripRestoresContent() {
        val e = TerminalEmulator(20, 5)
        e.feedStr("the quick brown fox jumps over") // one logical line, wraps at 20
        e.resize(8, 5)
        // Widen past the line length so the whole logical line fits on one row again.
        e.resize(40, 5)
        assertEquals("the quick brown fox jumps over", rowText(e, 0))
    }

    @Test
    fun utf8SplitAcrossChunks() {
        val e = TerminalEmulator(80, 24)
        val euro = "€".toByteArray(Charsets.UTF_8) // 3 bytes: E2 82 AC
        e.feed(euro.copyOfRange(0, 2)) // partial
        e.feed(euro.copyOfRange(2, 3)) // completes it
        assertEquals("€", rowText(e, 0))
    }
}
