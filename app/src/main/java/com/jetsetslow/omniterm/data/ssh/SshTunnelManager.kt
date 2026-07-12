package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Monotonic stop/start ownership for one tunnel id. [publishIfCurrent] deliberately validates on
 * both sides of [publish]: a stop that lands in the tiny check-to-publication window is detected
 * and rolled back instead of leaving a tunnel alive after stop() returned.
 */
internal class TunnelGeneration {
    private val value = AtomicLong(0)

    fun snapshot(): Long = value.get()
    fun invalidate(): Long = value.incrementAndGet()

    fun publishIfCurrent(
        expected: Long,
        publish: () -> Unit,
        rollback: () -> Unit,
    ): Boolean {
        if (value.get() != expected) return false
        publish()
        if (value.get() == expected) return true
        rollback()
        return false
    }
}

/**
 * Owns the live JSch sessions that back user-defined port-forwarding tunnels (`ssh -L / -R / -D`).
 *
 * Each active tunnel keeps its own dedicated, un-pooled [Session] open for as long as the tunnel is
 * up — a pooled session would be reclaimed while idle and silently drop the forward. The session is
 * built with the same [buildJschSession] / [buildJumpedJschSession] factories as shells, so proxies,
 * jump hosts, and key/password auth all work identically.
 *
 * This is a JSch-typed class and therefore lives below the [SshTransport] boundary; the ViewModel
 * drives it only through [start]/[stop]/[isActive], which take/return pure Kotlin.
 */
object SshTunnelManager {
    private const val CONNECT_TIMEOUT_MS = 15_000

    /** One running tunnel: its session (+ optional jump wrapper) and the actual bound local port. */
    private class ActiveTunnel(val session: Session, val jumped: JumpedSession?, val boundPort: Int)

    private val active = ConcurrentHashMap<Int, ActiveTunnel>()
    private val locks = ConcurrentHashMap<Int, Mutex>()
    private val generations = ConcurrentHashMap<Int, TunnelGeneration>()

    fun isActive(tunnelId: Int): Boolean {
        val tunnel = active[tunnelId] ?: return false
        if (tunnel.session.isConnected) return true
        if (active.remove(tunnelId, tunnel)) tunnel.jumped?.disconnect() ?: runCatching { tunnel.session.disconnect() }
        return false
    }

    fun activeIds(): Set<Int> = active.keys.filterTo(mutableSetOf(), ::isActive)

    /** The actual local port a running tunnel bound (relevant when the request bound port 0). */
    fun boundPort(tunnelId: Int): Int? = active[tunnelId]?.boundPort

    /**
     * Bring up tunnel [id] over [creds]. [kind] is "local" | "remote" | "dynamic".
     * - local  (-L): listen on [bindHost]:[bindPort], forward to [destHost]:[destPort] via the remote.
     * - remote (-R): the remote listens on [bindPort] and forwards back to [destHost]:[destPort] (local side).
     * - dynamic(-D): a SOCKS proxy on [bindHost]:[bindPort].
     * Idempotent: starting an already-active tunnel is a no-op. Throws on connect/bind failure with a
     * cleaned-up session. Returns the bound local port (useful when [bindPort] is 0 for local/dynamic).
     */
    suspend fun start(
        id: Int,
        creds: SshCredentials,
        kind: String,
        bindHost: String,
        bindPort: Int,
        destHost: String,
        destPort: Int,
    ): Int = withContext(Dispatchers.IO) {
        val generation = generations.getOrPut(id) { TunnelGeneration() }
        val expectedGeneration = generation.snapshot()
        locks.getOrPut(id) { Mutex() }.withLock {
            active[id]?.takeIf { it.session.isConnected }?.let { return@withLock it.boundPort }
            active.remove(id)?.let { stale -> stale.jumped?.disconnect() ?: runCatching { stale.session.disconnect() } }

            var jumped: JumpedSession? = null
            var session: Session? = null
            val cancellationHandle = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
                if (cause is CancellationException) {
                    jumped?.disconnect() ?: runCatching { session?.disconnect() }
                }
            }
            try {
                val builtJumped = if (isJumpHost(creds)) buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS) else null
                jumped = builtJumped
                val builtSession = builtJumped?.target ?: buildJschSession(creds)
                session = builtSession
                builtSession.connect(CONNECT_TIMEOUT_MS)
                val bound = when (kind) {
                    "remote" -> {
                        builtSession.setPortForwardingR(bindHost, bindPort, destHost, destPort)
                        bindPort
                    }
                    "dynamic" -> builtSession.setPortForwardingL("$bindHost:$bindPort")
                    "local" -> builtSession.setPortForwardingL(bindHost, bindPort, destHost, destPort)
                    else -> throw IllegalArgumentException("Unsupported tunnel kind: $kind")
                }
                val running = ActiveTunnel(builtSession, builtJumped, bound)
                val published = generation.publishIfCurrent(
                    expected = expectedGeneration,
                    publish = { active[id] = running },
                    rollback = {
                        if (active.remove(id, running)) {
                            builtJumped?.disconnect() ?: runCatching { builtSession.disconnect() }
                        }
                    },
                )
                if (!published) throw CancellationException("Tunnel was stopped while starting")
                session = null
                jumped = null
                bound
            } catch (e: CancellationException) {
                jumped?.disconnect() ?: runCatching { session?.disconnect() }
                throw e
            } catch (e: Throwable) {
                jumped?.disconnect() ?: runCatching { session?.disconnect() }
                throw SshConnectException(e.message ?: "Failed to start tunnel", e)
            } finally {
                cancellationHandle?.dispose()
            }
        }
    }

    /** Tear a tunnel down. Safe to call when it isn't running. */
    fun stop(id: Int) {
        generations.getOrPut(id) { TunnelGeneration() }.invalidate()
        val t = active.remove(id) ?: return
        runCatching { t.jumped?.disconnect() ?: t.session.disconnect() }
    }

    /** Stop every running tunnel (app teardown / logout). */
    fun stopAll() {
        (active.keys + generations.keys).toSet().forEach { stop(it) }
    }

    private fun isJumpHost(creds: SshCredentials): Boolean =
        creds.proxyType == "ssh" && creds.proxyHost.isNotBlank() && creds.proxyPort > 0
}
