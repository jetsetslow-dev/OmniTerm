package com.jetsetslow.omniterm.data.mcp

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import java.util.Locale

/**
 * The MCP server's HTTP side: one POST to `/mcp` per connection, on the loopback address only.
 *
 * Every request must name a loopback host (so a web page that rebinds its own name to 127.0.0.1
 * is refused), must not come from a web page's origin, and must carry the bearer token. Only the
 * token's SHA-256 is kept; [tokenHash] returns null when there is no token, and then nothing gets
 * in. A body is read only after those checks, and only up to [MAX_BODY_BYTES].
 *
 * [onRefused] hears each request turned away for its token, host or origin, for the record of calls;
 * [onError], a connection that failed inside, for the log.
 */
class McpHttpServer(
    private val tokenHash: () -> String?,
    private val handler: suspend (body: String, headers: Map<String, String>) -> McpReply,
    private val onRefused: (status: Int) -> Unit = {},
    private val onError: (Throwable) -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val slots = Semaphore(MAX_CONNECTIONS)
    @Volatile private var socket: ServerSocket? = null

    /** The port it listens on, or null when it is stopped. */
    val port: Int? get() = socket?.takeUnless { it.isClosed }?.localPort

    /** Starts listening on 127.0.0.1:[port] (0 picks a free one) and returns the port. */
    fun start(port: Int): Int {
        socket?.takeUnless { it.isClosed }?.let { return it.localPort }
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(LOOPBACK, port), BACKLOG)
        socket = server
        Thread({ accept(server) }, "omniterm-mcp-accept").apply { isDaemon = true }.start()
        return server.localPort
    }

    fun stop() {
        runCatching { socket?.close() }
        socket = null
        scope.cancel()
    }

    private fun accept(server: ServerSocket) {
        while (!server.isClosed) {
            val client = try {
                server.accept()
            } catch (e: IOException) {
                if (server.isClosed) return else continue
            }
            if (!slots.tryAcquire()) {
                // Busy: say so at once rather than queue behind calls that may wait for approval.
                runCatching { client.use { write(it, 503, errorBody("Too many requests at once")) } }
                continue
            }
            scope.launch {
                try {
                    client.use { serve(it) }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    onError(e)
                } finally {
                    slots.release()
                }
            }
        }
    }

    private suspend fun serve(client: Socket) {
        client.soTimeout = READ_TIMEOUT_MS
        val input = client.getInputStream().buffered()
        val head = try {
            readHead(input)
        } catch (e: HttpError) {
            write(client, e.status, errorBody(e.message.orEmpty()))
            drain(client, input)
            return
        } catch (e: SocketException) {
            return
        }
        val reply = check(head) ?: try {
            handler(readBody(input, head.headers), head.headers)
        } catch (e: HttpError) {
            McpReply(e.status, errorBody(e.message.orEmpty()))
        }
        val extra = when (reply.status) {
            401 -> listOf("WWW-Authenticate: Bearer")
            405 -> listOf("Allow: POST")
            else -> emptyList()
        }
        if (reply.status in REFUSALS) onRefused(reply.status)
        write(client, reply.status, reply.body, extra)
        drain(client, input)
    }

    /**
     * Ends the reply, then reads what the client still sends: closing with a refused body unread
     * would reset the connection, and the client could lose the reply it was reading.
     */
    private fun drain(client: Socket, input: InputStream) {
        runCatching {
            client.shutdownOutput()
            client.soTimeout = DRAIN_TIMEOUT_MS
            val buffer = ByteArray(8 * 1024)
            var left = MAX_BODY_BYTES * 2L
            while (left > 0) {
                val n = input.read(buffer)
                if (n < 0) break
                left -= n
            }
        }
    }

    /** Why [head] is turned away before its body is read, or null when it may go on. */
    private fun check(head: Head): McpReply? {
        val host = head.headers["host"]
        if (host == null || hostName(host) !in LOOPBACK_NAMES) return McpReply(403, errorBody("Only 127.0.0.1 or localhost may be named in the Host header"))
        head.headers["origin"]?.let { origin ->
            if (!loopbackOrigin(origin)) return McpReply(403, errorBody("Requests from web pages are refused"))
        }
        if (head.path.substringBefore('?') != PATH) return McpReply(404, errorBody("Not found; the MCP endpoint is $PATH"))
        if (head.method != "POST") return McpReply(405, errorBody("Only POST is supported"))
        if (!authorised(head.headers["authorization"])) return McpReply(401, errorBody("A valid bearer token is required"))
        val type = head.headers["content-type"].orEmpty().substringBefore(';').trim().lowercase(Locale.ROOT)
        if (type != "application/json") return McpReply(415, errorBody("The body must be application/json"))
        return null
    }

    private fun authorised(header: String?): Boolean {
        val expected = tokenHash() ?: return false
        val token = header?.takeIf { it.regionMatches(0, "Bearer ", 0, 7, ignoreCase = true) }?.substring(7)?.trim()
            ?: return false
        val sent = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
        val want = expected.chunked(2).mapNotNull { it.toIntOrNull(16)?.toByte() }.toByteArray()
        return want.size == sent.size && MessageDigest.isEqual(sent, want)
    }

    private class Head(val method: String, val path: String, val headers: Map<String, String>)

    private class HttpError(val status: Int, message: String) : Exception(message)

    private fun readHead(input: InputStream): Head {
        val bytes = ByteArrayOutputStream()
        var matched = 0
        while (matched < 4) {
            val b = input.read()
            if (b < 0) throw SocketException("closed")
            bytes.write(b)
            if (bytes.size() > MAX_HEAD_BYTES) throw HttpError(431, "Request headers are too large")
            matched = when {
                b == '\r'.code && (matched == 0 || matched == 2) -> matched + 1
                b == '\n'.code && (matched == 1 || matched == 3) -> matched + 1
                b == '\r'.code -> 1
                else -> 0
            }
        }
        val lines = bytes.toString(Charsets.ISO_8859_1.name()).split("\r\n").dropLast(2)
        val request = lines.firstOrNull()?.split(' ').orEmpty()
        if (request.size != 3 || !request[2].startsWith("HTTP/1.")) throw HttpError(400, "Malformed request line")
        val headers = mutableMapOf<String, String>()
        lines.drop(1).forEach { line ->
            val colon = line.indexOf(':')
            if (colon <= 0) throw HttpError(400, "Malformed header")
            val name = line.substring(0, colon).trim().lowercase(Locale.ROOT)
            val value = line.substring(colon + 1).trim()
            if (name in SINGLE_HEADERS && name in headers) throw HttpError(400, "Repeated $name header")
            headers[name] = headers[name]?.let { "$it, $value" } ?: value
        }
        return Head(request[0], request[1], headers)
    }

    private fun readBody(input: InputStream, headers: Map<String, String>): String {
        val chunked = headers["transfer-encoding"]?.lowercase(Locale.ROOT)?.let {
            if (it != "chunked") throw HttpError(501, "Only chunked transfer encoding is supported")
            true
        } ?: false
        val bytes = if (chunked) readChunked(input) else {
            val length = headers["content-length"]?.toLongOrNull() ?: throw HttpError(411, "Content-Length is required")
            if (length < 0) throw HttpError(400, "Bad Content-Length")
            if (length > MAX_BODY_BYTES) throw HttpError(413, "The body is larger than ${MAX_BODY_BYTES / 1024} KiB")
            readExactly(input, length.toInt())
        }
        return bytes.toString(Charsets.UTF_8)
    }

    private fun readChunked(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        while (true) {
            val size = readLine(input).substringBefore(';').trim().toIntOrNull(16) ?: throw HttpError(400, "Bad chunk size")
            if (size < 0 || out.size() + size > MAX_BODY_BYTES) throw HttpError(413, "The body is larger than ${MAX_BODY_BYTES / 1024} KiB")
            if (size == 0) {
                while (readLine(input).isNotEmpty()) Unit // trailers
                return out.toByteArray()
            }
            out.write(readExactly(input, size))
            if (readLine(input).isNotEmpty()) throw HttpError(400, "Bad chunk")
        }
    }

    private fun readLine(input: InputStream): String {
        val line = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) throw HttpError(400, "The body ended early")
            if (b == '\n'.code) return line.toString().removeSuffix("\r")
            if (line.length > 256) throw HttpError(400, "Bad chunk")
            line.append(b.toChar())
        }
    }

    private fun readExactly(input: InputStream, length: Int): ByteArray {
        val bytes = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(bytes, read, length - read)
            if (n < 0) throw HttpError(400, "The body ended early")
            read += n
        }
        return bytes
    }

    private fun write(client: Socket, status: Int, body: String?, extra: List<String> = emptyList()) {
        val payload = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val head = buildString {
            append("HTTP/1.1 ").append(status).append(' ').append(REASONS[status] ?: "Error").append("\r\n")
            if (body != null) append("Content-Type: application/json\r\n")
            append("Content-Length: ").append(payload.size).append("\r\n")
            append("Cache-Control: no-store\r\n")
            append("Connection: close\r\n")
            extra.forEach { append(it).append("\r\n") }
            append("\r\n")
        }
        val out = client.getOutputStream()
        out.write(head.toByteArray(Charsets.ISO_8859_1))
        out.write(payload)
        out.flush()
    }

    private fun errorBody(message: String) =
        """{"jsonrpc":"2.0","id":null,"error":{"code":${Mcp.INVALID_REQUEST},"message":${JsonPrimitive(message)}}}"""

    companion object {
        const val PATH = "/mcp"
        const val MAX_BODY_BYTES = 256 * 1024
        const val MAX_HEAD_BYTES = 16 * 1024
        const val MAX_CONNECTIONS = 8
        private const val BACKLOG = 16
        private const val READ_TIMEOUT_MS = 15_000
        private const val DRAIN_TIMEOUT_MS = 1_000

        /**
         * 127.0.0.1 by number: Android's getLoopbackAddress() is ::1, where neither the SSH tunnel
         * nor a client naming 127.0.0.1 would find it.
         */
        internal val LOOPBACK: InetAddress = InetAddress.getByAddress("localhost", byteArrayOf(127, 0, 0, 1))

        private val LOOPBACK_NAMES = setOf("127.0.0.1", "localhost", "::1")
        private val SINGLE_HEADERS = setOf("host", "content-length", "authorization", "content-type", "transfer-encoding", "origin")
        private val REFUSALS = setOf(401, 403)
        private val REASONS = mapOf(
            200 to "OK", 202 to "Accepted", 400 to "Bad Request", 401 to "Unauthorized", 403 to "Forbidden",
            404 to "Not Found", 405 to "Method Not Allowed", 411 to "Length Required", 413 to "Content Too Large",
            415 to "Unsupported Media Type", 431 to "Request Header Fields Too Large", 501 to "Not Implemented",
            503 to "Service Unavailable",
        )

        /** The name in a Host header: `[::1]:8080` gives `::1`, `localhost:8080` gives `localhost`. */
        internal fun hostName(host: String): String {
            val h = host.trim().lowercase(Locale.ROOT)
            return if (h.startsWith("[")) h.substringAfter('[').substringBefore(']') else h.substringBefore(':')
        }

        /** Whether [origin] is a loopback address: a page served from anywhere else is refused. */
        internal fun loopbackOrigin(origin: String): Boolean {
            val o = origin.trim().lowercase(Locale.ROOT)
            val scheme = o.substringBefore("://", "")
            if (scheme != "http" && scheme != "https") return false
            val authority = o.substringAfter("://").substringBefore('/')
            if ('@' in authority) return false
            return hostName(authority) in LOOPBACK_NAMES
        }
    }
}
