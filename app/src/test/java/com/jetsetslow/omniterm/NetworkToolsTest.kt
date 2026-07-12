package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class NetworkToolsTest {

    @Test
    fun testIsIpAddress() {
        assertTrue(isIpAddress("127.0.0.1"))
        assertTrue(isIpAddress("8.8.8.8"))
        assertTrue(isIpAddress("192.168.1.1"))
        assertTrue(isIpAddress("2001:db8::1"))
        assertTrue(isIpAddress("::1"))

        assertFalse(isIpAddress("google.com"))
        assertFalse(isIpAddress("www.google.com"))
        assertFalse(isIpAddress("localhost"))
        assertFalse(isIpAddress("123"))
        assertFalse(isIpAddress("192.168.1.300")) // invalid IPv4 octet (will fail pattern or resolve)
    }

    @Test
    fun testCleanWhoisServerUri() {
        assertEquals("whois.ripe.net", cleanWhoisServerUri("whois://whois.ripe.net"))
        assertEquals("whois.ripe.net", cleanWhoisServerUri("whois.ripe.net"))
        assertEquals("whois.ripe.net", cleanWhoisServerUri("whois://whois.ripe.net:43"))
        assertEquals("whois.ripe.net", cleanWhoisServerUri("whois://whois.ripe.net/path"))
    }

    @Test
    fun testExtractReferralServer() {
        val response1 = """
            % IANA WHOIS server
            % for more information on IANA, visit http://www.iana.org

            refer:        whois.apnic.net
        """.trimIndent()
        assertEquals("whois.apnic.net", extractReferralServer(response1))

        val response2 = """
            Domain Name: GOOGLE.COM
            Registry Domain ID: 2138514_DOMAIN_COM-VRSN
            Registrar WHOIS Server: whois.markmonitor.com
            Registrar URL: http://www.markmonitor.com
            whois: whois.verisign-grs.com
        """.trimIndent()
        assertEquals("whois.verisign-grs.com", extractReferralServer(response2))

        val response3 = """
            NetRange:       8.8.8.0 - 8.8.8.255
            CIDR:           8.8.8.0/24
            NetName:        LVLT-GOGL-8-8-8
            ReferralServer:  whois://whois.arin.net
        """.trimIndent()
        assertEquals("whois.arin.net", extractReferralServer(response3))

        val responseNone = """
            No referral info here.
        """.trimIndent()
        assertNull(extractReferralServer(responseNone))
    }

    @Test
    fun testSerializeDnsQuery() {
        val query = serializeDnsQuery("google.com", 1) // A record

        // Check transaction ID (0x1234)
        assertEquals(0x12.toByte(), query[0])
        assertEquals(0x34.toByte(), query[1])

        // Flags: 0x0100
        assertEquals(0x01.toByte(), query[2])
        assertEquals(0x00.toByte(), query[3])

        // Questions count: 1
        assertEquals(0x00.toByte(), query[4])
        assertEquals(0x01.toByte(), query[5])

        // Label sizes
        // "google.com" -> 6google3com0
        // Find index of first label len
        assertEquals(6.toByte(), query[12])
        assertEquals('g'.code.toByte(), query[13])
        assertEquals('e'.code.toByte(), query[18])
        assertEquals(3.toByte(), query[19])
        assertEquals('c'.code.toByte(), query[20])
        assertEquals('m'.code.toByte(), query[22])
        assertEquals(0.toByte(), query[23])

        // Type: 1
        assertEquals(0x00.toByte(), query[24])
        assertEquals(0x01.toByte(), query[25])

        // Class: 1
        assertEquals(0x00.toByte(), query[26])
        assertEquals(0x01.toByte(), query[27])
    }

    @Test
    fun testReadNameBasic() {
        val nameBytes = byteArrayOf(
            6, 'g'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'g'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0
        )
        val (name, nextIdx) = readName(nameBytes, 0)
        assertEquals("google.com", name)
        assertEquals(12, nextIdx)
    }

    @Test
    fun testReadNameWithCompression() {
        // Construct a response packet manually
        // Header: 12 bytes
        // Question: google.com (12 bytes) + Type/Class (4 bytes) -> offset 28 is after question
        // Answer: Name is pointer to offset 12 (0xC00C)
        val response = ByteArray(40)

        // Set up google.com at offset 12 (first question)
        val nameBytes = byteArrayOf(
            6, 'g'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'g'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0
        )
        System.arraycopy(nameBytes, 0, response, 12, nameBytes.size)

        // Set up pointer 0xC00C at offset 28
        response[28] = 0xC0.toByte()
        response[29] = 12.toByte()

        val (name, nextIdx) = readName(response, 28)
        assertEquals("google.com", name)
        assertEquals(30, nextIdx)
    }

    @Test
    fun testParseDnsResponseA() {
        // A full DNS response mock for a query of google.com (A)
        // Questions count = 1, Answers count = 1
        val response = ByteArray(128)

        // Header
        response[0] = 0x12.toByte()
        response[1] = 0x34.toByte()
        response[2] = 0x81.toByte() // flags
        response[3] = 0x80.toByte()
        response[4] = 0x00.toByte() // qdcount
        response[5] = 0x01.toByte()
        response[6] = 0x00.toByte() // ancount
        response[7] = 0x01.toByte()

        // Question name "google.com" at index 12
        val nameBytes = byteArrayOf(
            6, 'g'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'g'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0
        )
        System.arraycopy(nameBytes, 0, response, 12, nameBytes.size)

        // Question Type (A = 1) and Class (IN = 1) at index 24
        response[24] = 0.toByte()
        response[25] = 1.toByte()
        response[26] = 0.toByte()
        response[27] = 1.toByte()

        // Answer starts at index 28
        // Pointer to name at index 12 (0xC00C)
        response[28] = 0xC0.toByte()
        response[29] = 12.toByte()

        // Type A (1), Class IN (1)
        response[30] = 0.toByte()
        response[31] = 1.toByte()
        response[32] = 0.toByte()
        response[33] = 1.toByte()

        // TTL (300 seconds)
        response[34] = 0.toByte()
        response[35] = 0.toByte()
        response[36] = 0x01.toByte()
        response[37] = 0x2C.toByte()

        // RDLength (4)
        response[38] = 0.toByte()
        response[39] = 4.toByte()

        // IP Address: 8.8.8.8
        response[40] = 8.toByte()
        response[41] = 8.toByte()
        response[42] = 8.toByte()
        response[43] = 8.toByte()

        val records = parseDnsResponse(response, 44)
        assertEquals(1, records.size)
        assertEquals("google.com", records[0].name)
        assertEquals("A", records[0].type)
        assertEquals(300L, records[0].ttl)
        assertEquals("8.8.8.8", records[0].value)
    }

    @Test
    fun testParseDnsResponseMX() {
        val response = ByteArray(128)

        // Header
        response[4] = 0.toByte() // qdcount = 1
        response[5] = 1.toByte()
        response[6] = 0.toByte() // ancount = 1
        response[7] = 1.toByte()

        // Question name "google.com" at index 12
        val nameBytes = byteArrayOf(
            6, 'g'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'g'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0
        )
        System.arraycopy(nameBytes, 0, response, 12, nameBytes.size)

        // Type MX (15), Class IN (1)
        response[24] = 0.toByte()
        response[25] = 15.toByte()
        response[26] = 0.toByte()
        response[27] = 1.toByte()

        // Answer at index 28: Pointer to name at index 12
        response[28] = 0xC0.toByte()
        response[29] = 12.toByte()

        // Type MX (15), Class IN (1)
        response[30] = 0.toByte()
        response[31] = 15.toByte()
        response[32] = 0.toByte()
        response[33] = 1.toByte()

        // TTL
        response[37] = 60.toByte()

        // RDLength (9) -> 2 bytes preference + "mail" label + google.com pointer
        response[38] = 0.toByte()
        response[39] = 9.toByte()

        // Preference: 10
        response[40] = 0.toByte()
        response[41] = 10.toByte()

        // Exchange name literal: "mail" (4) "google" (6) "com" (3) -> 12 bytes
        val mxExchangeBytes = byteArrayOf(
            4, 'm'.code.toByte(), 'a'.code.toByte(), 'i'.code.toByte(), 'l'.code.toByte(),
            0xC0.toByte(), 12.toByte() // pointer to google.com
        )
        System.arraycopy(mxExchangeBytes, 0, response, 42, mxExchangeBytes.size)

        val records = parseDnsResponse(response, 42 + mxExchangeBytes.size)
        assertEquals(1, records.size)
        assertEquals("google.com", records[0].name)
        assertEquals("MX", records[0].type)
        assertEquals("10 mail.google.com", records[0].value)
    }

    @Test
    fun testParseDnsResponseTXT() {
        val response = ByteArray(128)

        // Header
        response[5] = 1.toByte() // qdcount = 1
        response[7] = 1.toByte() // ancount = 1

        // Question name "google.com" at index 12
        val nameBytes = byteArrayOf(
            6, 'g'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'g'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0
        )
        System.arraycopy(nameBytes, 0, response, 12, nameBytes.size)

        // Answer at index 28
        response[28] = 0xC0.toByte()
        response[29] = 12.toByte()

        // Type TXT (16), Class IN (1)
        response[30] = 0.toByte()
        response[31] = 16.toByte()
        response[32] = 0.toByte()
        response[33] = 1.toByte()

        // TTL
        response[37] = 100.toByte()

        val txtVal = "v=spf1 -all"

        // RDLength: text length byte + text bytes
        response[38] = 0.toByte()
        response[39] = (txtVal.length + 1).toByte()

        // Text: length-prefixed "v=spf1 -all"
        response[40] = txtVal.length.toByte()
        System.arraycopy(txtVal.toByteArray(), 0, response, 41, txtVal.length)

        val records = parseDnsResponse(response, 41 + txtVal.length)
        assertEquals(1, records.size)
        assertEquals("google.com", records[0].name)
        assertEquals("TXT", records[0].type)
        assertEquals("v=spf1 -all", records[0].value)
    }

    // ── TTL-stepped ping traceroute hop parsing ──

    @Test
    fun testTracerouteHopTtlExceededNoColon() {
        // iputils/toybox print "From <ip> icmp_seq=…" (no colon) when there's no reverse DNS.
        val out = """
            PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
            From 103.57.86.5 icmp_seq=1 Time to live exceeded

            --- 8.8.8.8 ping statistics ---
            1 packets transmitted, 0 received, +1 errors, 100% packet loss, time 0ms
        """.trimIndent()
        val hop = parseTracerouteHop(3, out, 12.6)
        assertFalse(hop.reachedDestination)
        assertEquals(" 3  103.57.86.5  ~13 ms", hop.line)
    }

    @Test
    fun testTracerouteHopTtlExceededWithColon() {
        val out = "From 192.168.1.1: icmp_seq=1 Time to live exceeded"
        val hop = parseTracerouteHop(1, out, 2.4)
        assertFalse(hop.reachedDestination)
        assertEquals(" 1  192.168.1.1  ~2 ms", hop.line)
    }

    @Test
    fun testTracerouteHopEchoReply() {
        val out = """
            PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
            64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=26.4 ms
        """.trimIndent()
        val hop = parseTracerouteHop(12, out, 30.0)
        assertTrue(hop.reachedDestination)
        assertEquals("12  8.8.8.8  26.4 ms", hop.line)
    }

    @Test
    fun testTracerouteHopEchoReplyIpv6() {
        // The IPv6 address's own colons must stay in the capture; the delimiter colon must not.
        val out = "64 bytes from 2404:6800:4002:80e::200e: icmp_seq=1 ttl=118 time=30.9 ms"
        val hop = parseTracerouteHop(9, out, 33.0)
        assertTrue(hop.reachedDestination)
        assertEquals(" 9  2404:6800:4002:80e::200e  30.9 ms", hop.line)
    }

    @Test
    fun testTracerouteHopIpv6TtlExceeded() {
        val out = "From 2a00:1450:8000::1 icmp_seq=1 Time exceeded: Hop limit"
        val hop = parseTracerouteHop(4, out, 18.2)
        assertFalse(hop.reachedDestination)
        assertEquals(" 4  2a00:1450:8000::1  ~18 ms", hop.line)
    }

    @Test
    fun testTracerouteHopTimeout() {
        val out = """
            PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.

            --- 8.8.8.8 ping statistics ---
            1 packets transmitted, 0 received, 100% packet loss, time 0ms
        """.trimIndent()
        val hop = parseTracerouteHop(7, out, 2000.0)
        assertFalse(hop.reachedDestination)
        assertEquals(" 7  *", hop.line)
    }
}
