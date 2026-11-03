package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSchException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Addresses here are documentation ranges (RFC 5737 and 3849): nothing is dialled but the loopback listener. */
class EveryAddressSocketFactoryTest {
    private val v6 = InetAddress.getByName("2001:db8::1")
    private val dead = InetAddress.getByName("192.0.2.1")
    private val loopback = InetAddress.getLoopbackAddress()

    @Test
    fun aHostWhoseFirstAddressNeverAnswersConnectsOnTheNext() {
        ServerSocket(0, 1, loopback).use { server ->
            val tried = mutableListOf<Pair<InetAddress, Int>>()
            val factory = EveryAddressSocketFactory(
                timeoutMs = 15_000,
                resolve = { arrayOf(v6, loopback) },
                dial = { socket, address, timeout ->
                    tried += address.address to timeout
                    if (address.address == v6) throw SocketTimeoutException("connect timed out")
                    socket.connect(address, timeout)
                },
            )
            factory.createSocket("dual.example", server.localPort).use { socket ->
                assertTrue(socket.isConnected)
                assertEquals(loopback, socket.inetAddress)
            }
            assertEquals(listOf(v6, loopback), tried.map { it.first })
            // The first of two addresses may use half the time, so the second still has the rest.
            assertTrue("the first address's share: ${tried[0].second}", tried[0].second in 7_000..7_500)
        }
    }

    @Test
    fun whenNoAddressAnswersTheTimeIsSharedAndTheErrorReadsAsJSchsOwn() {
        val shares = mutableListOf<Int>()
        var clock = 0L
        val factory = EveryAddressSocketFactory(
            timeoutMs = 9_000,
            resolve = { arrayOf(v6, dead, dead) },
            // Each attempt waits out its share before it times out, as a real one does.
            dial = { _, _, timeout ->
                shares += timeout
                clock += timeout * 1_000_000L
                throw SocketTimeoutException("connect timed out")
            },
            nanoTime = { clock },
        )
        val failure = assertThrows(JSchException::class.java) { factory.createSocket("down.example", 22) }
        assertEquals("timeout: socket is not established", failure.message)
        assertEquals(listOf(3_000, 3_000, 3_000), shares)
    }

    @Test
    fun aRefusalIsReportedAsTheExceptionAndAnUnknownHostAsOne() {
        val refused = EveryAddressSocketFactory(
            resolve = { arrayOf(dead) },
            dial = { _, _, _ -> throw ConnectException("Connection refused") },
        )
        val failure = assertThrows(JSchException::class.java) { refused.createSocket("refusing.example", 22) }
        assertEquals("java.net.ConnectException: Connection refused", failure.message)

        val unknown = EveryAddressSocketFactory(resolve = { throw UnknownHostException("nowhere.invalid") })
        val notFound = assertThrows(JSchException::class.java) { unknown.createSocket("nowhere.invalid", 22) }
        // The app reads "UnknownHost" in the message as a name that does not resolve.
        assertTrue(notFound.message!!, notFound.message!!.contains("UnknownHost"))
        assertTrue(notFound.cause is UnknownHostException)
    }

    @Test
    fun everySessionDialsThroughIt() {
        val session = buildJschSession(
            SshCredentials(host = "fixture.invalid", port = 22, username = "fixture"),
            hostKeys = com.jcraft.jsch.JSch().hostKeyRepository,
        )
        val factory = com.jcraft.jsch.Session::class.java.getDeclaredField("socket_factory")
            .apply { isAccessible = true }.get(session)
        assertTrue("socket factory: $factory", factory is EveryAddressSocketFactory)
        assertFalse(session.isConnected)
    }
}
