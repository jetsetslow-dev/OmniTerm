package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.portAfterProtocolSwitch
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The share form's port when the protocol changes, ported from Flutter (`withProtocol` in
 * `network_share_form.dart`, the same cases as its "switching protocol moves a default port but
 * never a typed one" test).
 */
class ShareProtocolPortTest {

    @Test
    fun `a default port moves with the protocol`() {
        assertEquals("22", portAfterProtocolSwitch("445", oldDefault = 445, newDefault = 22))
        assertEquals("2049", portAfterProtocolSwitch("22", oldDefault = 22, newDefault = 2049))
    }

    @Test
    fun `a blank port takes the new default`() {
        assertEquals("21", portAfterProtocolSwitch("", oldDefault = 0, newDefault = 21))
        assertEquals("21", portAfterProtocolSwitch("  ", oldDefault = 445, newDefault = 21))
    }

    @Test
    fun `a typed port is never overwritten`() {
        // A NAS on a non-standard port would otherwise stop answering with no visible cause.
        assertEquals("5006", portAfterProtocolSwitch("5006", oldDefault = 443, newDefault = 22))
        assertEquals("2222", portAfterProtocolSwitch("2222", oldDefault = 22, newDefault = 445))
    }

    @Test
    fun `a protocol without a default leaves the port blank`() {
        assertEquals("", portAfterProtocolSwitch("445", oldDefault = 445, newDefault = 0))
    }
}
