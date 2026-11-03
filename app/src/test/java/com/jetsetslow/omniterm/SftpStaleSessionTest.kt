package com.jetsetslow.omniterm

import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jetsetslow.omniterm.data.ssh.JschSftp
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.buildJschSession
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.util.Vector

/**
 * A pooled SFTP connection whose network went away without a word (a NAT that forgot it) still
 * says it is connected, and its channels never open. Every listing waited out the channel timeout
 * on it and failed, until keepalive gave up on it, or forever with keepalive off.
 */
class SftpStaleSessionTest {
    private val creds = SshCredentials(host = "stale.invalid", port = 22, username = "fixture", keepAliveSeconds = 0)

    @Before
    fun mockFactory() {
        mockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt")
    }

    @After
    fun restoreFactory() {
        JschSftp.shutdownPool()
        unmockkStatic("com.jetsetslow.omniterm.data.ssh.JschSessionKt")
    }

    private fun session(vararg channels: ChannelSftp): Session = mockk<Session>(relaxed = true).also {
        every { it.isConnected } returns true
        every { it.openChannel("sftp") } returnsMany channels.toList()
    }

    private fun lists(): ChannelSftp = mockk<ChannelSftp>(relaxed = true).also {
        every { it.ls(any<String>()) } returns Vector<ChannelSftp.LsEntry>()
    }

    private fun neverOpens(): ChannelSftp = mockk<ChannelSftp>(relaxed = true).also {
        every { it.connect(any()) } throws JSchException("channel is not opened.")
    }

    @Test(timeout = 30_000)
    fun aReusedConnectionThatCannotOpenAChannelIsReplaced() = runBlocking {
        val goneQuiet = neverOpens()
        val first = session(lists(), goneQuiet)
        val replacement = lists()
        val second = session(replacement)
        every { buildJschSession(creds, null) } returnsMany listOf(first, second)
        val sftp = JschSftp(creds)

        sftp.list("/srv")
        assertEquals(emptyList<Any>(), sftp.list("/srv"))

        verify(exactly = 2) { buildJschSession(creds, null) }
        // The reused connection got the short wait; the new one the usual.
        verify { goneQuiet.connect(5_000) }
        verify { replacement.connect(15_000) }
        verify { goneQuiet.disconnect() }
        verify { first.disconnect() }
    }

    @Test(timeout = 30_000)
    fun aNewConnectionThatCannotOpenAChannelIsTheServersAnswer() = runBlocking {
        val refused = neverOpens()
        val only = session(refused)
        every { buildJschSession(creds, null) } returns only
        val sftp = JschSftp(creds)

        assertThrows(JSchException::class.java) { runBlocking { sftp.list("/srv") } }
        // Not signed in again: on a host with two-step sign-in that would ask for another code.
        verify(exactly = 1) { buildJschSession(creds, null) }
        verify { refused.disconnect() }
    }

    @Test(timeout = 30_000)
    fun aNewConnectionThatDropsDuringChannelOpenDoesNotAskForAnotherCode() = runBlocking {
        val refused = neverOpens()
        val only = session(refused)
        every { refused.connect(any()) } answers {
            every { only.isConnected } returns false
            throw JSchException("connection dropped during SFTP startup")
        }
        every { buildJschSession(creds, null) } returns only

        assertThrows(JSchException::class.java) { runBlocking { JschSftp(creds).list("/srv") } }
        verify(exactly = 1) { buildJschSession(creds, null) }
        verify { refused.disconnect() }
    }
}
