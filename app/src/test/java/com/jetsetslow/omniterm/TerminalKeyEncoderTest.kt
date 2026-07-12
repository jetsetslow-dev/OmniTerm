package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.TermKey
import com.jetsetslow.omniterm.ui.TerminalKeyEncoder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalKeyEncoderTest {
    @Test fun conventionalControlMappingsAreExplicit() {
        assertEquals(0x00.toByte(), TerminalKeyEncoder.controlByte('2'.code))
        assertEquals(0x03.toByte(), TerminalKeyEncoder.controlByte('c'.code))
        assertEquals(0x1E.toByte(), TerminalKeyEncoder.controlByte('6'.code))
        assertEquals(0x1F.toByte(), TerminalKeyEncoder.controlByte('/'.code))
        assertEquals(0x7F.toByte(), TerminalKeyEncoder.controlByte('?'.code))
        assertEquals(null, TerminalKeyEncoder.controlByte('界'.code))
    }

    @Test fun modifiersReachNavigationAndFunctionKeys() {
        assertEncoded("\u001B[3;6~", TermKey.DELETE, shift = true, ctrl = true)
        assertEncoded("\u001B[5;3~", TermKey.PAGE_UP, alt = true)
        assertEncoded("\u001B[1;8P", TermKey.F1, shift = true, alt = true, ctrl = true)
        assertEncoded("\u001B[24;5~", TermKey.F12, ctrl = true)
    }

    @Test fun applicationCursorModeCoversHomeAndEnd() {
        assertArrayEquals("\u001BOH".toByteArray(), encode(TermKey.HOME, app = true))
        assertArrayEquals("\u001BOF".toByteArray(), encode(TermKey.END, app = true))
    }

    private fun assertEncoded(expected: String, key: TermKey, shift: Boolean = false, alt: Boolean = false, ctrl: Boolean = false) {
        assertArrayEquals(expected.toByteArray(), encode(key, shift = shift, alt = alt, ctrl = ctrl))
    }

    private fun encode(key: TermKey, app: Boolean = false, shift: Boolean = false, alt: Boolean = false, ctrl: Boolean = false) =
        TerminalKeyEncoder.encode(key, app, shift, alt, ctrl)
}
