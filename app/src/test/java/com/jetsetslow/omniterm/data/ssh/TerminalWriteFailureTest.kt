package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.Session
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Exercise the actual terminal adapter and its IO dispatcher, without a virtual-time test. */
class TerminalWriteFailureTest {
    private val credentials = SshCredentials("fixture.invalid", 22, "fixture")

    @Before fun mockSessionFactory() { mockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt") }
    @After fun restoreSessionFactory() { unmockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt") }

    @Test(timeout = 15_000)
    fun failedStreamWriteReportsItsFailureAndClosesTheShell() = runBlocking {
        val failure = IOException("fixture write failure")
        withShell(object : OutputStream() {
            override fun write(value: Int) { throw failure }
        }) { shell ->
            val actual = runCatching { shell.write(byteArrayOf(65)) }.exceptionOrNull()
            assertFailurePreserved("A failed wire write must not return as accepted", failure, actual)
            assertTrue(shell.closed.value)
        }
    }

    @Test(timeout = 15_000)
    fun failedFlushReportsUncertainDeliveryAndClosesTheShell() = runBlocking {
        val failure = IOException("fixture flush failure")
        val written = ByteArrayOutputStream()
        withShell(object : OutputStream() {
            override fun write(value: Int) { written.write(value) }
            override fun flush() { throw failure }
        }) { shell ->
            val actual = runCatching { shell.write(byteArrayOf(65, 66)) }.exceptionOrNull()
            assertArrayEquals(byteArrayOf(65, 66), written.toByteArray())
            assertFailurePreserved("A partially delivered write must expose its failure", failure, actual)
            assertTrue(shell.closed.value)
        }
    }

    @Test(timeout = 15_000)
    fun closedShellRejectsInputInsteadOfClaimingAcceptance() = runBlocking {
        val written = ByteArrayOutputStream()
        withShell(written) { shell ->
            shell.close()
            val actual = runCatching { shell.write(byteArrayOf(65)) }.exceptionOrNull()
            assertTrue("A closed shell cannot accept bytes", actual is IOException)
            assertArrayEquals(byteArrayOf(), written.toByteArray())
        }
    }

    @Test(timeout = 15_000)
    fun cancellationIsPropagatedAndTheOwnedShellIsClosed() = runBlocking {
        val failure = CancellationException("fixture cancelled write")
        withShell(object : OutputStream() {
            override fun write(value: Int) { throw failure }
        }) { shell ->
            val actual = runCatching { shell.write(byteArrayOf(65)) }.exceptionOrNull()
            assertFailurePreserved("Cancellation must not be swallowed as a successful write", failure, actual)
            assertTrue(shell.closed.value)
        }
    }

    @Test(timeout = 15_000)
    fun completedWriteRemainsAcceptedAfterChannelClosure() = runBlocking {
        val written = ByteArrayOutputStream()
        withShell(written) { shell ->
            shell.write(byteArrayOf(65, 66))
            shell.close()
            assertArrayEquals(byteArrayOf(65, 66), written.toByteArray())
            assertTrue(shell.closed.value)
        }
    }

    private fun assertFailurePreserved(label: String, original: Throwable, actual: Throwable?) {
        assertNotNull(label, actual)
        requireNotNull(actual)
        assertEquals(label, original.javaClass, actual.javaClass)
        assertEquals(label, original.message, actual.message)
        // Coroutine stack recovery may copy the error while retaining it as the cause. Require
        // the actual stream/cancellation failure to survive, rather than identity of that copy.
        assertTrue(label, generateSequence(actual) { it.cause }.take(8).any { it === original })
    }

    private suspend fun withShell(output: OutputStream, exercise: suspend (TerminalSession) -> Unit) {
        val releaseReader = CountDownLatch(1)
        val readerStopped = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read(): Int {
                try {
                    check(releaseReader.await(10, TimeUnit.SECONDS)) { "Fixture reader was not released" }
                    return -1
                } finally {
                    readerStopped.countDown()
                }
            }
        }
        val session = mockk<Session>(relaxed = true)
        val channel = mockk<ChannelShell>(relaxed = true)
        every { buildJschSession(credentials) } returns session
        every { session.openChannel("shell") } returns channel
        every { session.isConnected } returns true
        every { channel.inputStream } returns input
        every { channel.outputStream } returns output
        every { channel.exitStatus } returns -1
        every { channel.isEOF } returns false
        every { channel.disconnect() } answers { releaseReader.countDown() }
        val transport = JschSshTransport()
        val shell = transport.openShell(credentials, 80, 24)
        try {
            exercise(shell)
        } finally {
            shell.close()
            releaseReader.countDown()
            assertTrue("The owned fixture reader must stop", readerStopped.await(2, TimeUnit.SECONDS))
            transport.shutdown()
        }
    }
}
