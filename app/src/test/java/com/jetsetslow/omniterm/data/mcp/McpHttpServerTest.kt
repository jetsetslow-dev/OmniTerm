package com.jetsetslow.omniterm.data.mcp

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.net.Socket
import java.security.MessageDigest

/** The MCP server's HTTP side over a real loopback socket: what gets in, and what is turned away. */
class McpHttpServerTest {
    private val token = "omt_good-token-0123456789ab"
    @Volatile private var hash: String? = sha256(token)
    private val bodies = mutableListOf<String>()
    private val refused = mutableListOf<Int>()
    private lateinit var server: McpHttpServer
    private var port = 0

    @Before
    fun start() {
        server = McpHttpServer(
            tokenHash = { hash },
            handler = { body, headers ->
                synchronized(bodies) { bodies += body }
                McpReply(200, """{"ok":true,"ua":"${headers["user-agent"].orEmpty()}"}""")
            },
            onRefused = { synchronized(refused) { refused += it } },
        )
        port = server.start(0)
    }

    @After
    fun stop() = server.stop()

    private data class Answer(val status: Int, val headers: Map<String, String>, val body: String)

    private fun request(
        method: String = "POST",
        path: String = "/mcp",
        headers: Map<String, String> = good(),
        body: String? = """{"jsonrpc":"2.0","id":1,"method":"ping"}""",
        raw: ByteArray? = null,
    ): Answer {
        Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 10_000
            val out = socket.getOutputStream()
            if (raw != null) out.write(raw) else {
                val payload = body?.toByteArray(Charsets.UTF_8)
                val head = buildString {
                    append("$method $path HTTP/1.1\r\n")
                    headers.forEach { (k, v) -> append("$k: $v\r\n") }
                    if (payload != null && headers.keys.none { it.equals("transfer-encoding", true) || it.equals("content-length", true) }) {
                        append("Content-Length: ${payload.size}\r\n")
                    }
                    append("\r\n")
                }
                out.write(head.toByteArray(Charsets.ISO_8859_1))
                if (payload != null) out.write(payload)
            }
            out.flush()
            val text = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
            val (head, rest) = text.split("\r\n\r\n", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            val lines = head.split("\r\n")
            val status = lines.first().split(' ')[1].toInt()
            val hs = lines.drop(1).associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
            return Answer(status, hs, rest)
        }
    }

    private fun good() = mapOf(
        "Host" to "127.0.0.1:$port",
        "Authorization" to "Bearer $token",
        "Content-Type" to "application/json",
        "Accept" to "application/json, text/event-stream",
        "User-Agent" to "test-agent",
    )

    @Test
    fun itListensOnLoopbackOnly() {
        // The address it bound is the loopback one: nothing on the network can reach it.
        val field = McpHttpServer::class.java.getDeclaredField("socket").apply { isAccessible = true }
        val socket = field.get(server) as java.net.ServerSocket
        assertThat(socket.inetAddress.isLoopbackAddress).isTrue()
        assertWithMessage("127.0.0.1 itself, which the tunnel and clients name; never ::1 alone")
            .that(socket.inetAddress.hostAddress).isEqualTo("127.0.0.1")
    }

    @Test
    fun anAuthorisedPostReachesTheHandler() {
        val answer = request()
        assertThat(answer.status).isEqualTo(200)
        assertThat(answer.headers["content-type"]).isEqualTo("application/json")
        assertThat(answer.headers["cache-control"]).isEqualTo("no-store")
        assertThat(answer.body).isEqualTo("""{"ok":true,"ua":"test-agent"}""")
        assertThat(bodies).containsExactly("""{"jsonrpc":"2.0","id":1,"method":"ping"}""")
        assertThat(request(headers = good() + ("Host" to "localhost:9")).status).isEqualTo(200)
        assertThat(request(headers = good() + ("Host" to "[::1]:9")).status).isEqualTo(200)
        assertThat(request(headers = good() + ("Origin" to "http://127.0.0.1:3000")).status).isEqualTo(200)
        assertThat(request(headers = good() + ("Content-Type" to "application/json; charset=utf-8")).status).isEqualTo(200)
        assertThat(request(headers = good() + ("Authorization" to "bearer $token")).status).isEqualTo(200)
    }

    @Test
    fun aMissingOrWrongTokenIsRefusedBeforeTheBodyIsRead() {
        listOf(
            good() - "Authorization",
            good() + ("Authorization" to "Bearer omt_wrong-token-0123456789"),
            good() + ("Authorization" to "Basic $token"),
            good() + ("Authorization" to "Bearer "),
        ).forEach { headers ->
            val answer = request(headers = headers)
            assertWithMessage(headers["Authorization"].orEmpty()).that(answer.status).isEqualTo(401)
            assertThat(answer.headers["www-authenticate"]).isEqualTo("Bearer")
        }
        assertThat(bodies).isEmpty()
        assertThat(refused.toSet()).containsExactly(401)
    }

