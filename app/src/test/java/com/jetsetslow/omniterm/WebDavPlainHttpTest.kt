package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.shares.WebDavFsClient
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.Base64
import kotlin.concurrent.thread

/**
 * A WebDAV share with "Use HTTPS" off talks plain HTTP (the share form warns that the password then
 * travels in clear text). The client used to refuse to exist with `https = false`, so a share the
 * user had deliberately set to HTTP could not be opened at all.
 */
class WebDavPlainHttpTest {

    @Test
    fun `a share with HTTPS off reaches the server over plain HTTP with its credentials`() {
        ServerSocket(0).use { server ->
            val request = StringBuilder()
            val responder = thread {
                server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        request.appendLine(line)
                    }
                    socket.getOutputStream().write(
                        "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(),
                    )
                }
            }

            val client = WebDavFsClient(
                host = "127.0.0.1",
                port = server.localPort,
                https = false,
                username = "alice",
                password = "pw",
                anonymous = false,
            )
            runBlocking { client.mkdir("/new") }
            responder.join(5_000)

            val lines = request.lines()
            // A plain-text request line could only have been read by a plain socket: TLS would
            // have opened with a binary ClientHello.
            assertEquals("MKCOL /new/ HTTP/1.1", lines.first())
            val basic = Base64.getEncoder().encodeToString("alice:pw".toByteArray())
            assertTrue(lines.any { it.equals("Authorization: Basic $basic", ignoreCase = true) })
        }
    }
}

/**
 * Cleartext is now permitted app-wide so a WebDAV share can be set to plain HTTP. The speed test
 * used to rely on the network policy to refuse an http:// URL; it must refuse it itself.
 */
class SpeedTestUrlTest {

    @Test
    fun `only an https URL with a host is accepted`() {
        assertEquals(null, com.jetsetslow.omniterm.ui.speedTestUrlError("https://speed.cloudflare.com/__down?bytes=1"))
        for (url in listOf("http://example.com/test.bin", "not a url", "ftp://example.com/x", "https:///nohost")) {
            assertEquals(url, "Enter a valid HTTPS download URL.", com.jetsetslow.omniterm.ui.speedTestUrlError(url))
        }
    }
}
