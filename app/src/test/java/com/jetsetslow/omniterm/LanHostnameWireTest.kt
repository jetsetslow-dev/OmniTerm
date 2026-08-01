package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.LanHostnameWire
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-format tests for the LAN hostname fallbacks. These codecs are the part of the host scan that
 * cannot be exercised without real devices on a real network, so the encoding and — more importantly
 * — the parsing of hostile/truncated responses is pinned here.
 */
class LanHostnameWireTest {

    // ── DNS / mDNS reverse PTR ──

    @Test
    fun reversePtrQueryAsksForTheInAddrArpaNameInReverseOctetOrder() {
        val query = LanHostnameWire.buildReversePtrQuery("192.168.11.5", transactionId = 0x1234)
        assertNotNull(query)
        query!!

        assertEquals(0x12, query[0].toInt() and 0xFF)
        assertEquals(0x34, query[1].toInt() and 0xFF)
        assertEquals(1, readShort(query, 4)) // QDCOUNT
        assertEquals(0, readShort(query, 6)) // ANCOUNT

        val (name, next) = readLabels(query, 12)
        assertEquals("5.11.168.192.in-addr.arpa", name)
        assertEquals(LanHostnameWire.TYPE_PTR, readShort(query, next))
        // Top bit set = "answer me unicast", so a plain DatagramSocket hears the mDNS reply.
        assertEquals(0x8001, readShort(query, next + 2))
    }

    @Test
    fun reversePtrQueryRejectsAnythingThatIsNotADottedQuad() {
        assertNull(LanHostnameWire.buildReversePtrQuery("192.168.1", 0))
        assertNull(LanHostnameWire.buildReversePtrQuery("192.168.1.5.9", 0))
        assertNull(LanHostnameWire.buildReversePtrQuery("192.168.1.999", 0))
        assertNull(LanHostnameWire.buildReversePtrQuery("nas.local", 0))
        assertNull(LanHostnameWire.buildReversePtrQuery("", 0))
    }

    @Test
    fun parsesCompressedPtrAnswer() {
        val packet = ptrResponse(question = "5.11.168.192.in-addr.arpa", answer = "nas.local", compress = true)
        assertEquals("nas.local", LanHostnameWire.parsePtrAnswer(packet, packet.size))
    }

    @Test
    fun parsesUncompressedPtrAnswer() {
        val packet = ptrResponse(question = "5.11.168.192.in-addr.arpa", answer = "printer.local", compress = false)
        assertEquals("printer.local", LanHostnameWire.parsePtrAnswer(packet, packet.size))
    }

    @Test
    fun parsesPtrAnswerFromResponderThatOmitsTheQuestion() {
        // mDNS responders may answer with QDCOUNT=0; the parser must follow the header counts
        // instead of assuming the question is echoed back at a fixed offset.
        val packet = ptrResponse(question = null, answer = "tar-server.local", compress = false)
        assertEquals("tar-server.local", LanHostnameWire.parsePtrAnswer(packet, packet.size))
    }

    @Test
    fun skipsNonPtrAnswersAndReturnsNullWhenNoneMatch() {
        val packet = buildPacket(questions = 1, answers = 1) { out ->
            writeLabels(out, "5.11.168.192.in-addr.arpa")
            out.writeShort(LanHostnameWire.TYPE_PTR)
            out.writeShort(LanHostnameWire.CLASS_IN)
            // A TXT answer, not PTR.
            out.write(0xC0); out.write(0x0C)
            out.writeShort(16)
            out.writeShort(LanHostnameWire.CLASS_IN)
            out.writeInt(120)
            out.writeShort(4)
            out.write(byteArrayOf(3, 'a'.code.toByte(), 'b'.code.toByte(), 'c'.code.toByte()))
        }
        assertNull(LanHostnameWire.parsePtrAnswer(packet, packet.size))
    }

    @Test
    fun truncatedResponsesAreRejectedRatherThanReadPastTheBuffer() {
        val packet = ptrResponse(question = "5.11.168.192.in-addr.arpa", answer = "nas.local", compress = true)
        for (cut in 0 until packet.size) {
            // Must never throw, whatever the truncation point.
            LanHostnameWire.parsePtrAnswer(packet, cut)
        }
        assertNull(LanHostnameWire.parsePtrAnswer(ByteArray(4), 4))
        assertNull(LanHostnameWire.parsePtrAnswer(ByteArray(0), 0))
    }

