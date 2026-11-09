package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.EndpointChecks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/** Ping, TCP Port and DNS checks the phone runs itself, against stand-ins on this machine. */
class PhoneChecksTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun targetsNameAHostAPortOrANameAndServer() {
        assertEquals("nas.lan" to 22, EndpointChecks.tcpEndpoint("22", "nas.lan"))
        assertEquals("db.lan" to 5432, EndpointChecks.tcpEndpoint("db.lan:5432", "nas.lan"))
        assertEquals("fd00::5" to 8006, EndpointChecks.tcpEndpoint("[fd00::5]:8006", "nas.lan"))
        assertNull("a TCP check needs a port", EndpointChecks.tcpEndpoint("db.lan", "nas.lan"))
        assertNull(EndpointChecks.tcpEndpoint("70000", "nas.lan"))

        assertEquals(Triple("example.com", "pihole.lan", 53), EndpointChecks.dnsTarget("example.com", "pihole.lan"))
        assertEquals(Triple("nas.lan", "192.168.1.1", 53), EndpointChecks.dnsTarget("nas.lan@192.168.1.1", "pihole.lan"))
        assertEquals(Triple("nas.lan", "10.0.0.2", 5353), EndpointChecks.dnsTarget("nas.lan.@10.0.0.2:5353", "x"))
        assertEquals("xn--bcher-kva.example", EndpointChecks.dnsTarget("bücher.example", "x")?.first)
        assertNull(EndpointChecks.dnsTarget("two words", "x"))
        assertNull(EndpointChecks.dnsTarget("a..b", "x"))

        assertEquals("192.168.1.10", EndpointChecks.pingHost(" 192.168.1.10 "))
        assertEquals("fe80::1%wlan0", EndpointChecks.pingHost("fe80::1%wlan0"))
        assertEquals("brackets are for URLs, not ping", "fd00::5", EndpointChecks.pingHost("[fd00::5]"))
        assertNull("never an option", EndpointChecks.pingHost("-f"))
        assertNull("never an option", EndpointChecks.pingHost("[-s65000]"))
        assertNull(EndpointChecks.pingHost("nas lan"))
        assertNull(EndpointChecks.pingHost("nas;reboot"))

