package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic unit tests for the pure-Kotlin ANSI emulator. No Android/network deps. */
class TerminalEmulatorTest {
    @Test(timeout = 15_000)
    fun largeMostlyAsciiHistoryReplaysWithinAUsefulBound() {
        val emulator = TerminalEmulator(100, 30, scrollbackLimit = 5_000)
        val payload = buildString(500_000) {
            var line = 0
            while (length < 500_000) {
                append("row=")
                append(line++)
                append(" abcdefghijklmnopqrstuvwxyz 0123456789 café-東京-🙂\r\n")
            }
        }.toByteArray()

        emulator.feed(payload)

        assertTrue(emulator.scrollbackRowCount() > 1_000)
        assertTrue(emulator.rowCount() <= 5_030)
    }


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
    fun changingScrollbackLimitTrimsExistingRows() {
        val e = TerminalEmulator(10, 2, scrollbackLimit = 10)
        e.feedStr("L0\r\nL1\r\nL2\r\nL3\r\nL4")

        e.setScrollbackLimit(1)

        val rows = e.snapshot().rows
        assertEquals(3, rows.size) // 1 scrollback + 2 visible rows
        assertEquals("L2", rows[0].spans.joinToString("") { it.text })
        assertEquals("L4", rows[2].spans.joinToString("") { it.text })
    }

    @Test
    fun alternateScreenDoesNotCaptureScrollbackByDefault() {
        val e = TerminalEmulator(10, 2)
        e.feedStr("${esc}[?1049h")
        e.feedStr("A\r\nB\r\nC")

        assertEquals(2, e.snapshot().rows.size)
    }

    @Test
    fun alternateScreenCanCaptureScrollbackForTmuxSessions() {
        val e = TerminalEmulator(10, 2)
        e.setCaptureAlternateScreenScrollback(true)
        e.feedStr("${esc}[?1049h")
        e.feedStr("A\r\nB\r\nC")

        val rows = e.snapshot().rows
        assertEquals(3, rows.size)
        assertEquals("A", rows[0].spans.joinToString("") { it.text })
        assertEquals("C", rows[2].spans.joinToString("") { it.text })
    }

    @Test
    fun alternateScreenResizePreservesNormalScreenAndCursor() {
        val e = TerminalEmulator(12, 4)
        e.feedStr("shell-line\r\nprompt> ")
        e.feedStr("${esc}[?1049h")
        e.feedStr("TUI${esc}[s${esc}[4;10H")

        e.resize(20, 6)
        e.feedStr("${esc}[?1049l")
        e.feedStr("x")

        val text = e.snapshot().rows.joinToString("\n") { row ->
            row.spans.joinToString("") { it.text }.trimEnd()
        }
        assertTrue(text.contains("shell-line"))
        assertTrue(text.contains("prompt> x"))
        assertFalse(text.contains("TUI"))
    }

    @Test
    fun alternateScreenShrinkReflowsHiddenNormalScreenWithoutTruncation() {
        val e = TerminalEmulator(12, 4)
        e.feedStr("ABCDEFGHIJKL")
        e.feedStr("${esc}[?1049h")
        e.feedStr("TUI")

        e.resize(6, 4)
        e.feedStr("${esc}[?1049l")

        assertEquals("ABCDEF", rowText(e, 0))
        assertEquals("GHIJKL", rowText(e, 1))
        assertFalse(e.snapshot().rows.any { row -> row.spans.any { it.text.contains("TUI") } })
    }

    @Test
    fun heightShrinkKeepsHighCursorLineVisible() {
        val e = TerminalEmulator(10, 4)
        e.feedStr("prompt> ")

        e.resize(10, 2)

        val snapshot = e.snapshot()
        assertEquals("prompt>", snapshot.rows[0].spans.joinToString("") { it.text })
        assertEquals(0, snapshot.cursorRow)
        assertEquals(8, snapshot.cursorCol)
    }

    @Test
    fun alternateScreenHeightShrinkKeepsHiddenNormalCursorLineVisible() {
        val e = TerminalEmulator(10, 4)
        e.feedStr("prompt> ")
        e.feedStr("${esc}[?1049h")
        e.feedStr("TUI")

        e.resize(10, 2)
        e.feedStr("${esc}[?1049l")

        val snapshot = e.snapshot()
        assertEquals("prompt>", snapshot.rows[0].spans.joinToString("") { it.text })
        assertEquals(0, snapshot.cursorRow)
        assertEquals(8, snapshot.cursorCol)
    }

    @Test
    fun tracksBracketedPasteMode() {
        val e = TerminalEmulator(20, 4)
        assertFalse(e.bracketedPasteMode)
        e.feedStr("${esc}[?2004h")
        assertTrue(e.bracketedPasteMode)
        e.feedStr("${esc}[?2004l")
        assertFalse(e.bracketedPasteMode)
    }

