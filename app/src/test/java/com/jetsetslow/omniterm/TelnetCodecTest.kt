package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.telnet.TelnetCodec
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.DO
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.DONT
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.IAC
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.SB
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.SE
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.WILL
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.WONT
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class TelnetCodecTest {
    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun TelnetCodec.feed(input: ByteArray): Pair<String, ByteArray> {
        val replies = ByteArrayOutputStream()
        val data = decode(input, input.size, replies)
        return String(data, Charsets.ISO_8859_1) to replies.toByteArray()
    }

    @Test
    fun theHostAskingForWindowSizeAndTerminalTypeGetsBoth() {
        val codec = TelnetCodec(cols = 100, rows = 30)
        val (_, nawsReply) = codec.feed(byteArrayOf(IAC, DO, 31))
        assertArrayEquals(byteArrayOf(IAC, WILL, 31, IAC, SB, 31, 0, 100, 0, 30, IAC, SE), nawsReply)
        val (_, ttypeWill) = codec.feed(byteArrayOf(IAC, DO, 24))
        assertArrayEquals(byteArrayOf(IAC, WILL, 24), ttypeWill)
        val (_, ttypeIs) = codec.feed(byteArrayOf(IAC, SB, 24, 1, IAC, SE))
        assertArrayEquals(byteArrayOf(IAC, SB, 24, 0) + "XTERM-256COLOR".toByteArray() + byteArrayOf(IAC, SE), ttypeIs)
        // A resize is reported once the host asked for sizes, and a 255 in it is doubled.
        assertArrayEquals(byteArrayOf(IAC, SB, 31, 0, IAC, IAC, 0, 40, IAC, SE), codec.resize(255, 40))
    }

    @Test
    fun optionsAskedForAtTheStartAreNotOfferedTwice() {
        val codec = TelnetCodec(80, 24)
        assertArrayEquals(byteArrayOf(IAC, WILL, 31, IAC, WILL, 24, IAC, DO, 3), codec.opening())
        val (_, reply) = codec.feed(byteArrayOf(IAC, DO, 31, IAC, WILL, 3))
        // Only the size itself: the WILL NAWS and DO SGA were already sent.
        assertArrayEquals(byteArrayOf(IAC, SB, 31, 0, 80, 0, 24, IAC, SE), reply)
    }

    @Test
    fun unknownOptionsAreRefusedAndEchoMovesToTheHost() {
        val codec = TelnetCodec(80, 24)
        assertArrayEquals(byteArrayOf(IAC, WONT, 39), codec.feed(byteArrayOf(IAC, DO, 39)).second)
        assertArrayEquals(byteArrayOf(IAC, DONT, 34), codec.feed(byteArrayOf(IAC, WILL, 34)).second)
        assertFalse(codec.hostEchoes)
        assertArrayEquals("ls\r\n".toByteArray(), codec.localEcho("ls\r".toByteArray()))
        assertArrayEquals(byteArrayOf(IAC, DO, 1), codec.feed(byteArrayOf(IAC, WILL, 1)).second)
        assertTrue(codec.hostEchoes)
        assertNull(codec.localEcho("ls\r".toByteArray()))
        // Saying it again changes nothing, so nothing is said back: no negotiation loop.
        assertEquals(0, codec.feed(byteArrayOf(IAC, WILL, 1)).second.size)
    }

    @Test
    fun commandsAreStrippedEvenWhenSplitAcrossReads() {
        val codec = TelnetCodec(80, 24)
        assertEquals("log", codec.feed("log".toByteArray() + byteArrayOf(IAC)).first)
        val (data, reply) = codec.feed(byteArrayOf(DO, 31) + "in: ".toByteArray())
        assertEquals("in: ", data)
        assertEquals(WILL, reply[1])
        // A doubled IAC is a 255 data byte; CR NUL is a bare CR.
        assertEquals("aÿb\rc\r\n", codec.feed(bytes(0x61, 255, 255, 0x62, 13, 0, 0x63, 13, 10)).first)
        assertEquals("", codec.feed(byteArrayOf(IAC, 241.toByte())).first)
    }

    @Test
    fun typedInputDoublesTheCommandByteAndEndsCrWithNul() {
        val codec = TelnetCodec(80, 24)
        assertArrayEquals(bytes(0x6C, 0x73, 13, 0), codec.encode("ls\r".toByteArray()))
        assertArrayEquals(bytes(13, 10), codec.encode(bytes(13, 10)))
        assertArrayEquals(bytes(255, 255), codec.encode(bytes(255)))
    }
}
