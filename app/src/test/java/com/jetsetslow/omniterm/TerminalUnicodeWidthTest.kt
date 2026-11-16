package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.UnicodeWidthTable
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The terminal gives each character the width the programs drawing on it assume: Claude Code
 * (Ink's string-width), Codex (Rust's unicode-width) and tmux all follow Unicode's East Asian Width
 * and emoji presentation. When the two disagree by one cell, every later redraw on that row lands
 * one column off: shifted text, leftover letters and blank cells.
 */
class TerminalUnicodeWidthTest {
    private val esc = "\u001B"

    private fun TerminalEmulator.feedStr(s: String) = feed(s.toByteArray(Charsets.UTF_8))

    /** The column the cursor reaches after [text] on an empty row. */
    private fun columnsOf(text: String): Int =
        TerminalEmulator(80, 24).also { it.feedStr(text) }.snapshot().cursorCol

    private fun row0(e: TerminalEmulator) = e.snapshot().rows[0].spans.joinToString("") { it.text }.trimEnd()

    @Test
    fun emojiThatTuisDrawTwoCellsWideTakeTwo() {
        // Wide by Unicode (emoji presentation), which the old table drew one cell wide.
        val wide = listOf(
            0x2705, 0x274C, 0x2728, 0x2B50, 0x26A1, 0x23F3, 0x231B, 0x26D4, 0x2753, 0x2754, 0x2755,
            0x2757, 0x2795, 0x2796, 0x2797, 0x2B1B, 0x2B1C, 0x2B55, 0x231A, 0x23E9, 0x23EC, 0x23F0,
            0x25FD, 0x25FE, 0x2614, 0x2615, 0x2648, 0x2653, 0x267F, 0x2693, 0x26AA, 0x26AB, 0x26BD,
            0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x270A,
            0x270B, 0x274E, 0x27B0, 0x27BF, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191, 0x1F19A, 0x1F200,
            0x1F680, 0x1F916, 0x1F4C1, 0x1F642, 0x1FAE8,
        )
        for (cp in wide) {
            assertEquals("U+%04X then x".format(cp), 3, columnsOf(String(Character.toChars(cp)) + "x"))
        }
    }

    @Test
    fun pictographsWithTextPresentationTakeOne() {
        // 🌡 🖥 🛠 🗂 ⚙ ❤ ☑ ➡ ✏: one cell unless VS16 asks for the emoji form.
        for (cp in listOf(0x1F321, 0x1F5A5, 0x1F6E0, 0x1F5C2, 0x2699, 0x2764, 0x2611, 0x27A1, 0x270F)) {
            val glyph = String(Character.toChars(cp))
            assertEquals("U+%04X".format(cp), 1, columnsOf(glyph))
            assertEquals("U+%04X with VS16".format(cp), 2, columnsOf(glyph + "️"))
            assertEquals("U+%04X with VS15".format(cp), 1, columnsOf(glyph + "︎"))
        }
    }

    @Test
    fun claudeCodesOwnGlyphsTakeOne() {
        for (glyph in "⏺⎿✻✶✳✢✽·❯›⏵⏸★☆✔✓✗✘⚠☐☒■□▪•●○◯◉↓↑→←⧉│─└├┌┐┘╭╮╯╰▌█░▒▓…⋯") {
            assertEquals("$glyph U+%04X".format(glyph.code), 1, columnsOf(glyph.toString()))
        }
    }

    @Test
    fun regionalIndicatorsPairIntoAFlag() {
        assertEquals("one indicator", 1, columnsOf("🇮"))
        assertEquals("a flag", 2, columnsOf("🇮🇳"))
        assertEquals("a flag then a lone indicator", 3, columnsOf("🇮🇳🇯"))
    }

    @Test
    fun eastAsianTextFollowsUnicode() {
        assertEquals(2, columnsOf("中"))
        assertEquals(2, columnsOf("한"))
        assertEquals(2, columnsOf("Ａ")) // fullwidth
        assertEquals(1, columnsOf("ｱ")) // halfwidth katakana
        assertEquals(2, columnsOf("䷀")) // a Yijing hexagram: wide since Unicode 16
        assertEquals(1, columnsOf("☯")) // neutral
        assertEquals(1, columnsOf("〿")) // half fill space
        assertEquals(2, columnsOf(String(Character.toChars(0x2A6DF)))) // plane 2
        assertEquals(2, columnsOf(String(Character.toChars(0x2FFF0)))) // unassigned in plane 2
        assertEquals(1, columnsOf("é"))
        assertEquals(1, columnsOf("é")) // combining accent
        assertEquals(2, columnsOf("👩‍💻")) // a ZWJ sequence
        assertEquals(2, columnsOf("1️⃣")) // keycap
    }

    /**
     * A TUI's differential redraw: it moves to a column it computed itself and writes there. With
     * ✅ two cells wide on both sides the write lands on the letter the TUI meant.
     */
    @Test
    fun aRedrawAfterAnEmojiLandsInTheTuisColumn() {
        val e = TerminalEmulator(80, 24)
        e.feedStr("✅ done$esc[G$esc[3CX")
        assertEquals("✅ Xone", row0(e))
        val f = TerminalEmulator(80, 24)
        f.feedStr("🖥 x$esc[G$esc[2CY")
        assertEquals("🖥 Y", row0(f))
    }

    @Test
    fun theTableAnswersAtItsEdges() {
        assertEquals("16.0.0", UnicodeWidthTable.UNICODE_VERSION)
        // Every wide code point, counted through the lookup, as the generator counted them.
        assertEquals(WIDE_CODE_POINTS, (0..0x10FFFF).count(UnicodeWidthTable::isWide))
        for ((cp, wide) in listOf(
            0x10FF to false, 0x1100 to true, 0x115F to true, 0x1160 to false,
            0x2319 to false, 0x231A to true, 0x231B to true, 0x231C to false,
            0x1F1E5 to false, 0x1F1E6 to false, 0x1F1FF to false, 0x1F200 to true,
            0x1F300 to true, 0x1F320 to true, 0x1F321 to false,
            0x3FFFD to true, 0x3FFFE to false, 0x10FFFF to false,
        )) {
            assertEquals("U+%04X".format(cp), wide, UnicodeWidthTable.isWide(cp))
        }
    }

    private companion object {
        /** From scripts/generate-unicode-width.py's table for Unicode 16.0.0. */
        const val WIDE_CODE_POINTS = 182_719
    }
}
