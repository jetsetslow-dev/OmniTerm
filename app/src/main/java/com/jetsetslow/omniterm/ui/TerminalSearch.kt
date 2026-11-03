package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.term.TermRow

/**
 * One occurrence of a search in the terminal, from cell [startCol] of absolute [row] (scrollback
 * first) to cell [endCol] of [endRow], end exclusive. [endRow] is later than [row] only for a match
 * that runs across a soft wrap.
 */
data class TerminalMatch(val row: Int, val startCol: Int, val endRow: Int, val endCol: Int) {
    /** The cells this match covers on absolute [row], end exclusive, or null if none. */
    fun colsOn(row: Int, cols: Int): IntRange? = when {
        row < this.row || row > endRow -> null
        else -> (if (row == this.row) startCol else 0) until (if (row == endRow) endCol else cols)
    }
}

/**
 * Every occurrence of [query] in [rows], top to bottom, ignoring case. [firstRow] is the absolute
 * index of `rows[0]`.
 *
 * Columns are terminal cells, not characters: a wide glyph (CJK, most emoji) takes two cells, so a
 * match after one would otherwise be highlighted a cell too far left. A row that soft-wraps into the
 * next is searched joined to it, so a long command that broke at the right edge is still found.
 */
fun findInTerminal(rows: List<TermRow>, query: String, firstRow: Int = 0): List<TerminalMatch> {
    if (query.isEmpty()) return emptyList()
    val needle = query.lowercase()
    val matches = ArrayList<TerminalMatch>()
    var i = 0
    while (i < rows.size) {
        // One logical line: this row and every row it soft-wraps into.
        val text = StringBuilder()
        val cellOf = ArrayList<Int>()   // text index → first cell of its glyph, within its own row
        val widthOf = ArrayList<Int>()  // text index → cells its glyph takes
        val rowOf = ArrayList<Int>()    // text index → row index in [rows]
        while (true) {
            var col = 0
            for (span in rows[i].spans) {
                val (glyphs, widths) = span.cellLayout()
                for (g in glyphs.indices) {
                    val width = widths[g].coerceIn(1, 2)
                    for (c in glyphs[g]) {
                        text.append(c)
                        cellOf.add(col)
                        widthOf.add(width)
                        rowOf.add(i)
                    }
                    col += width
                }
            }
            if (!rows[i].softWrap || i + 1 >= rows.size) break
            i++
        }
        val haystack = text.toString().lowercase()
        // lowercase() keeps the length for almost all text; where it does not, skip rather than misplace.
        if (haystack.length == text.length) {
            var from = 0
            while (true) {
                val at = haystack.indexOf(needle, from)
                if (at < 0) break
                val last = at + needle.length - 1
                matches += TerminalMatch(
                    row = firstRow + rowOf[at],
                    startCol = cellOf[at],
                    endRow = firstRow + rowOf[last],
                    endCol = cellOf[last] + widthOf[last],
                )
                from = at + needle.length
            }
        }
        i++
    }
    return matches
}

/**
 * The terminal find bar's matches and which one is current. A plain class, like
 * [TerminalViewportState], so its rules are unit-tested: a new search starts at the newest match at
 * or above the bottom of the screen, as the most recent output is what the user just saw; fresh
 * results for the same search keep the same match; stepping wraps around.
 */
@Stable
class TerminalFindState {
    var matches by mutableStateOf<List<TerminalMatch>>(emptyList())
        private set
    var current by mutableIntStateOf(-1)
        private set
    val currentMatch: TerminalMatch? get() = matches.getOrNull(current)

    /** Results of a new search. The current match is the newest one at or above [bottomRow]. */
    fun showResults(found: List<TerminalMatch>, bottomRow: Int) {
        matches = found
        current = found.indexOfLast { it.row <= bottomRow }.takeIf { it >= 0 } ?: if (found.isEmpty()) -1 else 0
    }

    /**
     * Results of the same search after output changed. Rows trimmed off the top of the scrollback
     * since the last results move every match [shift] rows up; the current match stays current
     * while it is still there, and otherwise the nearest one at or above it takes over.
     */
    fun refresh(found: List<TerminalMatch>, shift: Int) {
        val before = currentMatch?.let { it.copy(row = it.row - shift, endRow = it.endRow - shift) }
        matches = found
        current = when {
            found.isEmpty() -> -1
            before == null -> current.coerceIn(0, found.lastIndex)
            else -> found.indexOf(before).takeIf { it >= 0 }
                ?: found.indexOfLast { it.row <= before.row }.takeIf { it >= 0 }
                ?: 0
        }
    }

    /** Steps to the match above the current one, wrapping to the newest. */
    fun older(): TerminalMatch? = step(-1)

    /** Steps to the match below the current one, wrapping to the oldest. */
    fun newer(): TerminalMatch? = step(1)

    private fun step(by: Int): TerminalMatch? {
        if (matches.isEmpty()) return null
        current = if (current < 0) (if (by < 0) matches.lastIndex else 0) else Math.floorMod(current + by, matches.size)
        return currentMatch
    }

    fun clear() {
        matches = emptyList()
        current = -1
    }
}
