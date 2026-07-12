package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Session
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Caches one connected JSch [Session] per (host, port, user, credential) key so repeated one-shot
 * commands reuse a single authenticated connection — and open lightweight per-command exec
 * channels on it — instead of re-running the full SSH handshake on every call.
 *
 * Why this matters: the telemetry poller fans out to every host on a 15s timer, and the Monitor
 * tabs add their own loops. Without pooling, each cycle re-authenticated to every host (expensive
 * RSA/ed25519 auth, battery drain, and a fast way to trip `MaxStartups`/fail2ban). With pooling we
 * authenticate once per host and keep the session warm with SSH keepalives.
 *
 * A session that has dropped is detected via [Session.isConnected] and transparently rebuilt.
 * Interactive shells are deliberately NOT pooled — they own their own session lifecycle (see
 * JschTerminalSession), and tearing a shell down must not kill a session shared with exec calls.
 */
internal class SshSessionPool(
    private val connectTimeoutMs: Int,
) {
    private class Entry(val session: Session, val generation: Long) {
        val leases = AtomicInteger(0)
        val retired = AtomicBoolean(false)
    }

    internal class Lease internal constructor(
        val session: Session,
        private val releaseAction: () -> Unit,
    ) : AutoCloseable {
        private val released = AtomicBoolean(false)
        override fun close() {
            if (released.compareAndSet(false, true)) releaseAction()
        }
    }

    private val sessions = ConcurrentHashMap<String, Entry>()
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val lifecycleGeneration = AtomicLong(0)

    private fun key(c: SshCredentials): String =
        "${c.username}@${c.host}:${c.port}" +
            "|pw=${fingerprint(c.password)}|pk=${fingerprint(c.privateKeyPem)}|pp=${fingerprint(c.passphrase)}" +
            "|proxy=${c.proxyType}:${c.proxyUser}@${c.proxyHost}:${c.proxyPort}:${fingerprint(c.proxyPassword)}" +
            ":${fingerprint(c.proxyKeyPem)}|ka=${c.keepAliveSeconds}|z=${c.compression}"

    private fun fingerprint(secret: String?): String {
        if (secret.isNullOrEmpty()) return "empty"
        val digest = MessageDigest.getInstance("SHA-256").digest(secret.toByteArray(Charsets.UTF_8))
        return digest.take(12).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /** Return a connected session for [creds], reusing a live cached one or building a new one. */
    suspend fun acquire(creds: SshCredentials): Lease {
        val k = key(creds)
        val expectedGeneration = lifecycleGeneration.get()
        // Per-key lock so two concurrent callers for the same host don't both open a session.
        val lock = locks.getOrPut(k) { Mutex() }
        return lock.withLock {
            val entry = sessions[k]?.takeIf {
                it.generation == expectedGeneration && !it.retired.get() && it.session.isConnected
            } ?: run {
                sessions.remove(k)?.let(::retire)
                val s = buildJschSession(creds)
                try {
                    s.connect(connectTimeoutMs)
                    val fresh = Entry(s, expectedGeneration)
                    sessions[k] = fresh
                    fresh
                } catch (e: Throwable) {
                    runCatching { s.disconnect() }
                    throw e
                }
            }
            // Take the lease before revalidating. If closeAll races just before this increment it
            // marks the entry retired and may disconnect it; the checks below reject it. If
            // closeAll races after the increment it sees an outstanding lease and defers the
            // disconnect until this caller finishes.
            entry.leases.incrementAndGet()
            if (entry.retired.get() || lifecycleGeneration.get() != expectedGeneration || !entry.session.isConnected) {
                sessions.remove(k, entry)
                retire(entry)
                release(entry)
                error("SSH session pool was reset while acquiring a session")
            }
            Lease(entry.session) { release(entry) }
        }
    }

    /**
     * Retire the cached session for [creds]. Existing channels retain a lease and may finish; the
     * underlying SSH connection is disconnected only after the final lease closes. Supplying
     * [suspect] prevents a late failure from evicting a newer replacement session.
     */
    fun evict(creds: SshCredentials, suspect: Session? = null) {
        val k = key(creds)
        while (true) {
            val entry = sessions[k] ?: return
            if (suspect != null && entry.session !== suspect) return
            if (sessions.remove(k, entry)) {
                retire(entry)
                return
            }
        }
    }

    /** Disconnect and forget every pooled session. */
    fun closeAll() {
        val resetGeneration = lifecycleGeneration.incrementAndGet()
        // Never call clear(): an acquire that starts after the generation bump may legitimately
        // publish a post-reset entry while this method is scanning. Removing only entries from an
        // older generation guarantees every removed session is retired/disconnected. An acquire
        // that started before the bump but publishes late fails its generation recheck and retires
        // its own entry.
        sessions.entries.forEach { (key, entry) ->
            if (entryPredatesReset(entry.generation, resetGeneration) && sessions.remove(key, entry)) {
                retire(entry)
            }
        }
        // Do not clear per-key mutexes: a waiter may still hold a reference to one. Replacing it
        // here would allow a concurrent post-reset caller to use a second lock for the same key.
    }

    private fun release(entry: Entry) {
        val remaining = entry.leases.decrementAndGet()
        check(remaining >= 0) { "SSH session lease released more than once" }
        if (remaining == 0 && entry.retired.get()) runCatching { entry.session.disconnect() }
    }

    private fun retire(entry: Entry) {
        entry.retired.set(true)
        if (entry.leases.get() == 0) runCatching { entry.session.disconnect() }
    }
}

internal fun entryPredatesReset(entryGeneration: Long, resetGeneration: Long): Boolean =
    entryGeneration < resetGeneration
