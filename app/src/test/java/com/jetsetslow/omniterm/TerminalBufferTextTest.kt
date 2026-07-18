package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.dropBoundaryDuplication
import com.jetsetslow.omniterm.ui.insertedCodePointDelta
import com.jetsetslow.omniterm.ui.isSingleTerminalEnter
import com.jetsetslow.omniterm.ui.joinRowsRespectingWraps
import com.jetsetslow.omniterm.ui.logicalLineAt
import com.jetsetslow.omniterm.ui.terminalLinkAt
import com.jetsetslow.omniterm.ui.terminalColumnToTextIndex
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Test

/** Tests for the scrollback↔screen boundary de-duplication used by "Full buffer" copy. */
class TerminalBufferTextTest {

    @Test
    fun singleImeNewlineIsTerminalEnterButPasteBlockIsNot() {
        assertEquals(true, isSingleTerminalEnter("\n"))
        assertEquals(true, isSingleTerminalEnter("\r"))
        assertEquals(true, isSingleTerminalEnter("\r\n"))
        assertEquals(false, isSingleTerminalEnter("command\n"))
        assertEquals(false, isSingleTerminalEnter("one\ntwo\n"))
    }

    @Test
    fun pasteDeltaCountsSupplementaryCharactersAsSingleCodePoints() {
        val old = "😀".repeat(101)
        assertEquals(1, insertedCodePointDelta(old, old + "😁"))
        assertEquals(1, insertedCodePointDelta("a😀z", "a😁z"))
    }

    @Test
    fun collapsesScrollbackTailThatRepeatsScreenHead() {
        // scrollback = [A, B, C], screen = [B, C, D]; tmux replayed B,C into the live screen.
        val lines = listOf("A", "B", "C", "B", "C", "D")
        val result = dropBoundaryDuplication(lines, boundary = 3)
        assertEquals(listOf("A", "B", "C", "D"), result)
    }

    @Test
    fun keepsBufferWhenNoBoundaryOverlap() {
        val lines = listOf("A", "B", "C", "D", "E", "F")
        assertEquals(lines, dropBoundaryDuplication(lines, boundary = 3))
    }

    @Test
    fun doesNotCollapseGenuineRepeatsAwayFromBoundary() {
        // "echo hi" appears twice but not at the boundary — must be preserved.
        val lines = listOf("echo hi", "hi", "prompt$", "echo hi", "hi")
        assertEquals(lines, dropBoundaryDuplication(lines, boundary = 3))
    }

    @Test
    fun blankOnlyOverlapIsNotCollapsed() {
        // Trailing blank scrollback matching leading blank screen rows must stay (real newlines).
        val lines = listOf("A", "", "", "", "", "B")
        assertEquals(lines, dropBoundaryDuplication(lines, boundary = 3))
    }

    @Test
    fun collapsesAcrossBlankPaddingGap() {
        // tmux replays the pane (B,C) but leaves blank pane-padding before the live screen:
        // scrollback = [A, B, C, "", ""], screen = [B, C, D]. The B,C duplicate must collapse and
        // the blank gap must be preserved.
        val lines = listOf("A", "B", "C", "", "", "B", "C", "D")
        val result = dropBoundaryDuplication(lines, boundary = 5)
        assertEquals(listOf("A", "", "", "B", "C", "D"), result)
    }

    @Test
    fun prefersLongestOverlap() {
        val lines = listOf("X", "B", "C", "B", "C")
        assertEquals(listOf("X", "B", "C"), dropBoundaryDuplication(lines, boundary = 3))
    }

    @Test
    fun handlesDegenerateBoundaries() {
        val lines = listOf("A", "B")
        assertEquals(lines, dropBoundaryDuplication(lines, boundary = 0))
        assertEquals(lines, dropBoundaryDuplication(lines, boundary = 2))
        assertEquals(emptyList<String>(), dropBoundaryDuplication(emptyList(), boundary = 0))
    }

    // ── Soft-wrap re-joining: copied text must not gain newlines from visual wrapping ──

    @Test
    fun softWrappedLongLineCopiesAsOneLogicalLine() {
        // 10-column terminal; a 25-char line wraps across three visual rows.
        val e = TerminalEmulator(10, 4)
        e.feed("abcdefghijklmnopqrstuvwxy".toByteArray())
        val text = joinRowsRespectingWraps(e.snapshot().rows)
        assertEquals("abcdefghijklmnopqrstuvwxy", text)
    }

    @Test
    fun hardNewlinesArePreserved() {
        val e = TerminalEmulator(10, 4)
        e.feed("one\r\ntwo\r\nthree".toByteArray())
        assertEquals("one\ntwo\nthree", joinRowsRespectingWraps(e.snapshot().rows))
    }

    @Test
    fun copyPreservesRealTrailingUnicodeWhitespace() {
        val e = TerminalEmulator(10, 1)
        e.feed("value\u3000".toByteArray())
        assertEquals("value\u3000", joinRowsRespectingWraps(e.snapshot().rows))
    }

    @Test
    fun mixedWrapAndNewline() {
        // First line wraps once (12 chars on 10 cols), then a hard newline, then a short line.
        val e = TerminalEmulator(10, 5)
        e.feed("abcdefghijkl\r\nshort".toByteArray())
        assertEquals("abcdefghijkl\nshort", joinRowsRespectingWraps(e.snapshot().rows))
    }

