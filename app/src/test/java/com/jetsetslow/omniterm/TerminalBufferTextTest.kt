package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.dropBoundaryDuplication
import org.junit.Assert.assertEquals
import org.junit.Test

/** Tests for the scrollback↔screen boundary de-duplication used by "Full buffer" copy. */
class TerminalBufferTextTest {

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
}
