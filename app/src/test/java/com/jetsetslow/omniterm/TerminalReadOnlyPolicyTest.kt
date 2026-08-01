package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.TermKey
import com.jetsetslow.omniterm.ui.terminalKeyAllowedInReadOnly
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalReadOnlyPolicyTest {
    @Test
    fun readOnlyAllowsOnlyExplicitScrollNavigation() {
        assertTrue(terminalKeyAllowedInReadOnly(TermKey.PAGE_UP))
        assertTrue(terminalKeyAllowedInReadOnly(TermKey.PAGE_DOWN))
        assertFalse(terminalKeyAllowedInReadOnly(TermKey.ENTER))
        assertFalse(terminalKeyAllowedInReadOnly(TermKey.BACKSPACE))
        assertFalse(terminalKeyAllowedInReadOnly(TermKey.UP))
        assertFalse(terminalKeyAllowedInReadOnly(TermKey.F1))
    }
}
