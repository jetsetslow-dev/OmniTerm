package com.jetsetslow.omniterm

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.Session
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.data.ssh.JumpedSession
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.buildJschSession
import com.jetsetslow.omniterm.data.ssh.buildJumpedJschSession
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SshCommandCancellationTest {
    private val creds = SshCredentials(host = "fixture.invalid", port = 22, username = "fixture")

    @Before
    fun mockFactory() {
        mockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt")
    }

    @After
    fun restoreFactory() {
        unmockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt")
    }

    private fun session(): Session = mockk<Session>(relaxed = true).also {
        every { it.isConnected } returns true
        every { buildJschSession(creds) } returns it
    }

    private fun channel(output: String, closed: Boolean): ChannelExec = mockk<ChannelExec>(relaxed = true).also {
        every { it.inputStream } returns output.byteInputStream()
        every { it.errStream } returns "".byteInputStream()
        every { it.isClosed } returns closed
        every { it.exitStatus } returns 0
    }

    @Test(timeout = 30_000)
    fun stoppingAnOpenStreamKeepsTheHealthyPooledConnection() = runBlocking {
        val session = session()
        val stream = channel("ready\n", false)
        val following = channel("followup-ok", true)
        every { session.openChannel("exec") } returnsMany listOf(stream, following)
        val transport = JschSshTransport()
        val ready = CompletableDeferred<Unit>()
        val job = launch {
            transport.execStream(creds, "fixture-stream", null) {
                ready.complete(Unit)
                awaitCancellation()
            }
        }
        try {
            withTimeout(5_000) { ready.await() }
            withTimeout(5_000) { job.cancelAndJoin() }
            assertEquals("followup-ok", transport.exec(creds, "fixture-followup"))
            verify(exactly = 1) { stream.disconnect() }
            verify(exactly = 1) { buildJschSession(creds) }
            verify(exactly = 0) { session.disconnect() }
        } finally {
            job.cancelAndJoin()
            transport.shutdown()
        }
    }

    @Test(timeout = 30_000)
    fun cancellationDuringBlockingConnectNeverOpensAnExecChannel() = runBlocking {
        for (streaming in listOf(false, true)) {
            val session = session()
            val entered = CompletableDeferred<Unit>()
            val release = CountDownLatch(1)
            every { session.connect(any<Int>()) } answers {
                entered.complete(Unit)
                check(release.await(5, TimeUnit.SECONDS)) { "fixture connection was not released" }
            }
            every { session.openChannel("exec") } returns channel("must-not-run", true)
            val transport = JschSshTransport()
            val job = launch {
                if (streaming) transport.execStream(creds, "must-not-run", null) {}
                else transport.exec(creds, "must-not-run")
            }
            try {
                withTimeout(5_000) { entered.await() }
                job.cancel()
                release.countDown()
                withTimeout(5_000) { job.join() }
                verify(exactly = 0) { session.openChannel("exec") }
            } finally {
                release.countDown()
                job.cancelAndJoin()
                transport.shutdown()
            }
        }
    }

    @Test(timeout = 30_000)
    fun failedJumpTargetAuthenticationClosesBothOwnedSessions() = runBlocking {
        val target = mockk<Session>(relaxed = true)
        val bastion = mockk<Session>(relaxed = true)
        val jumpedCreds = creds.copy(proxyType = "ssh", proxyHost = "bastion.invalid", proxyPort = 22)
        every { buildJumpedJschSession(jumpedCreds, any()) } returns JumpedSession(target, bastion)
        every { target.connect(any<Int>()) } throws IllegalStateException("fixture auth rejected")
        val transport = JschSshTransport()
        try {
            val result = transport.execStream(jumpedCreds, "must-not-run", null) {}
            assertTrue(result.contains("fixture auth rejected"))
            verify(exactly = 1) { target.disconnect() }
            verify(exactly = 1) { bastion.disconnect() }
        } finally {
            transport.shutdown()
        }
    }
}
