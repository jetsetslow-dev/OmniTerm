package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TermSpan
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Control sequences the programs drawing on a terminal send, byte for byte, and where each leaves
 * the text and the cursor (xterm's behaviour). A sequence this terminal does not carry out must
 * change nothing and print nothing: a stray letter or a wrong column moves every later redraw of a
 * TUI such as Claude Code, Codex or vim.
 */
class TerminalControlSequenceTest {
    private val esc = "\u001B"

    private fun emulator(cols: Int = 80, rows: Int = 24, input: String = "") =
        TerminalEmulator(cols, rows).also { if (input.isNotEmpty()) it.feedStr(input) }

    private fun TerminalEmulator.feedStr(s: String) = feed(s.toByteArray(Charsets.UTF_8))

    /** Visible row [row] of the screen (not counting scrollback), without trailing blanks. */
    private fun TerminalEmulator.screenRow(row: Int): String {
        val snapshot = snapshot()
        return snapshot.rows[scrollbackRowCount() + row].spans.joinToString("") { it.text }.trimEnd()
    }

    /** The span that holds the cell at [col] of visible row [row]. */
    private fun TerminalEmulator.spanAt(row: Int, col: Int): TermSpan {
        var column = 0
        for (span in snapshot().rows[scrollbackRowCount() + row].spans) {
            val (_, widths) = span.cellLayout()
            if (col < column + widths.sum()) return span
            column += widths.sum()
        }
        throw AssertionError("no cell at $row,$col")
    }

    /** Cursor as (screen row, column). */
    private fun TerminalEmulator.cursor(): Pair<Int, Int> =
        snapshot().let { (it.cursorRow - scrollbackRowCount()) to it.cursorCol }

    @Test
    fun aModeQueryPrintsNothing() {
        // DECRQM for synchronized output, as TUIs probe it.
        assertEquals("X", emulator(input = "$esc[?2026\$pX").screenRow(0))
        // DECSCA, DECSCUSR and DECSTR's cousins with other intermediates.
        assertEquals("X", emulator(input = "$esc[0\"qX").screenRow(0))
        assertEquals("X", emulator(input = "$esc[2 qX").screenRow(0))
    }

    @Test
    fun keyboardProtocolRequestsLeaveThePenAlone() {
        // xterm modifyOtherKeys, sent by vim and by tmux with extended-keys.
        val e = emulator(input = "$esc[>4;2ma$esc[>4;1mb$esc[>4mc")
        for (col in 0..2) {
            val span = e.spanAt(0, col)
            assertFalse("dim at $col", span.dim)
            assertFalse("bold at $col", span.bold)
        }
        // A kitty keyboard query and push neither move the cursor nor print.
        val k = emulator(input = "ab$esc[?u$esc[>1u$esc[<u$esc[=1;1uc")
        assertEquals("abc", k.screenRow(0))
    }

    @Test
    fun decLineDrawingDrawsBoxes() {
        val e = emulator(input = "$esc(0lqk\r\nx x\r\nmqj$esc(Bq")
        assertEquals("┌─┐", e.screenRow(0))
        assertEquals("│ │", e.screenRow(1))
        assertEquals("└─┘q", e.screenRow(2))
        // G1 shifted in with SO, back to G0 with SI.
        assertEquals("q─q", emulator(input = "$esc)0q\u000Eq\u000Fq").screenRow(0))
    }

    @Test
    fun repRepeatsTheLastCharacter() {
        assertEquals("aaaa", emulator(input = "a$esc[3b").screenRow(0))
        assertEquals("=====", emulator(input = "=$esc[b$esc[3b").screenRow(0))
        // Nothing printed yet: nothing to repeat.
        assertEquals("", emulator(input = "$esc[5b").screenRow(0))
    }

    @Test
    fun withAutowrapOffTheLastColumnIsOverwritten() {
        val e = emulator(cols = 80, input = "$esc[?7l" + "a".repeat(99) + "Z")
        assertEquals("a".repeat(79) + "Z", e.screenRow(0))
        assertEquals("", e.screenRow(1))
        assertEquals(0 to 79, e.cursor())
        // Turned back on, text wraps again.
        e.feedStr("$esc[?7h\r" + "b".repeat(81))
        assertEquals("b", e.screenRow(1))
    }

    @Test
    fun insertModeMovesTheRestOfTheRowRight() {
        assertEquals("Xabc", emulator(input = "abc\r$esc[4hX").screenRow(0))
        assertEquals("Xbc", emulator(input = "abc\r$esc[4h$esc[4lX").screenRow(0))
    }

    @Test
    fun aScrollRegionWithZeroMeansTheWholeScreen() {
        val e = emulator(rows = 24, input = "top$esc[1;0r" + "\n".repeat(30))
        assertEquals(23, e.cursor().first)
        assertTrue("the first row scrolled off the top", e.scrollbackRowCount() > 0)
        assertEquals("top", e.snapshot().rows[0].spans.joinToString("") { it.text }.trimEnd())
    }

    @Test
    fun aScrollRegionOfOneRowIsIgnored() {
        val e = emulator(input = "$esc[3;7H$esc[5;5rX")
        // Not applied, and the cursor was not sent home.
        assertEquals("      X", e.screenRow(2))
        e.feedStr("\r\n".repeat(30))
        assertTrue("the whole screen still scrolls", e.scrollbackRowCount() > 0)
    }

    @Test
    fun saveCursorKeepsThePenAndRestoreBringsItBack() {
        val e = emulator(input = "$esc[1m${esc}7$esc[0m${esc}8a")
        assertTrue(e.spanAt(0, 0).bold)
        // The CSI s / u forms too.
        val f = emulator(input = "$esc[4m$esc[s$esc[0m$esc[5;5H$esc[ua")
        assertTrue(f.spanAt(0, 0).underline)
        // With nothing saved, restore goes home with a plain pen.
        val g = emulator(input = "$esc[1m$esc[5;5H${esc}8a")
        assertEquals("a", g.screenRow(0))
        assertFalse(g.spanAt(0, 0).bold)
    }

    @Test
    fun saveCursorKeepsTheCharsetAndAPendingWrap() {
        val e = emulator(cols = 10, input = "$esc(0${esc}7$esc(B${esc}8q")
        assertEquals("─", e.screenRow(0))
        val w = emulator(cols = 10, input = "0123456789${esc}7$esc[5;1H${esc}8X")
        assertEquals("0123456789", w.screenRow(0))
        assertEquals("X", w.screenRow(1))
    }

    @Test
    fun insertAndDeleteLineGoToTheFirstColumn() {
        assertEquals(0, emulator(input = "abc\r\n$esc[5G$esc[L").cursor().second)
        assertEquals(0, emulator(input = "abc\r\n$esc[5G$esc[M").cursor().second)
    }

    @Test
    fun backspaceWithAWrapPendingMovesLeftOfTheLastColumn() {
        val e = emulator(cols = 10, input = "0123456789\bX")
        assertEquals("01234567X9", e.screenRow(0))
        assertEquals("", e.screenRow(1))
    }

    @Test
    fun tabStopsCanBeSetClearedAndWalkedBack() {
        assertEquals("  X", emulator(input = "$esc[3G${esc}H\r\tX").screenRow(0))
        assertEquals(79, emulator(input = "$esc[3g\t").cursor().second)
        assertEquals(8, emulator(input = "$esc[3g$esc[9G${esc}H\r\t").cursor().second)
        assertEquals(16, emulator(input = "$esc[20G$esc[Z").cursor().second)
        assertEquals(0, emulator(input = "$esc[5G$esc[3Z").cursor().second)
        assertEquals(16, emulator(input = "$esc[2I").cursor().second)
        // Clearing one stop leaves the others.
        assertEquals(16, emulator(input = "$esc[9G$esc[0g\r\t").cursor().second)
        // A wider grid keeps the default stops in its new columns.
        val wide = emulator(cols = 20)
        wide.resize(40, 24)
        wide.feedStr("$esc[30G\t")
        assertEquals(32, wide.cursor().second)
    }

    @Test
    fun eraseSavedLinesKeepsTheScreen() {
        val e = emulator(rows = 3, input = "1\r\n2\r\n3\r\n4\r\nkeep")
        assertTrue(e.scrollbackRowCount() > 0)
        e.feedStr("$esc[3J")
        assertEquals(0, e.scrollbackRowCount())
        assertEquals("keep", e.screenRow(2))
    }

    @Test
    fun aControlInsideASequenceActsAndTheSequenceGoesOn() {
        // CR in the middle of CUF: the carriage return happens, then the cursor moves 2 right.
        assertEquals("abXdef", emulator(input = "abcdef$esc[\r2CX").screenRow(0))
        // A newline inside SGR: the next row, then bold.
        val e = emulator(input = "a$esc[\n1mb")
        assertEquals(" b", e.screenRow(1))
        assertTrue(e.spanAt(1, 1).bold)
    }

    @Test
    fun anEscapeInsideASequenceStartsANewOne() {
        val e = emulator(input = "$esc[3$esc[1mX")
        assertEquals("X", e.screenRow(0))
        assertTrue(e.spanAt(0, 0).bold)
    }

    @Test
    fun cancelEndsASequenceWithoutCarryingItOut() {
        val e = emulator(input = "$esc[1\u0018X$esc[4\u001AY")
        assertEquals("XY", e.screenRow(0))
        assertFalse(e.spanAt(0, 0).bold)
        assertFalse(e.spanAt(0, 1).underline)
    }

    @Test
    fun escapesWithIntermediatesTakeTheirFinalByte() {
        // ESC % G selects UTF-8; ESC SP F asks for 7-bit controls. Neither prints anything.
        assertEquals("ab", emulator(input = "a$esc%Gb$esc F").screenRow(0))
        // DECALN fills the screen with E.
        val e = emulator(cols = 4, rows = 2, input = "ab$esc#8")
        assertEquals("EEEE", e.screenRow(0))
        assertEquals("EEEE", e.screenRow(1))
        assertEquals(0 to 0, e.cursor())
    }

    @Test
    fun anOverlongSequenceIsConsumedNotPrinted() {
        assertEquals("X", emulator(input = "$esc[" + "1".repeat(2_000) + "mX").screenRow(0))
        assertEquals("X", emulator(input = "$esc[1" + "\$".repeat(20) + "pX").screenRow(0))
    }

    @Test
    fun aMisplacedPrivateMarkerIsIgnored() {
        assertEquals("X", emulator(input = "$esc[1?5hX").screenRow(0))
    }

    @Test
    fun originModeAddressesTheScrollRegion() {
        val e = emulator(input = "$esc[5;10r$esc[?6h$esc[HX")
        assertEquals("X", e.screenRow(4))
        e.feedStr("$esc[6n")
        assertEquals("$esc[1;2R", e.takeReplies()?.decodeToString())
        e.feedStr("$esc[20;1HY")
        assertEquals("Y", e.screenRow(9))
        e.feedStr("$esc[?6l")
        assertEquals(0 to 0, e.cursor())
    }

    @Test
    fun cursorUpAndDownStopAtTheScrollRegion() {
        assertEquals(4, emulator(input = "$esc[5;10r$esc[7;1H$esc[10A").cursor().first)
        assertEquals(9, emulator(input = "$esc[5;10r$esc[7;1H$esc[10B").cursor().first)
        // Outside the region they go to the screen's edge.
        assertEquals(0, emulator(input = "$esc[5;10r$esc[3;1H$esc[10A").cursor().first)
        assertEquals(23, emulator(input = "$esc[5;10r$esc[12;1H$esc[30B").cursor().first)
    }

    @Test
    fun colonSubParametersSetColoursAndUnderlines() {
        val e = emulator(
            input = "$esc[4:3mU$esc[0m" +
                "$esc[38:2::255:0:0mR" +
                "$esc[38:2:0:255:0mG" +
                "$esc[38:5:196mP" +
                "$esc[0;1;4:0mB" +
                "$esc[58:2::1:2:3mK" +
                "$esc[48:5:21mQ",
        )
        assertTrue(e.spanAt(0, 0).underline)
        assertEquals(0xFFFF0000.toInt(), e.spanAt(0, 1).fg)
        assertEquals(0xFF00FF00.toInt(), e.spanAt(0, 2).fg)
        assertEquals(TerminalEmulator.PALETTE_256[196], e.spanAt(0, 3).fg)
        assertTrue(e.spanAt(0, 4).bold)
        assertFalse(e.spanAt(0, 4).underline)
        // An underline colour changes nothing that is drawn, and resets nothing.
        assertTrue(e.spanAt(0, 5).bold)
        assertEquals(TerminalEmulator.DEFAULT_FG, e.spanAt(0, 5).fg)
        assertEquals(TerminalEmulator.PALETTE_256[21], e.spanAt(0, 6).bg)
        // The semicolon form of an underline colour does not leak into the pen either.
        val f = emulator(input = "$esc[58;5;9;1mA")
        assertTrue(f.spanAt(0, 0).bold)
        assertEquals(TerminalEmulator.DEFAULT_FG, f.spanAt(0, 0).fg)
    }

    @Test
    fun strikeThroughAndConcealedText() {
        val e = emulator(input = "$esc[9mS$esc[29mN$esc[8mH$esc[28mV")
        assertTrue(e.spanAt(0, 0).strike)
        assertFalse(e.spanAt(0, 1).strike)
        assertTrue(e.spanAt(0, 2).hidden)
        assertFalse(e.spanAt(0, 3).hidden)
        // Concealed text is still text: it copies.
        assertEquals("SNHV", e.screenRow(0))
        val r = emulator(input = "$esc[9;8mx$esc[0my")
        assertFalse(r.spanAt(0, 1).strike)
        assertFalse(r.spanAt(0, 1).hidden)
    }

    @Test
    fun softResetRestoresModesButKeepsTheScreen() {
        val e = emulator(cols = 10, input = "keep$esc[?7l$esc[4h$esc[3;5r$esc[1m$esc[!p\r")
        assertEquals("keep", e.screenRow(0))
        e.feedStr("0123456789ab")
        assertEquals("0123456789", e.screenRow(0))
        assertEquals("ab", e.screenRow(1))
        assertFalse(e.spanAt(1, 0).bold)
    }

    @Test
    fun c1ControlsSentAsTextAreNotDrawn() {
        assertEquals("ab", emulator(input = "a\u009B\u0085b").screenRow(0))
    }

    @Test
    fun aFullResetForgetsModes() {
        val e = emulator(cols = 10, input = "$esc[?7l$esc[4h$esc(0${esc}c")
        e.feedStr("q0123456789x")
        assertEquals("q012345678", e.screenRow(0))
        assertEquals("9x", e.screenRow(1))
        assertNull(e.takeReplies())
    }
}
