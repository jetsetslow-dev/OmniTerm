package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.terminalGeometryMatches
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalGeometryPolicyTest {
    @Test
    fun captureRequiresExactColumnsRowsAndGeneration() {
        assertTrue(terminalGeometryMatches(80, 24, 7, 80, 24, 7))
        assertFalse(terminalGeometryMatches(80, 24, 7, 100, 24, 8))
        assertFalse(terminalGeometryMatches(80, 24, 7, 80, 30, 8))
        // A resize away and back can restore the same dimensions but not the same coordinate space.
        assertFalse(terminalGeometryMatches(80, 24, 7, 80, 24, 9))
    }
}
