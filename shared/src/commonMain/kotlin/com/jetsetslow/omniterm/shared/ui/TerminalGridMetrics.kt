package com.jetsetslow.omniterm.shared.ui

import com.jetsetslow.omniterm.data.term.TermRow
import com.jetsetslow.omniterm.data.term.TermSpan

/**
 * Grid arithmetic every renderer needs, shared so the Android canvas and the native iOS view cannot
 * disagree about where a column is.
 */

/**
 * Display columns a span occupies. Wide glyphs (CJK, emoji) count as two, matching the emulator's
 * own accounting — counting characters instead would drift the grid on the first CJK line, and
 * counting UTF-16 units would drift on the first emoji.
 */
fun spanColumnWidth(span: TermSpan): Int =
    if (span.glyphs.isNotEmpty() && span.glyphWidths.size == span.glyphs.size) {
        span.glyphWidths.sumOf { it.coerceIn(1, 2) }
    } else {
        span.text.length
    }

/** Total display columns in a row. */
fun rowColumnWidth(row: TermRow): Int = row.spans.sumOf { spanColumnWidth(it) }

/**
 * The visible row range for a viewport, plus one row of overscan so a partially scrolled row is
 * never blank at the edge. Returns an empty range when nothing is visible.
 */
fun visibleRowRange(
    scrollOffset: Double,
    viewportHeight: Double,
    cellHeight: Double,
    rowCount: Int,
    overscanRows: Int = 1,
): IntRange {
    if (rowCount <= 0 || cellHeight <= 0.0 || viewportHeight <= 0.0) return IntRange.EMPTY
    val first = (scrollOffset / cellHeight).toInt().coerceIn(0, rowCount - 1)
    val last = (((scrollOffset + viewportHeight) / cellHeight).toInt() + overscanRows)
        .coerceIn(first, rowCount - 1)
    return first..last
}
