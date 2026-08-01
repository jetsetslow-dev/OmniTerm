package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.ui.TerminalClipboardPasteAction
import com.jetsetslow.omniterm.ui.terminalClipboardPasteAction
import org.junit.Test

class TerminalClipboardPastePolicyTest {
    @Test
    fun emptyClipboardDoesNotSendInput() {
        assertThat(terminalClipboardPasteAction(null, readOnly = false))
            .isEqualTo(TerminalClipboardPasteAction.EMPTY)
        assertThat(terminalClipboardPasteAction("", readOnly = false))
            .isEqualTo(TerminalClipboardPasteAction.EMPTY)
    }

    @Test
    fun readOnlyBlocksClipboardInput() {
        assertThat(terminalClipboardPasteAction("rm -rf important", readOnly = true))
            .isEqualTo(TerminalClipboardPasteAction.BLOCKED_READ_ONLY)
    }

    @Test
    fun smallPasteSendsAndLargePasteRequiresConfirmation() {
        assertThat(terminalClipboardPasteAction("ls -la", readOnly = false))
            .isEqualTo(TerminalClipboardPasteAction.SEND)
        assertThat(terminalClipboardPasteAction("x".repeat(101), readOnly = false))
            .isEqualTo(TerminalClipboardPasteAction.CONFIRM)
    }
}
