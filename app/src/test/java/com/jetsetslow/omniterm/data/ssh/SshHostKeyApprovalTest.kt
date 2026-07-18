package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSch
import com.jcraft.jsch.HostKeyRepository
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class SshHostKeyApprovalTest {
    private fun request() = HostKeyApprovalRequest(
        host = "host.example:22",
        keyType = "ssh-ed25519",
        fingerprint = "SHA256:test",
        deferred = CompletableDeferred(),
    )

    @Test
    fun `approved request succeeds`() {
        val request = request()

        assertTrue(SshHostKeyTrust.awaitApproval({ it.deferred.complete(true) }, request, 1_000L))
    }

    @Test
    fun `handler failure rejects and completes request`() {
        val request = request()

        assertFalse(SshHostKeyTrust.awaitApproval({ error("UI unavailable") }, request, 1_000L))
        assertTrue(request.deferred.isCompleted)
        assertFalse(runBlocking { request.deferred.await() })
    }

    @Test
    fun `unanswered request times out fail closed`() {
        val request = request()

        assertFalse(SshHostKeyTrust.awaitApproval({}, request, 1L))
        assertTrue(request.deferred.isCompleted)
        assertFalse(runBlocking { request.deferred.await() })
    }

    @Test
    fun `non-positive timeout rejects without invoking handler`() {
        val request = request()
        var invoked = false

        assertFalse(SshHostKeyTrust.awaitApproval({ invoked = true }, request, 0L))
        assertFalse(invoked)
        assertTrue(request.deferred.isCompleted)
    }

    @Test
    fun `jump target host key uses stable logical identity instead of ephemeral forward`() {
        val session = JSch().getSession("user", "127.0.0.1", 49152)

        pinJumpTargetToLogicalHost(session, "target.example", 22)

        assertEquals("target.example", session.hostKeyAlias)
        assertEquals("[target.example]:2222", logicalHostKeyAlias("target.example", 2222))
        assertFalse(session.hostKeyAlias.contains("127.0.0.1"))
        assertFalse(session.hostKeyAlias.contains("49152"))
    }

    @Test
    fun `concurrent approved first pins cannot replace each other`() {
        val stored = AtomicReference<String?>(null)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val results = listOf("key-a", "key-b").map { candidate ->
                executor.submit<Int> {
                    start.await()
                    SshHostKeyTrust.persistApprovedFirstPin(
                        encoded = candidate,
                        readCurrent = stored::get,
                        write = { stored.set(it); true },
                    )
                }
            }
            start.countDown()

            assertEquals(
                setOf(HostKeyRepository.OK, HostKeyRepository.CHANGED),
                results.map { it.get(2, TimeUnit.SECONDS) }.toSet(),
            )
            assertTrue(stored.get() == "key-a" || stored.get() == "key-b")
        } finally {
            executor.shutdownNow()
        }
    }
}
