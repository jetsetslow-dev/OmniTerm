package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Session
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

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
    private val keepAliveIntervalMs: Int = 30_000,
) {
    private val sessions = ConcurrentHashMap<String, Session>()
    private val locks = ConcurrentHashMap<String, Mutex>()

    private fun key(c: SshCredentials): String =
        "${c.username}@${c.host}:${c.port}" +
            "|pw=${fingerprint(c.password)}|pk=${fingerprint(c.privateKeyPem)}|pp=${fingerprint(c.passphrase)}" +
            "|proxy=${c.proxyType}:${c.proxyUser}@${c.proxyHost}:${c.proxyPort}:${fingerprint(c.proxyPassword)}"

    private fun fingerprint(secret: String?): String {
        if (secret.isNullOrEmpty()) return "empty"
        val digest = MessageDigest.getInstance("SHA-256").digest(secret.toByteArray(Charsets.UTF_8))
        return digest.take(12).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /** Return a connected session for [creds], reusing a live cached one or building a new one. */
    suspend fun acquire(creds: SshCredentials): Session {
        val k = key(creds)
        // Per-key lock so two concurrent callers for the same host don't both open a session.
        val lock = locks.getOrPut(k) { Mutex() }
        return lock.withLock {
            sessions[k]?.takeIf { it.isConnected }
                ?: buildJschSession(creds).also { s ->
                    sessions.remove(k)?.let { stale -> runCatching { stale.disconnect() } }
                    s.connect(connectTimeoutMs)
                    runCatching { s.serverAliveInterval = keepAliveIntervalMs }
                    sessions[k] = s
                }
        }
    }

    /** Drop the cached session for [creds] (e.g. after a transport error) so the next call reconnects. */
    fun evict(creds: SshCredentials) {
        sessions.remove(key(creds))?.let { runCatching { it.disconnect() } }
    }

    /** Disconnect and forget every pooled session. */
    fun closeAll() {
        sessions.values.forEach { runCatching { it.disconnect() } }
        sessions.clear()
    }
}
