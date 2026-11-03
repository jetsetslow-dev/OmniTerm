package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.DO
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.IAC
import com.jetsetslow.omniterm.data.telnet.TelnetCodec.Companion.WILL
import com.jetsetslow.omniterm.data.telnet.TelnetSession
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.fold
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket

/** A Telnet session against a server on this machine's loopback, which it runs itself. */
class TelnetSessionTest {
    @Test
    fun aSessionNegotiatesShowsTheHostsTextSendsInputAndEndsWhenTheHostHangsUp() = runBlocking {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val fromClient = ByteArrayOutputStream()
            val host = Thread {
                server.accept().use { socket ->
                    val out = socket.getOutputStream()
                    out.write(byteArrayOf(IAC, DO, 31, IAC, WILL, 1) + "login: ".toByteArray())
                    out.flush()
                    val input = socket.getInputStream()
                    val buffer = ByteArray(256)
                    // Read until the typed line arrives, then hang up.
                    while (!String(fromClient.toByteArray(), Charsets.ISO_8859_1).contains("root\r\u0000")) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        fromClient.write(buffer, 0, read)
                    }
                }
            }.apply { start() }

            val session = TelnetSession.open("127.0.0.1", server.localPort, cols = 80, rows = 24)
            val shown = StringBuilder()
            withTimeout(5_000) {
                session.output.first { chunk -> shown.append(String(chunk)); shown.contains("login: ") }
            }
            session.write("root\r".toByteArray())
            withTimeout(5_000) {
                session.output.fold(Unit) { _, chunk -> shown.append(String(chunk)) }
            }
            host.join(5_000)

            assertEquals("login: ", shown.toString())
            val sent = fromClient.toByteArray()
            assertTrue("agreed to report its size", sent.toList().windowed(3).contains(listOf(IAC, WILL, 31.toByte())))
            assertTrue("agreed the host echoes", sent.toList().windowed(3).contains(listOf(IAC, DO, 1.toByte())))
            assertTrue(session.remoteExited.value)
            assertEquals("Connection closed by the host", session.endedBecause)
        }
    }
}
