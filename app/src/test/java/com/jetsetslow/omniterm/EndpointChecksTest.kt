package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.EndpointChecks
import com.sun.net.httpserver.HttpServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket

class EndpointChecksTest {
    @Test
    fun aTlsTargetMayBeAHostAHostAndPortAnIpv6AddressOrAUrl() {
        assertEquals("nas.lan" to 443, EndpointChecks.tlsEndpoint("", "nas.lan"))
        assertEquals("example.com" to 443, EndpointChecks.tlsEndpoint("example.com", "nas.lan"))
        assertEquals("example.com" to 8443, EndpointChecks.tlsEndpoint("example.com:8443", "nas.lan"))
        assertEquals("2001:db8::1" to 443, EndpointChecks.tlsEndpoint("2001:db8::1", "nas.lan"))
        assertEquals("2001:db8::1" to 9443, EndpointChecks.tlsEndpoint("[2001:db8::1]:9443", "nas.lan"))
        assertEquals("example.com" to 443, EndpointChecks.tlsEndpoint("https://example.com/status", "nas.lan"))
        assertEquals("example.com" to 8443, EndpointChecks.tlsEndpoint("https://example.com:8443/", "nas.lan"))
        assertNull(EndpointChecks.tlsEndpoint("example.com:http", "nas.lan"))
        assertNull(EndpointChecks.tlsEndpoint("[2001:db8::1", "nas.lan"))
        assertNull(EndpointChecks.tlsEndpoint("two words", "nas.lan"))
    }

    @Test
    fun aUrlCheckAddsHttpsAndTakesOnlyWebAddresses() {
        assertEquals("https://example.com/health", EndpointChecks.checkUrl("example.com/health"))
        assertEquals("http://10.0.0.5:8080/", EndpointChecks.checkUrl(" http://10.0.0.5:8080/ "))
        assertNull(EndpointChecks.checkUrl(""))
        assertNull(EndpointChecks.checkUrl("ftp://example.com"))
        assertNull(EndpointChecks.checkUrl("https://"))
    }

    @Test
    fun tlsBreachesAtOrBelowItsDaysAndUrlOnFailureOrSlowness() {
        val tls = AlertRuleEntity(serverId = 1, metricName = EndpointChecks.TLS_EXPIRY, thresholdValue = 14f, severity = "WARNING")
        assertFalse(EndpointChecks.breached(tls, 30f))
        assertTrue(EndpointChecks.breached(tls, 14f))
        assertTrue(EndpointChecks.breached(tls, -2f))
        val url = AlertRuleEntity(serverId = 1, metricName = EndpointChecks.URL_CHECK, thresholdValue = 2000f, severity = "WARNING")
        assertFalse(EndpointChecks.breached(url, 300f))
        assertTrue(EndpointChecks.breached(url, 2500f))
        assertTrue(EndpointChecks.breached(url, -503f))
        assertTrue(EndpointChecks.breached(url, EndpointChecks.URL_NO_RESPONSE))
    }

    @Test
    fun readingsAreSaidInWords() {
        val day = 24L * 60 * 60 * 1000
        assertEquals(41.5f, EndpointChecks.daysLeft(notAfter = 83 * day, now = 41 * day + day / 2), 0.001f)
        assertEquals("41 days left", EndpointChecks.describe(EndpointChecks.TLS_EXPIRY, 41.5f))
        assertEquals("1 day left", EndpointChecks.describe(EndpointChecks.TLS_EXPIRY, 1.2f))
        assertEquals("less than a day left", EndpointChecks.describe(EndpointChecks.TLS_EXPIRY, 0.3f))
        assertEquals("expired 3 days ago", EndpointChecks.describe(EndpointChecks.TLS_EXPIRY, -3.4f))
        assertEquals("320 ms", EndpointChecks.describe(EndpointChecks.URL_CHECK, 320.4f))
        assertEquals("HTTP 503", EndpointChecks.describe(EndpointChecks.URL_CHECK, -503f))
        assertEquals("no response", EndpointChecks.describe(EndpointChecks.URL_CHECK, EndpointChecks.URL_NO_RESPONSE))
    }

    @Test
    fun aFetchReportsTheResponseTimeAnHttpErrorOrNoResponse() {
        val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.createContext("/ok") { it.sendResponseHeaders(200, -1); it.close() }
        server.createContext("/moved") { it.responseHeaders.add("Location", "/ok"); it.sendResponseHeaders(302, -1); it.close() }
        server.createContext("/down") { it.sendResponseHeaders(503, -1); it.close() }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            val (ok, okProblem) = EndpointChecks.fetch("$base/ok", 5_000)
            assertTrue("a response time, not a failure: $ok", ok >= 0f)
            assertNull(okProblem)
            assertTrue(EndpointChecks.fetch("$base/moved", 5_000).first >= 0f)
            assertEquals(-503f, EndpointChecks.fetch("$base/down", 5_000).first)
        } finally {
            server.stop(0)
        }
        // A port nothing listens on: free one, then close it.
        val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        assertEquals(EndpointChecks.URL_NO_RESPONSE, EndpointChecks.fetch("http://127.0.0.1:$closedPort/", 5_000).first)
    }
}