    @Test
    fun cyclicCompressionPointerTerminatesInsteadOfSpinningForever() {
        // Answer RDATA is a pointer to itself: a naive parser loops forever on this.
        val packet = buildPacket(questions = 0, answers = 1) { out ->
            out.write(0x00) // answer name = root
            out.writeShort(LanHostnameWire.TYPE_PTR)
            out.writeShort(LanHostnameWire.CLASS_IN)
            out.writeInt(120)
            out.writeShort(2)
            out.write(0xC0); out.write(0x0F) // points back at itself (offset 15)
        }
        assertNull(LanHostnameWire.parsePtrAnswer(packet, packet.size))
    }

    // ── NetBIOS node status ──

    @Test
    fun netbiosQueryFirstLevelEncodesTheWildcardName() {
        val query = LanHostnameWire.buildNetbiosNodeStatusQuery(transactionId = 0x00AB)

        assertEquals(0x00, query[0].toInt() and 0xFF)
        assertEquals(0xAB, query[1].toInt() and 0xFF)
        assertEquals(1, readShort(query, 4)) // QDCOUNT
        assertEquals(32, query[12].toInt() and 0xFF) // encoded name length

        // "*" (0x2A) then 15 NULs → "CK" then 30 'A's.
        val encoded = String(query, 13, 32, Charsets.US_ASCII)
        assertEquals("CK" + "A".repeat(30), encoded)
        assertEquals(0, query[45].toInt()) // root label
        assertEquals(LanHostnameWire.TYPE_NBSTAT, readShort(query, 46))
        assertEquals(LanHostnameWire.CLASS_IN, readShort(query, 48))
    }

    @Test
    fun netbiosResponseYieldsTheUniqueWorkstationNameNotTheWorkgroup() {
        val packet = netbiosResponse(
            listOf(
                // A group entry first — this is the workgroup, and must be skipped.
                Triple("WORKGROUP", 0x00, true),
                Triple("TARSERVER", 0x00, false),
                Triple("TARSERVER", 0x20, false),
            ),
        )
        assertEquals("TARSERVER", LanHostnameWire.parseNetbiosNodeStatus(packet, packet.size))
    }

    @Test
    fun netbiosResponseWithOnlyServiceEntriesHasNoMachineName() {
        // Suffix 0x20 is the file-server service, not the machine name.
        val packet = netbiosResponse(listOf(Triple("TARSERVER", 0x20, false)))
        assertNull(LanHostnameWire.parseNetbiosNodeStatus(packet, packet.size))
    }

    @Test
    fun truncatedNetbiosResponsesAreRejected() {
        val packet = netbiosResponse(listOf(Triple("TARSERVER", 0x00, false)))
        for (cut in 0 until packet.size) {
            LanHostnameWire.parseNetbiosNodeStatus(packet, cut)
        }
        assertNull(LanHostnameWire.parseNetbiosNodeStatus(ByteArray(8), 8))
    }

    // ── Normalisation ──

    @Test
    fun normalisationRejectsTheNonAnswersAResolverHandsBack() {
        // What the JDK returns when the reverse lookup fails: the literal it was given.
        assertEquals("", LanHostnameWire.normalizeHostname("192.168.11.5", "192.168.11.5"))
        assertEquals("", LanHostnameWire.normalizeHostname("5.11.168.192.in-addr.arpa", "192.168.11.5"))
        assertEquals("", LanHostnameWire.normalizeHostname(null, "192.168.11.5"))
        assertEquals("", LanHostnameWire.normalizeHostname("   ", "192.168.11.5"))
    }

    @Test
    fun normalisationDropsTheFqdnRootDot() {
        assertEquals("nas.local", LanHostnameWire.normalizeHostname("nas.local.", "192.168.11.5"))
        assertEquals("nas.local", LanHostnameWire.normalizeHostname("  nas.local  ", "192.168.11.5"))
    }

    @Test
    fun normalisationKeepsARealName() {
        assertEquals("tar-server.lan", LanHostnameWire.normalizeHostname("tar-server.lan", "192.168.11.5"))
    }

