package com.jetsetslow.omniterm.data.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CappedTextBufferTest {
    @Test
    fun keeps_full_text_until_cap_is_exceeded() {
        val buffer = CappedTextBuffer(10)

        buffer.append("hello")
        buffer.append("!")

        assertFalse(buffer.truncated)
        assertEquals("hello!", buffer.text())
    }

    @Test
    fun keeps_latest_tail_after_cap_is_exceeded() {
        val buffer = CappedTextBuffer(5)

        buffer.append("abcdef")
        buffer.append("gh")

        assertTrue(buffer.truncated)
        assertEquals("[Output truncated; showing latest 5 characters]\ndefgh", buffer.text())
    }
}
