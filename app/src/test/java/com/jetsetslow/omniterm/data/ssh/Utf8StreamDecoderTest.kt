package com.jetsetslow.omniterm.data.ssh

import com.jetsetslow.omniterm.data.term.Utf8StreamDecoder
import org.junit.Assert.assertEquals
import org.junit.Test

class Utf8StreamDecoderTest {
    @Test
    fun preservesCodePointsAcrossEveryPossibleReadBoundary() {
        val expected = "ascii € ✓ 😀 tail"
        val bytes = expected.toByteArray(Charsets.UTF_8)
        for (split in 0..bytes.size) {
            val decoder = Utf8StreamDecoder()
            val actual = decoder.decode(bytes.copyOfRange(0, split)) +
                decoder.decode(bytes.copyOfRange(split, bytes.size)) + decoder.finish()
            assertEquals("split=$split", expected, actual)
        }
    }

    @Test
    fun invalidLeadDoesNotConsumeFollowingAscii() {
        val decoder = Utf8StreamDecoder()
        assertEquals("�A", decoder.decode(byteArrayOf(0xC2.toByte(), 'A'.code.toByte())) + decoder.finish())
    }

    @Test
    fun incompleteTailIsReplacedOnlyAtEndOfInput() {
        val decoder = Utf8StreamDecoder()
        assertEquals("", decoder.decode(byteArrayOf(0xE2.toByte(), 0x82.toByte())))
        assertEquals("�", decoder.finish())
    }

    @Test
    fun malformedSplitLeadDoesNotStrandFollowingAscii() {
        for (lead in listOf(0xE2, 0xF0)) {
            val decoder = Utf8StreamDecoder()
            assertEquals("", decoder.decode(byteArrayOf(lead.toByte())))
            assertEquals("�A", decoder.decode(byteArrayOf('A'.code.toByte())))
            assertEquals("", decoder.finish())
        }
    }
}