        // The TLS target keeps its meaning after the shared parser moved underneath it.
        assertEquals("nas.lan" to 443, EndpointChecks.tlsEndpoint("", "nas.lan"))
        assertEquals("example.com" to 8443, EndpointChecks.tlsEndpoint("https://example.com:8443/x", "nas.lan"))
    }

    @Test
    fun aTcpCheckTimesTheConnectAndFailsOnAClosedPort() {
        val open = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        open.use {
            val (ms, problem) = EndpointChecks.connect("127.0.0.1", open.localPort, 3_000)
            assertTrue(ms >= 0f)
            assertNull(problem)
        }
        val (failed, why) = EndpointChecks.connect("127.0.0.1", closedPort, 3_000)
        assertEquals(EndpointChecks.URL_NO_RESPONSE, failed)
        assertTrue(why.orEmpty().isNotBlank())
        assertEquals("not accepting connections", EndpointChecks.describe(EndpointChecks.TCP_PORT, failed))
    }

    @Test
    fun aDnsCheckReadsTheAnswerTheRcodeOrNothing() {
        // A stand-in server: answers A for "up.test", NXDOMAIN for "gone.test", nothing for "lost.test",
        // and NOERROR without records for "empty.test". For "spoof.test" it first sends an NXDOMAIN
        // under another query id, as a stray or forged packet would, then the real answer.
        val server = DatagramSocket(0, InetAddress.getLoopbackAddress())
        val worker = thread(isDaemon = true) {
            val buf = ByteArray(512)
            while (!server.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                runCatching { server.receive(p) }.getOrElse { return@thread }
                val q = buf.copyOf(p.length)
                val name = questionName(q)
                if (name == "lost.test") continue
                if (name == "spoof.test") {
                    val forged = q.copyOf()
                    forged[1] = (q[1] + 1).toByte()
                    forged[2] = 0x81.toByte(); forged[3] = 0x83.toByte()
                    server.send(DatagramPacket(forged, forged.size, p.address, p.port))
                }
                val reply = q.copyOf()
                reply[2] = (0x80 or (q[2].toInt() and 0x01)).toByte() // a response, RD echoed
                reply[3] = when (name) { "gone.test" -> 0x83; else -> 0x80 }.toByte() // RA, rcode
                val answers = if (name in setOf("up.test", "spoof.test") && q[q.size - 3].toInt() == 1) 1 else 0
                reply[7] = answers.toByte()
                val out = if (answers == 1) {
                    reply + byteArrayOf(0xc0.toByte(), 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1)
                } else reply
                server.send(DatagramPacket(out, out.size, p.address, p.port))
            }
        }
        try {
            val port = server.localPort
            val (ok, okWhy) = EndpointChecks.dnsLookup("up.test", "127.0.0.1", port, 2_000)
            assertTrue("answered in ms", ok >= 0f); assertNull(okWhy)
            val (gone, _) = EndpointChecks.dnsLookup("gone.test", "127.0.0.1", port, 2_000)
            assertEquals(-103f, gone)
            assertEquals("no such name (NXDOMAIN)", EndpointChecks.describe(EndpointChecks.DNS_CHECK, gone))
            assertEquals(EndpointChecks.DNS_NO_ADDRESS, EndpointChecks.dnsLookup("empty.test", "127.0.0.1", port, 2_000).first)
            assertEquals(EndpointChecks.URL_NO_RESPONSE, EndpointChecks.dnsLookup("lost.test", "127.0.0.1", port, 500).first)
            val (real, _) = EndpointChecks.dnsLookup("spoof.test", "127.0.0.1", port, 2_000)
            assertTrue("the reply to this query, not the forged one", real >= 0f)
        } finally {
            server.close()
            worker.join(2_000)
        }
    }

    @Test
    fun aPingReadsTheReplyTimeFromThePlatformBinary() {
        assumeTrue("needs a POSIX shell", File("/bin/sh").canExecute())
        fun stub(name: String, body: String) = File(tmp.root, name).apply {
            writeText("#!/bin/sh\n$body\n"); setExecutable(true)
        }
        val replying = stub("ping-ok", "echo 'PING nas (10.0.0.5) 56(84) bytes of data.'; echo '64 bytes from 10.0.0.5: icmp_seq=1 ttl=64 time=0.42 ms'; exit 0")
        val silent = stub("ping-lost", "echo 'PING nas (10.0.0.5) 56(84) bytes of data.'; exit 1")
        val unknown = stub("ping-unknown", "echo 'ping: nas.invalid: Name or service not known'; exit 2")
        val args = stub("ping-args", "echo \"\$@\" > \"${tmp.root}/args\"; exit 1")

        assertEquals(0.42f to null, EndpointChecks.ping("nas", 3_000, replying.path))
        assertEquals(EndpointChecks.URL_NO_RESPONSE to null, EndpointChecks.ping("nas", 3_000, silent.path))
        assertEquals(EndpointChecks.URL_NO_RESPONSE to "nas.invalid: Name or service not known", EndpointChecks.ping("nas.invalid", 3_000, unknown.path))
        assertEquals("0.4 ms", EndpointChecks.describe(EndpointChecks.PING, 0.42f))
        assertEquals("no reply", EndpointChecks.describe(EndpointChecks.PING, -1f))

        EndpointChecks.ping("nas", 3_000, args.path)
        assertEquals("one try, a whole-second wait, the host last", "-c 1 -W 3 nas", File(tmp.root, "args").readText().trim())
        EndpointChecks.ping("[fd00::5]", 2_500, args.path)
        assertEquals("-c 1 -W 3 fd00::5", File(tmp.root, "args").readText().trim())
        assertEquals("an option is never passed", EndpointChecks.URL_NO_RESPONSE, EndpointChecks.ping("-f", 3_000, replying.path).first)

        // One process, as ping is, that outlives its limit: the watchdog ends it.
        val hanging = stub("ping-hang", "exec sleep 60")
        val started = System.nanoTime()
        assertEquals(EndpointChecks.URL_NO_RESPONSE to "timed out", EndpointChecks.ping("nas", 500, hanging.path))
        assertTrue("stopped near its limit, not after the minute", (System.nanoTime() - started) / 1_000_000 < 15_000)
    }

    @Test
    fun timedChecksBreachOnFailureOrASlowReply() {
        val rule = AlertRuleEntity(serverId = 1, metricName = EndpointChecks.PING, thresholdValue = 200f, severity = "WARNING", triggerWindow = "5m")
        assertTrue(EndpointChecks.breached(rule, -1f))
        assertTrue(EndpointChecks.breached(rule, 250f))
        assertFalse(EndpointChecks.breached(rule, 12f))
        assertEquals(EndpointChecks.QUICK_TIMEOUT_MS, EndpointChecks.timeoutMs(EndpointChecks.DNS_CHECK))
        assertEquals(EndpointChecks.URL_TIMEOUT_MS, EndpointChecks.timeoutMs(EndpointChecks.URL_CHECK))
        assertNull(EndpointChecks.timeoutMs(EndpointChecks.TLS_EXPIRY))
        assertEquals("Ping nas failed: no reply", EndpointChecks.alertText(rule, "nas", -1f))
        assertEquals("Ping nas answered in 250 ms (threshold 200 ms)", EndpointChecks.alertText(rule, "nas", 250f))
        assertTrue(listOf(EndpointChecks.PING, EndpointChecks.TCP_PORT, EndpointChecks.DNS_CHECK).all(EndpointChecks::isEndpointMetric))
    }

    private fun questionName(q: ByteArray): String {
        val labels = mutableListOf<String>()
        var i = 12
        while (i < q.size && q[i].toInt() != 0) {
            val n = q[i].toInt(); labels += String(q, i + 1, n, Charsets.US_ASCII); i += n + 1
        }
        return labels.joinToString(".")
    }
}