    @Test
    fun wrappedLineSurvivesScrollIntoScrollback() {
        // 3 rows tall: the wrapped line's first row scrolls into scrollback; the wrap join must
        // still work across the scrollback↔screen boundary.
        val e = TerminalEmulator(10, 3)
        e.feed("abcdefghijklmnopqrst\r\nnext\r\nmore\r\nlast".toByteArray())
        val text = joinRowsRespectingWraps(e.snapshot().rows)
        assertEquals("abcdefghijklmnopqrst\nnext\nmore\nlast", text)
    }

    @Test
    fun erasedRowDropsStaleWrapFlag() {
        val e = TerminalEmulator(10, 4)
        // Wrap a long line, then clear the screen (ED 2) and write two separate short lines —
        // they must NOT be joined by the stale wrap flag.
        e.feed("abcdefghijklmnop".toByteArray())
        e.feed("\u001B[2J\u001B[H".toByteArray())
        e.feed("aa\r\nbb".toByteArray())
        val screenText = joinRowsRespectingWraps(e.snapshotRange(e.scrollbackRowCount(), 4).rows)
        assertEquals("aa\nbb", screenText)
    }

    // ── Logical-line reconstruction for tap targets on wrapped rows ──

    @Test
    fun logicalLineJoinsWrappedRunAndReportsRowOffset() {
        val e = TerminalEmulator(10, 4)
        e.feed("abcdefghijklmnopqrstuvwxy".toByteArray())
        val rows = e.snapshot().rows
        // Tap on the middle visual row (index 1): logical line is the full 25 chars, and row 1's
        // column 0 sits at offset 10 (one full-width row before it).
        val (line, offset) = logicalLineAt(rows, 1)!!
        assertEquals("abcdefghijklmnopqrstuvwxy", line.trimEnd())
        assertEquals(10, offset)
    }

    @Test
    fun urlWrappedAcrossRowsIsDetectedFromAnyRow() {
        // 20-col terminal: the URL spans two visual rows.
        val e = TerminalEmulator(20, 4)
        e.feed("see https://example.com/a/very/long/path".toByteArray())
        val rows = e.snapshot().rows
        val expected = "https://example.com/a/very/long/path"
        // Tap inside the first row's URL portion (col 6 of row 0).
        val first = logicalLineAt(rows, 0)!!.let { (line, off) -> terminalLinkAt(line, off + 6) }
        assertEquals(expected, first)
        // Tap on the wrapped continuation (col 3 of row 1).
        val second = logicalLineAt(rows, 1)!!.let { (line, off) -> terminalLinkAt(line, off + 3) }
        assertEquals(expected, second)
    }

    @Test
    fun unwrappedRowsAreNotJoined() {
        val e = TerminalEmulator(20, 4)
        e.feed("https://a.test\r\nplain text".toByteArray())
        val rows = e.snapshot().rows
        val (line, offset) = logicalLineAt(rows, 1)!!
        assertEquals("plain text", line.trimEnd())
        assertEquals(0, offset)
        assertNull(logicalLineAt(rows, 99))
    }

    @Test
    fun terminalColumnsMapAcrossWideAndCombinedGlyphs() {
        val e = TerminalEmulator(20, 2)
        e.feed("A界e\u0301Z".toByteArray())
        val row = e.snapshot().rows[0]
        assertEquals(0, terminalColumnToTextIndex(row, 0))
        assertEquals(1, terminalColumnToTextIndex(row, 1))
        assertEquals(1, terminalColumnToTextIndex(row, 2)) // second half of 界
        assertEquals(2, terminalColumnToTextIndex(row, 3)) // e + combining mark starts here
        assertEquals(4, terminalColumnToTextIndex(row, 4)) // Z starts after two UTF-16 chars
    }

    // ── Terminal tap-to-open hyperlink detection ──

    @Test
    fun findsUrlUnderTappedColumn() {
        val line = "Docs at https://example.com/guide and more"
        // Column inside the URL.
        assertEquals("https://example.com/guide", terminalLinkAt(line, 15))
        // First and last characters of the URL.
        assertEquals("https://example.com/guide", terminalLinkAt(line, 8))
        assertEquals("https://example.com/guide", terminalLinkAt(line, 32))
    }

    @Test
    fun ignoresTapsOutsideTheUrl() {
        val line = "Docs at https://example.com/guide and more"
        assertNull(terminalLinkAt(line, 3))
        assertNull(terminalLinkAt(line, 35))
        assertNull(terminalLinkAt(line, 500))
    }

    @Test
    fun trimsTrailingPunctuationAndRejectsTapsOnIt() {
        val line = "See https://example.com/a."
        assertEquals("https://example.com/a", terminalLinkAt(line, 10))
        // The trailing period is not part of the link.
        assertNull(terminalLinkAt(line, 25))
    }

    @Test
    fun addsSchemeToBareWwwHosts() {
        assertEquals("https://www.example.com", terminalLinkAt("go to www.example.com now", 8))
    }

    @Test
    fun handlesMultipleUrlsOnOneLine() {
        val line = "a http://one.test b https://two.test c"
        assertEquals("http://one.test", terminalLinkAt(line, 5))
        assertEquals("https://two.test", terminalLinkAt(line, 22))
        assertNull(terminalLinkAt(line, 18))
    }

    @Test
    fun plainTextHasNoLinks() {
        assertNull(terminalLinkAt("total 12K drwxr-xr-x 2 pi pi 4.0K", 10))
    }
}
