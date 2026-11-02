package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.TerminalFindState
import com.jetsetslow.omniterm.ui.TerminalMatch
import com.jetsetslow.omniterm.ui.TerminalViewportState
import com.jetsetslow.omniterm.ui.findInTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Finding text in the terminal: in scrollback and on screen, at the cells it is drawn in. */
class TerminalSearchTest {

    private fun rowsOf(cols: Int, rows: Int, output: String) =
        TerminalEmulator(cols, rows).apply { feed(output.toByteArray()) }.snapshot().rows

    private fun m(row: Int, start: Int, end: Int) = TerminalMatch(row, start, row, end)

    @Test
    fun findsEveryOccurrenceInScrollbackAndOnScreenIgnoringCase() {
        val rows = rowsOf(20, 3, "error one\r\nok\r\nERROR two\r\nok\r\nlast Error\r\n")

        assertEquals(listOf(m(0, 0, 5), m(2, 0, 5), m(4, 5, 10)), findInTerminal(rows, "error"))
    }

    @Test
    fun columnsCountWideGlyphsAsTwoCells() {
        val rows = rowsOf(20, 2, "日本 ok\r\n")

        assertEquals(listOf(m(0, 5, 7)), findInTerminal(rows, "ok"))
        assertEquals(listOf(m(0, 2, 4)), findInTerminal(rows, "本"))
    }

    @Test
    fun aLineThatWrappedAtTheEdgeIsSearchedWholeAndHighlightedOnBothRows() {
        // Ten columns: "0123456789abc" wraps after "9".
        val rows = rowsOf(10, 3, "0123456789abc\r\n")

        val match = findInTerminal(rows, "89ab").single()

        assertEquals(TerminalMatch(0, 8, 1, 2), match)
        assertEquals(8 until 10, match.colsOn(0, cols = 10))
        assertEquals(0 until 2, match.colsOn(1, cols = 10))
        assertNull(match.colsOn(2, cols = 10))
    }

    @Test
    fun anEmptyQueryFindsNothingAndRowsAreNumberedFromFirstRow() {
        val rows = rowsOf(20, 2, "abc\r\n")

        assertEquals(emptyList<TerminalMatch>(), findInTerminal(rows, ""))
        assertEquals(listOf(m(40, 1, 2)), findInTerminal(rows, "b", firstRow = 40))
    }

    @Test
    fun aNewSearchStartsAtTheNewestMatchOnScreenAndStepsWrap() {
        val find = TerminalFindState()
        val found = listOf(m(2, 0, 1), m(10, 0, 1), m(30, 0, 1), m(55, 0, 1))

        find.showResults(found, bottomRow = 40)
        assertEquals(m(30, 0, 1), find.currentMatch)

        assertEquals(m(10, 0, 1), find.older())
        assertEquals(m(2, 0, 1), find.older())
        assertEquals("wraps to the newest", m(55, 0, 1), find.older())
        assertEquals("and back to the oldest", m(2, 0, 1), find.newer())

        find.showResults(found, bottomRow = 1)
        assertEquals("nothing above the screen's bottom: the first below it", m(2, 0, 1), find.currentMatch)

        find.showResults(emptyList(), bottomRow = 40)
        assertNull(find.currentMatch)
        assertNull(find.older())
    }

    @Test
    fun freshResultsKeepTheSameMatchAfterTheScrollbackTrims() {
        val find = TerminalFindState()
        find.showResults(listOf(m(5, 0, 1), m(20, 3, 4), m(30, 0, 1)), bottomRow = 25)
        assertEquals(m(20, 3, 4), find.currentMatch)

        // Three rows trimmed off the top, and a new match below.
        find.refresh(listOf(m(2, 0, 1), m(17, 3, 4), m(27, 0, 1), m(40, 0, 1)), shift = 3)
        assertEquals(m(17, 3, 4), find.currentMatch)

        // Its line scrolled out entirely: the nearest one above takes over.
        find.refresh(listOf(m(2, 0, 1), m(27, 0, 1)), shift = 0)
        assertEquals(m(2, 0, 1), find.currentMatch)

        find.refresh(emptyList(), shift = 0)
        assertNull(find.currentMatch)
    }

    @Test
    fun revealingAMatchMovesTheViewOnlyWhenItIsOffScreenOrUnderTheFindBar() {
        val viewport = TerminalViewportState()
        viewport.onContentChanged(totalRows = 200, visibleRows = 30)
        assertEquals(170, viewport.firstVisibleRow)

        assertEquals("already in view", 170, viewport.reveal(row = 185, totalRows = 200, visibleRows = 30, coveredTopRows = 3))
        assertTrue(viewport.followTail)

        assertEquals(40, viewport.reveal(row = 50, totalRows = 200, visibleRows = 30, coveredTopRows = 3))
        assertFalse("off the tail once a match in scrollback is shown", viewport.followTail)

        // Behind the find bar on the top rows: moved down to clear it.
        assertEquals(31, viewport.reveal(row = 41, totalRows = 200, visibleRows = 30, coveredTopRows = 3))

        assertEquals("never past the tail", 170, viewport.reveal(row = 199, totalRows = 200, visibleRows = 30, coveredTopRows = 3))
        assertTrue(viewport.followTail)
    }
}
