package com.jetsetslow.omniterm.shared.ui

import com.jetsetslow.omniterm.data.term.TermRow
import com.jetsetslow.omniterm.data.term.TermSpan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private fun span(
    text: String,
    glyphs: List<String> = emptyList(),
    widths: List<Int> = emptyList(),
) = TermSpan(text = text, fg = 0, bg = 0, bold = false, inverse = false, glyphs = glyphs, glyphWidths = widths)

class TerminalGridMetricsTest {
    @Test
    fun plainTextCountsOneColumnPerCharacter() {
        assertEquals(5, spanColumnWidth(span("hello")))
        assertEquals(0, spanColumnWidth(span("")))
    }

    @Test
    fun wideGlyphsCountTwoColumns() {
        // Two CJK glyphs are four columns, not two characters.
        val cjk = span("日本", glyphs = listOf("日", "本"), widths = listOf(2, 2))
        assertEquals(4, spanColumnWidth(cjk))

        // An emoji is one glyph of two columns, though it is two UTF-16 units.
        val emoji = span("😀", glyphs = listOf("😀"), widths = listOf(2))
        assertEquals(2, spanColumnWidth(emoji))
        assertEquals(2, emoji.text.length, "the fixture really is a surrogate pair")
    }

    @Test
    fun outOfRangeWidthsAreClampedRatherThanTrusted() {
        val hostile = span("ab", glyphs = listOf("a", "b"), widths = listOf(0, 99))
        assertEquals(3, spanColumnWidth(hostile), "a crafted width must not stretch the grid")
    }

    @Test
    fun mismatchedGlyphMetadataFallsBackToTextLength() {
        val inconsistent = span("abc", glyphs = listOf("a", "b", "c"), widths = listOf(1, 1))
        assertEquals(3, spanColumnWidth(inconsistent))
    }

    @Test
    fun rowWidthSumsItsSpans() {
        val row = TermRow(listOf(span("ab"), span("日", glyphs = listOf("日"), widths = listOf(2))))
        assertEquals(4, rowColumnWidth(row))
        assertEquals(0, rowColumnWidth(TermRow(emptyList())))
    }

    @Test
    fun onlyTheVisibleRowsPlusOverscanAreDrawn() {
        // A 50k-line scrollback must cost the same per frame as a 24-line one.
        val range = visibleRowRange(scrollOffset = 0.0, viewportHeight = 240.0, cellHeight = 20.0, rowCount = 50_000)
        assertEquals(0, range.first)
        assertEquals(13, range.last, "12 visible rows plus one overscan row")
        assertTrue(range.count() < 20)
    }

    @Test
    fun scrolledViewportsStartAtTheirOwnRow() {
        val range = visibleRowRange(scrollOffset = 1_000.0, viewportHeight = 200.0, cellHeight = 20.0, rowCount = 5_000)
        assertEquals(50, range.first)
        assertEquals(61, range.last)
    }

    @Test
    fun rangeIsClampedAtTheEndOfTheBuffer() {
        val range = visibleRowRange(scrollOffset = 180.0, viewportHeight = 200.0, cellHeight = 20.0, rowCount = 12)
        assertEquals(9, range.first)
        assertEquals(11, range.last, "never past the last row")
    }

    @Test
    fun degenerateInputsDrawNothingRatherThanCrash() {
        assertTrue(visibleRowRange(0.0, 100.0, 20.0, rowCount = 0).isEmpty())
        assertTrue(visibleRowRange(0.0, 100.0, cellHeight = 0.0, rowCount = 10).isEmpty())
        assertTrue(visibleRowRange(0.0, viewportHeight = 0.0, cellHeight = 20.0, rowCount = 10).isEmpty())
    }
}