    @Test
    fun aRevokedTokenLetsNothingIn() {
        hash = null
        assertThat(request().status).isEqualTo(401)
        assertThat(bodies).isEmpty()
    }

    @Test
    fun aWebPageOrARebindingNameIsRefused() {
        listOf(
            good() - "Host",
            good() + ("Host" to "evil.example:$port"),
            good() + ("Host" to "127.0.0.1.evil.example"),
            good() + ("Host" to "192.168.1.5:$port"),
        ).forEach { headers ->
            assertWithMessage(headers["Host"].orEmpty()).that(request(headers = headers).status).isEqualTo(403)
        }
        listOf("https://evil.example", "null", "http://localhost.evil.example", "http://user@127.0.0.1", "file://", "chrome-extension://abc").forEach { origin ->
            assertWithMessage(origin).that(request(headers = good() + ("Origin" to origin)).status).isEqualTo(403)
        }
        assertThat(bodies).isEmpty()
        assertThat(refused.toSet()).containsExactly(403)
    }

    @Test
    fun onlyPostToTheEndpointIsServed() {
        val get = request(method = "GET", body = null)
        assertWithMessage("a GET gets 405, not an empty stream (electerm#4431)").that(get.status).isEqualTo(405)
        assertThat(get.headers["allow"]).isEqualTo("POST")
        assertThat(get.body).contains("\"jsonrpc\"")
        assertThat(request(method = "DELETE", body = null).status).isEqualTo(405)
        assertThat(request(method = "OPTIONS", body = null).status).isEqualTo(405)
        assertThat(request(path = "/").status).isEqualTo(404)
        assertThat(request(path = "/mcp/../etc").status).isEqualTo(404)
        assertThat(bodies).isEmpty()
    }

    @Test
    fun badBodiesAreRefused() {
        assertThat(request(headers = good() + ("Content-Type" to "text/plain")).status).isEqualTo(415)
        assertThat(request(headers = good() - "Content-Type").status).isEqualTo(415)
        val big = "x".repeat(McpHttpServer.MAX_BODY_BYTES + 1)
        assertThat(request(body = big).status).isEqualTo(413)
        val noLength = buildString {
            append("POST /mcp HTTP/1.1\r\n")
            good().forEach { (k, v) -> append("$k: $v\r\n") }
            append("\r\n")
        }
        assertThat(request(raw = noLength.toByteArray()).status).isEqualTo(411)
        val twice = buildString {
            append("POST /mcp HTTP/1.1\r\n")
            (good() - "Host").forEach { (k, v) -> append("$k: $v\r\n") }
            append("Host: 127.0.0.1\r\nHost: evil.example\r\nContent-Length: 2\r\n\r\n{}")
        }
        assertWithMessage("two Host headers cannot smuggle a second name").that(request(raw = twice.toByteArray()).status).isEqualTo(400)
        assertThat(request(raw = "GARBAGE\r\n\r\n".toByteArray()).status).isEqualTo(400)
        val huge = "POST /mcp HTTP/1.1\r\nX: ${"y".repeat(McpHttpServer.MAX_HEAD_BYTES)}\r\n\r\n"
        assertThat(request(raw = huge.toByteArray()).status).isEqualTo(431)
        assertThat(request(headers = good() + ("Transfer-Encoding" to "gzip")).status).isEqualTo(501)
        assertThat(bodies).isEmpty()
    }

    @Test
    fun aChunkedBodyIsJoined() {
        val head = buildString {
            append("POST /mcp HTTP/1.1\r\n")
            good().forEach { (k, v) -> append("$k: $v\r\n") }
            append("Transfer-Encoding: chunked\r\n\r\n")
            append("5\r\n{\"a\":\r\n3;ext=1\r\n12}\r\n0\r\nTrailer: x\r\n\r\n")
        }
        assertThat(request(raw = head.toByteArray()).status).isEqualTo(200)
        assertThat(bodies).containsExactly("""{"a":12}""")
    }

    @Test
    fun aNotificationGetsAnEmptyAccepted() {
        server.stop()
        server = McpHttpServer(tokenHash = { hash }, handler = { _, _ -> McpReply(202, null) })
        port = server.start(0)
        val answer = request()
        assertThat(answer.status).isEqualTo(202)
        assertThat(answer.headers["content-length"]).isEqualTo("0")
        assertThat(answer.headers).doesNotContainKey("content-type")
    }

    @Test
    fun hostAndOriginParsing() {
        assertThat(McpHttpServer.hostName("[::1]:8080")).isEqualTo("::1")
        assertThat(McpHttpServer.hostName("LocalHost:1")).isEqualTo("localhost")
        assertThat(McpHttpServer.loopbackOrigin("http://localhost")).isTrue()
        assertThat(McpHttpServer.loopbackOrigin("https://[::1]:5")).isTrue()
        assertThat(McpHttpServer.loopbackOrigin("ws://127.0.0.1")).isFalse()
    }

    private companion object {
        fun sha256(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
