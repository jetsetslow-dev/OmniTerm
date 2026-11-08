package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertForwarding
import com.jetsetslow.omniterm.data.AlertForwarding.Config
import com.sun.net.httpserver.HttpServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** What alert forwarding sends to ntfy, Gotify and a webhook, and how a delivery is judged. */
class AlertForwardingTest {
    private val event = AlertForwarding.Event(
        resolved = false, severity = "CRITICAL", host = "nas", rule = "Disk Usage",
        title = "CRITICAL: nas", text = "Disk Usage on /tank at 97% (threshold 90%)",
        value = 97f, threshold = 90f, timeMs = 1_762_646_400_000L,
    )

    @Test
    fun aConfigNeedsWhatItsServiceNeeds() {
        assertNull("off needs nothing", AlertForwarding.configError(Config()))
        assertNull(AlertForwarding.configError(Config(AlertForwarding.KIND_NTFY, topic = "homelab-alerts_7")))
        assertNotNull("a topic is required", AlertForwarding.configError(Config(AlertForwarding.KIND_NTFY)))
        assertNotNull("no spaces or slashes", AlertForwarding.configError(Config(AlertForwarding.KIND_NTFY, topic = "my/alerts")))
        assertNotNull(AlertForwarding.configError(Config(AlertForwarding.KIND_GOTIFY, url = "https://gotify.lan")))
        assertNull(AlertForwarding.configError(Config(AlertForwarding.KIND_GOTIFY, url = "https://gotify.lan", token = "Axyz")))
        assertNotNull(AlertForwarding.configError(Config(AlertForwarding.KIND_WEBHOOK)))
        assertNotNull(AlertForwarding.configError(Config(AlertForwarding.KIND_WEBHOOK, url = "ftp://example.com/x")))
        assertNull(AlertForwarding.configError(Config(AlertForwarding.KIND_WEBHOOK, url = "http://192.168.1.5:8080/hook")))
        assertTrue(AlertForwarding.isCleartext(Config(AlertForwarding.KIND_WEBHOOK, url = "http://192.168.1.5:8080/hook")))
        assertFalse(AlertForwarding.isCleartext(Config(AlertForwarding.KIND_NTFY, topic = "t")))
    }

    @Test
    fun ntfyGetsAJsonPublishToTheServerRoot() {
        val r = AlertForwarding.request(Config(AlertForwarding.KIND_NTFY, topic = "homelab", token = "tk_1"), event)!!
        assertEquals("https://ntfy.sh/", r.url)
        assertEquals(mapOf("Authorization" to "Bearer tk_1"), r.headers)
        assertEquals(
            """{"topic":"homelab","title":"CRITICAL: nas","message":"Disk Usage on /tank at 97% (threshold 90%)","priority":5,"tags":["rotating_light"]}""",
            r.body,
        )
        val own = AlertForwarding.request(Config(AlertForwarding.KIND_NTFY, url = "https://ntfy.lan/", topic = "t"), event.copy(severity = "WARNING"))!!
        assertEquals("https://ntfy.lan/", own.url)
        assertTrue("no token, no header", own.headers.isEmpty())
        assertTrue(own.body, own.body.contains(""""priority":4,"tags":["warning"]"""))
    }