    // ── helpers ──

    private fun readShort(buf: ByteArray, at: Int): Int =
        ((buf[at].toInt() and 0xFF) shl 8) or (buf[at + 1].toInt() and 0xFF)

    private fun readLabels(buf: ByteArray, from: Int): Pair<String, Int> {
        val parts = mutableListOf<String>()
        var i = from
        while (true) {
            val len = buf[i].toInt() and 0xFF
            if (len == 0) return parts.joinToString(".") to (i + 1)
            parts.add(String(buf, i + 1, len, Charsets.US_ASCII))
            i += 1 + len
        }
    }

    private fun ByteArrayOutputStream.writeShort(value: Int) {
        write((value ushr 8) and 0xFF)
        write(value and 0xFF)
    }

    private fun ByteArrayOutputStream.writeInt(value: Int) {
        writeShort((value ushr 16) and 0xFFFF)
        writeShort(value and 0xFFFF)
    }

    private fun writeLabels(out: ByteArrayOutputStream, name: String) {
        for (label in name.split('.')) {
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
    }

    private fun buildPacket(questions: Int, answers: Int, body: (ByteArrayOutputStream) -> Unit): ByteArray {
        val out = ByteArrayOutputStream()
        out.writeShort(0)
        out.writeShort(0x8400) // response, authoritative
        out.writeShort(questions)
        out.writeShort(answers)
        out.writeShort(0)
        out.writeShort(0)
        body(out)
        return out.toByteArray()
    }

    private fun ptrResponse(question: String?, answer: String, compress: Boolean): ByteArray =
        buildPacket(questions = if (question != null) 1 else 0, answers = 1) { out ->
            if (question != null) {
                writeLabels(out, question)
                out.writeShort(LanHostnameWire.TYPE_PTR)
                out.writeShort(LanHostnameWire.CLASS_IN)
            }
            if (compress && question != null) {
                out.write(0xC0); out.write(0x0C) // pointer to the question name at offset 12
            } else {
                out.write(0x00) // root
            }
            out.writeShort(LanHostnameWire.TYPE_PTR)
            out.writeShort(LanHostnameWire.CLASS_IN)
            out.writeInt(120)

            val rdata = ByteArrayOutputStream().also { writeLabels(it, answer) }.toByteArray()
            out.writeShort(rdata.size)
            out.write(rdata)
        }

    /** [names] is (name, suffix byte, isGroup). */
    private fun netbiosResponse(names: List<Triple<String, Int, Boolean>>): ByteArray {
        val encodedName = ByteArray(34).also {
            it[0] = 32
            for (i in 0 until 32) it[1 + i] = 'A'.code.toByte()
            it[33] = 0
        }
        val rdata = ByteArrayOutputStream().apply {
            write(names.size)
            for ((name, suffix, isGroup) in names) {
                write(name.padEnd(15, ' ').toByteArray(Charsets.US_ASCII), 0, 15)
                write(suffix)
                writeShort(if (isGroup) 0x8000 else 0x0400)
            }
        }.toByteArray()

        val out = ByteArrayOutputStream()
        out.writeShort(0)
        out.writeShort(0x8400)
        out.writeShort(1) // QDCOUNT — the question is echoed back
        out.writeShort(1) // ANCOUNT
        out.writeShort(0)
        out.writeShort(0)
        out.write(encodedName) // question name
        out.writeShort(LanHostnameWire.TYPE_NBSTAT)
        out.writeShort(LanHostnameWire.CLASS_IN)
        out.write(encodedName) // answer name
        out.writeShort(LanHostnameWire.TYPE_NBSTAT)
        out.writeShort(LanHostnameWire.CLASS_IN)
        out.writeInt(0)
        out.writeShort(rdata.size)
        out.write(rdata)
        return out.toByteArray()
    }

    @Test
    fun helperSanity() {
        // Guards the test's own encoder: a broken helper would make the parser tests meaningless.
        val packet = ptrResponse("5.11.168.192.in-addr.arpa", "nas.local", compress = true)
        assertTrue(packet.size > 12)
        assertEquals(1, readShort(packet, 6))
    }
}
