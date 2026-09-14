package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSch
import io.mockk.every
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Real loopback IO, not virtual coroutine time or mocked JSch. No Android runtime is required. */
class SshSetupTimeoutTest {
    @Before
    fun inMemoryTrustStore() {
        // Only replace Android-backed storage. JSch still performs real IO, and its default
        // empty repository fails closed if a peer unexpectedly presents a host key.
        mockkObject(SshHostKeyTrust)
        every { SshHostKeyTrust.repository() } returns JSch().hostKeyRepository
    }

    @After
    fun restoreTrustStore() {
        unmockkObject(SshHostKeyTrust)
    }

    @Test(timeout = 25_000)
    fun silentTargetIsBoundedAndItsSocketIsReleased() = assertSilentPeerIsBounded(false)

    @Test(timeout = 25_000)
    fun silentBastionIsBoundedAndItsSocketIsReleased() = assertSilentPeerIsBounded(true)

    private fun assertSilentPeerIsBounded(bastion: Boolean) {
        val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val reader = Executors.newSingleThreadExecutor()
        val accepted = AtomicReference<Socket?>()
        val peerClosed = reader.submit<Boolean> {
            listener.accept().use { peer ->
                accepted.set(peer)
                peer.soTimeout = 20_000
                // Drain the client's banner, but never send one back. TCP connects immediately;
                // only the SSH setup deadline can end this wait and release the owned socket.
                val buffer = ByteArray(1024)
                while (peer.getInputStream().read(buffer) >= 0) {
                    // Consume only; deliberately withhold the server banner.
                }
                true
            }
        }
        val transport = JschSshTransport()
        try {
            val credentials = SshCredentials(
                host = "127.0.0.1",
                port = listener.localPort,
                username = "repository-fixture",
                proxyType = if (bastion) "ssh" else "none",
                proxyHost = "127.0.0.1",
                proxyPort = listener.localPort,
                proxyUser = "repository-fixture",
            )
            runBlocking {
                try {
                    transport.openShell(credentials, 80, 24).close()
                    fail("A silent fixture cannot authenticate")
                } catch (expected: SshConnectException) {
                    assertTrue(
                        "Expected a setup timeout, got: ${expected.message}",
                        expected.message.orEmpty().contains("timed out", ignoreCase = true),
                    )
                }
            }
            assertTrue("Timed-out setup must close the socket", peerClosed.get(2, TimeUnit.SECONDS))
        } finally {
            transport.shutdown()
            listener.close()
            accepted.get()?.close()
            reader.shutdownNow()
            assertTrue("Fixture reader must stop", reader.awaitTermination(2, TimeUnit.SECONDS))
        }
    }
}