    @Test
    fun gotifyAndAWebhookGetTheirOwnShapes() {
        val g = AlertForwarding.request(Config(AlertForwarding.KIND_GOTIFY, url = "https://gotify.lan/", token = "Axyz"), event)!!
        assertEquals("https://gotify.lan/message", g.url)
        assertEquals(mapOf("X-Gotify-Key" to "Axyz"), g.headers)
        assertEquals("""{"title":"CRITICAL: nas","message":"Disk Usage on /tank at 97% (threshold 90%)","priority":8}""", g.body)

        val w = AlertForwarding.request(Config(AlertForwarding.KIND_WEBHOOK, url = "https://example.com/hook?x=1"), event.copy(resolved = true, title = "Resolved: nas"))!!
        assertEquals("https://example.com/hook?x=1", w.url)
        assertEquals(
            """{"source":"OmniTerm","event":"resolved","severity":"CRITICAL","host":"nas","rule":"Disk Usage","title":"Resolved: nas",""" +
                """"message":"Disk Usage on /tank at 97% (threshold 90%)","value":97.0,"threshold":90.0,"time":"2025-11-09T00:00:00Z"}""",
            w.body,
        )
        assertNull(
            "resolved alerts are skipped when the user turned them off",
            AlertForwarding.request(Config(AlertForwarding.KIND_WEBHOOK, url = "https://example.com/hook", includeResolved = false), event.copy(resolved = true)),
        )
        assertNull("off sends nothing", AlertForwarding.request(Config(), event))
    }

    @Test
    fun textIsQuotedSoAHostNameCannotBreakTheJson() {
        assertEquals(""""a\"b\\c\nd\te\u0001f\u2028 ü"""", AlertForwarding.quote("a\"b\\c\nd\te\u0001f\u2028 ü"))
    }

    @Test
    fun aDeliveryIsJudgedByTheAnswerAndARedirectIsNeverFollowed() {
        val received = LinkedBlockingQueue<Triple<String, String?, String>>()
        val elsewhere = LinkedBlockingQueue<String>()
        val server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        val other = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        other.createContext("/") { ex -> elsewhere.add(ex.requestURI.path); ex.sendResponseHeaders(200, -1); ex.close() }
        server.createContext("/") { ex ->
            val body = ex.requestBody.readBytes().toString(Charsets.UTF_8)
            received.add(Triple(ex.requestURI.path, ex.requestHeaders.getFirst("Authorization"), body))
            when (ex.requestURI.path) {
                "/ok" -> ex.sendResponseHeaders(200, -1)
                "/denied" -> ex.sendResponseHeaders(401, -1)
                "/busy" -> ex.sendResponseHeaders(503, -1)
                else -> {
                    ex.responseHeaders.add("Location", "http://127.0.0.1:${other.address.port}/stolen")
                    ex.sendResponseHeaders(302, -1)
                }
            }
            ex.close()
        }
        server.start(); other.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            fun deliver(path: String) = AlertForwarding.send(
                AlertForwarding.request(Config(AlertForwarding.KIND_WEBHOOK, url = base + path, token = "secret"), event)!!,
                timeoutMs = 3_000,
            )

            val ok = deliver("/ok")
            assertTrue(ok.detail, ok.ok)
            val (path, auth, body) = received.poll(5, TimeUnit.SECONDS)!!
            assertEquals("/ok", path)
            assertEquals("Bearer secret", auth)
            assertTrue(body, body.contains(""""event":"triggered""""))

            val denied = deliver("/denied")
            assertFalse(denied.ok)
            assertEquals(401, denied.status)
            assertFalse("a refusal is not retried", AlertForwarding.isRetryable(denied))
            assertTrue("a server error is", AlertForwarding.isRetryable(deliver("/busy")))

            val moved = deliver("/moved")
            assertFalse(moved.ok)
            assertTrue(moved.detail, moved.detail.contains("/stolen"))
            assertFalse(AlertForwarding.isRetryable(moved))
            assertNull("the token never went to the other address", elsewhere.poll(500, TimeUnit.MILLISECONDS))

            val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
            val nobody = AlertForwarding.send(
                AlertForwarding.request(Config(AlertForwarding.KIND_WEBHOOK, url = "http://127.0.0.1:$closedPort/x"), event)!!,
                timeoutMs = 3_000,
            )
            assertFalse(nobody.ok)
            assertNull(nobody.status)
            assertTrue("no answer is retried", AlertForwarding.isRetryable(nobody))
        } finally {
            server.stop(0); other.stop(0)
        }
    }
}