    @Test
    fun unsupportedControlStringsAreDiscardedUntilStringTerminator() {
        val e = TerminalEmulator(40, 4)
        e.feedStr("before${esc}PqSIXEL-GARBAGE${esc}\\after")
        assertEquals("beforeafter", rowText(e, 0))
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
    fun adoptScrollbackReplacesHistoryButKeepsScreen() {
        // tmux re-sync: the live emulator's gappy locally-captured scrollback is swapped for the
        // pane's real history (parsed through a scratch emulator); the visible screen is untouched.
        val live = TerminalEmulator(10, 2, scrollbackLimit = 100)
        live.feedStr("junk\r\nS0\r\nS1") // "junk" lands in scrollback; S0/S1 on screen
        val scratch = TerminalEmulator(10, 2, scrollbackLimit = 100)
        scratch.feedStr("H0\r\nH1\r\nH2")
        scratch.feedStr("\r\n\r\n") // screen-height of LFs pushes everything into scrollback
        assertEquals(3, scratch.scrollbackRowCount())

        live.adoptScrollbackFrom(scratch)

        val rows = live.snapshot().rows
        assertEquals(5, rows.size) // 3 adopted history rows + 2 screen rows
        assertEquals("H0", rows[0].spans.joinToString("") { it.text })
        assertEquals("H2", rows[2].spans.joinToString("") { it.text })
        assertEquals("S0", rows[3].spans.joinToString("") { it.text })
        assertEquals("S1", rows[4].spans.joinToString("") { it.text })
    }

    @Test
    fun adoptScrollbackCarriesSoftWrapFlagsForCopyJoining() {
        // A 12-char logical line wrapped at 6 cols in the scratch emulator must still copy as one
        // logical line after adoption (the soft-wrap flag travels with the row).
        val scratch = TerminalEmulator(6, 2, scrollbackLimit = 100)
        scratch.feedStr("ABCDEFGHIJKL")
        scratch.feedStr("\r\n\r\n")
        val live = TerminalEmulator(6, 2, scrollbackLimit = 100)
        live.adoptScrollbackFrom(scratch)
        val rows = live.snapshot().rows
        assertTrue("adopted wrapped row must keep its softWrap flag", rows[0].softWrap)
    }

    @Test
    fun historyResyncPathKeepsLongSequencesContinuous() {
        // Replicates resyncTmuxScrollbackFor's scratch+adopt steps with a seq-1-5000-style
        // capture (the field-reported failure): every number must survive, in order, with no
        // gaps and no interleaved blank rows. The capture side was verified separately against
        // real tmux 3.3a; this pins the client half of the pipeline.
        val capture = (1..5000).joinToString("\n")
        val live = TerminalEmulator(80, 24, scrollbackLimit = 10_000)
        live.feedStr("gappy live-captured junk\r\nmore junk\r\n")
        val scratch = TerminalEmulator(80, 24, scrollbackLimit = 10_000)
        scratch.feed(capture.replace("\n", "\r\n").toByteArray(Charsets.UTF_8))
        scratch.feed("\r\n".repeat(24).toByteArray(Charsets.UTF_8))

        live.adoptScrollbackFrom(scratch)

        val texts = live.snapshot().rows.map { r -> r.spans.joinToString("") { it.text }.trimEnd() }
        val nums = texts.mapNotNull { it.toIntOrNull() }
        assertEquals(5000, nums.size)
        assertEquals((1..5000).toList(), nums)
        // No junk row survives in SCROLLBACK (the last 24 rows are the live screen, which adopt
        // deliberately leaves untouched — in the real flow it mirrors the current pane).
        assertTrue(texts.dropLast(24).none { it.contains("junk") })
    }

    @Test
    fun adoptScrollbackIsNoOpOnWidthMismatch() {
        val live = TerminalEmulator(10, 2)
        live.feedStr("keep\r\nS0\r\nS1")
        val scratch = TerminalEmulator(8, 2)
        scratch.feedStr("H0\r\n\r\n\r\n")
        live.adoptScrollbackFrom(scratch)
        val rows = live.snapshot().rows
        assertEquals("keep", rows[0].spans.joinToString("") { it.text })
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
    fun heightChurnPreservesScrollback() {
        // Backgrounding the app bounces the IME, so a pane's row count grows and shrinks without a
        // width change. Rows must shuttle between screen and scrollback losslessly through the churn.
        val e = TerminalEmulator(20, 10, scrollbackLimit = 1000)
        for (i in 1..200) e.feedStr("line-$i\r\n")
        e.resize(20, 40)
        e.resize(20, 10)
        e.resize(20, 1)
        e.resize(20, 10)
        val text = (0 until e.rowCount()).joinToString("\n") { r ->
            e.snapshot().rows[r].spans.joinToString("") { it.text }.trimEnd()
        }
        for (i in 1..200) assertTrue("line-$i missing after height churn", text.contains("line-$i"))
    }

    @Test
    fun utf8SplitAcrossChunks() {
        val e = TerminalEmulator(80, 24)
        val euro = "€".toByteArray(Charsets.UTF_8) // 3 bytes: E2 82 AC
        e.feed(euro.copyOfRange(0, 2)) // partial
        e.feed(euro.copyOfRange(2, 3)) // completes it
        assertEquals("€", rowText(e, 0))
    }

    @Test
    fun combiningMarkOccupiesNoExtraCell() {
        val e = TerminalEmulator(8, 2)
        e.feedStr("e\u0301x")
        assertEquals("e\u0301x", rowText(e, 0))
        assertEquals(2, e.snapshot().cursorCol)
    }

    @Test
    fun cjkAndEmojiUseTwoTerminalColumns() {
        val e = TerminalEmulator(10, 2)
        e.feedStr("界👩‍💻X")
        assertEquals("界👩‍💻X", rowText(e, 0))
        assertEquals(5, e.snapshot().cursorCol)
    }

    @Test
    fun wideGlyphWrapsAtomicallyAtRightEdge() {
        val e = TerminalEmulator(4, 3)
        e.feedStr("ab界X")
        assertEquals("ab界", rowText(e, 0))
        assertEquals("X", rowText(e, 1))
        assertEquals(1, e.snapshot().cursorCol)
    }

    @Test
    fun erasingHalfOfWideGlyphClearsWholeGlyph() {
        val e = TerminalEmulator(6, 2)
        e.feedStr("界")
        e.feedStr("\r$esc[X")
        assertEquals("", rowText(e, 0))
    }

    @Test
    fun erasingContinuationHalfClearsWholeWideGlyph() {
        val e = TerminalEmulator(6, 2)
        e.feedStr("界")
        e.feedStr("$esc[2G$esc[X")
        assertEquals("", rowText(e, 0))
    }

    @Test
    fun prewrappedWideGlyphDoesNotCreateARealSpaceOnResize() {
        val e = TerminalEmulator(4, 3)
        e.feedStr("abc界")
        e.resize(8, 3)
        assertEquals("abc界", rowText(e, 0))
    }

    @Test
    fun oneColumnResizeDoesNotPermanentlyNarrowWideGlyphs() {
        val e = TerminalEmulator(6, 4)
        e.feedStr("界X")
        e.resize(1, 4)
        e.resize(6, 4)
        assertEquals("界X", rowText(e, 0))
        assertEquals(3, e.snapshot().cursorCol)
    }

    @Test
    fun finalWideGlyphKeepsCursorAfterOneColumnRoundTrip() {
        val e = TerminalEmulator(6, 4)
        e.feedStr("界")

        e.resize(1, 4)
        e.resize(6, 4)

        assertEquals("界", rowText(e, 0))
        assertEquals(2, e.snapshot().cursorCol)
    }

    @Test
    fun flagsKeycapsAndEmojiPresentationUseTwoColumns() {
        val e = TerminalEmulator(20, 2)
        e.feedStr("🇮🇳1️⃣❤️X")
        assertEquals("🇮🇳1️⃣❤️X", rowText(e, 0))
        assertEquals(7, e.snapshot().cursorCol)
    }

    @Test
    fun leadingCombiningMarkIsNotSilentlyLost() {
        val e = TerminalEmulator(6, 2)
        e.feedStr("\u0301X")
        assertEquals("◌\u0301X", rowText(e, 0))
        assertEquals(2, e.snapshot().cursorCol)
    }

    @Test
    fun deterministicArbitraryByteAndResizeCorpusStaysBounded() {
        val random = java.util.Random(0x4f4d4e49L)
        val scrollbackLimit = 64
        var columns = 80
        var rows = 24
        val e = TerminalEmulator(columns, rows, scrollbackLimit)

        repeat(2_000) { iteration ->
            val chunk = ByteArray(1 + random.nextInt(32))
            random.nextBytes(chunk)
            e.feed(chunk)
            if (iteration % 25 == 0) {
                columns = 1 + random.nextInt(100)
                rows = 1 + random.nextInt(40)
                e.resize(columns, rows)
            }

            if (iteration % 20 == 0) {
                val snapshot = e.snapshot()
                assertTrue(snapshot.cursorRow in 0 until snapshot.totalRows)
                assertTrue(snapshot.cursorCol in 0 until columns)
                assertTrue(snapshot.totalRows <= scrollbackLimit + rows)
                assertEquals(columns, snapshot.cols)
            }
        }
    }
}
