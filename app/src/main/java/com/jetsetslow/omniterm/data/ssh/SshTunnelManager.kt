package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Session
import com.jcraft.jsch.ChannelDirectTCPIP
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

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
    private class ActiveTunnel(
        val session: Session,
        val jumped: JumpedSession?,
        val boundPort: Int,
        val dynamicProxy: DynamicSocksProxy? = null,
    ) {
        fun disconnect() {
            dynamicProxy?.close()
            jumped?.disconnect() ?: runCatching { session.disconnect() }
        }
    }

    private val active = ConcurrentHashMap<Int, ActiveTunnel>()
    private val locks = ConcurrentHashMap<Int, Mutex>()
    private val generations = ConcurrentHashMap<Int, TunnelGeneration>()

    fun isActive(tunnelId: Int): Boolean {
        val tunnel = active[tunnelId] ?: return false
        if (tunnel.session.isConnected && tunnel.dynamicProxy?.isRunning != false) return true
        if (active.remove(tunnelId, tunnel)) tunnel.disconnect()
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
            active.remove(id)?.disconnect()

            var jumped: JumpedSession? = null
            var session: Session? = null
            var dynamicProxy: DynamicSocksProxy? = null
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
                    // JSch's String overload parses an OpenSSH *local-forward* specification; it
                    // does not implement `ssh -D`. Passing only host:port therefore always throws
                    // `parseForwarding`. Run a small local SOCKS4/5 listener and open one
                    // direct-tcpip channel per CONNECT request over this dedicated SSH session.
                    "dynamic" -> DynamicSocksProxy(builtSession, bindHost, bindPort).also {
                        it.start()
                        dynamicProxy = it
                    }.boundPort
                    "local" -> builtSession.setPortForwardingL(bindHost, bindPort, destHost, destPort)
                    else -> throw IllegalArgumentException("Unsupported tunnel kind: $kind")
                }
                val running = ActiveTunnel(builtSession, builtJumped, bound, dynamicProxy)
                val published = generation.publishIfCurrent(
                    expected = expectedGeneration,
                    publish = { active[id] = running },
                    rollback = {
                        if (active.remove(id, running)) {
                            running.disconnect()
                        }
                    },
                )
                if (!published) throw CancellationException("Tunnel was stopped while starting")
                session = null
                jumped = null
                bound
            } catch (e: CancellationException) {
                dynamicProxy?.close()
                jumped?.disconnect() ?: runCatching { session?.disconnect() }
                throw e
            } catch (e: Throwable) {
                dynamicProxy?.close()
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
        runCatching { t.disconnect() }
    }

    /** Stop every running tunnel (app teardown / logout). */
    fun stopAll() {
        (active.keys + generations.keys).toSet().forEach { stop(it) }
    }

    private fun isJumpHost(creds: SshCredentials): Boolean =
        creds.proxyType == "ssh" && creds.proxyHost.isNotBlank() && creds.proxyPort > 0

    /** Local SOCKS4/SOCKS4a/SOCKS5 CONNECT proxy backed by JSch direct-tcpip channels. */
    private class DynamicSocksProxy(
        private val session: Session,
        bindHost: String,
        requestedPort: Int,
    ) {
        private val running = AtomicBoolean(false)
        private val server = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(bindHost, requestedPort))
        }
        private val clients = ConcurrentHashMap.newKeySet<Socket>()
        private val channels = ConcurrentHashMap.newKeySet<ChannelDirectTCPIP>()
        val boundPort: Int get() = server.localPort
        val isRunning: Boolean get() = running.get() && !server.isClosed

        fun start() {
            check(running.compareAndSet(false, true))
            thread("OmniTerm-SOCKS-accept-$boundPort") {
                while (running.get() && session.isConnected) {
                    val socket = try { server.accept() } catch (_: Throwable) { break }
                    clients += socket
                    thread("OmniTerm-SOCKS-client") { handle(socket) }
                }
                close()
            }
        }

        fun close() {
            if (!running.getAndSet(false) && server.isClosed) return
            runCatching { server.close() }
            clients.toList().forEach { runCatching { it.close() } }
            channels.toList().forEach { runCatching { it.disconnect() } }
            clients.clear()
            channels.clear()
        }

        private fun handle(socket: Socket) {
            var channel: ChannelDirectTCPIP? = null
            try {
                socket.tcpNoDelay = true
                socket.soTimeout = 15_000
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                val version = input.read()
                val target = when (version) {
                    5 -> readSocks5Target(input, output)
                    4 -> readSocks4Target(input)
                    else -> null
                } ?: return

                channel = session.openChannel("direct-tcpip") as ChannelDirectTCPIP
                channels += channel
                channel.setHost(target.first)
                channel.setPort(target.second)
                channel.setOrgIPAddress(socket.inetAddress?.hostAddress ?: "127.0.0.1")
                channel.setOrgPort(socket.port)
                // ChannelDirectTCPIP only starts its pump thread when an input stream is installed.
                // Using getInputStream/getOutputStream leaves io.in null at connect(), opens the
                // channel synchronously, but never pumps the client request — the SOCKS handshake
                // succeeds and every tunneled request then times out with no response.
                channel.setInputStream(input)
                channel.setOutputStream(output)
                try {
                    channel.connect(CONNECT_TIMEOUT_MS)
                    val deadline = System.nanoTime() + CONNECT_TIMEOUT_MS * 1_000_000L
                    while (!channel.isConnected && System.nanoTime() < deadline) Thread.sleep(10)
                    if (!channel.isConnected) throw java.io.IOException("SSH direct-tcpip channel timed out")
                } catch (t: Throwable) {
                    if (version == 5) output.write(byteArrayOf(5, 5, 0, 1, 0, 0, 0, 0, 0, 0))
                    else output.write(byteArrayOf(0, 91, 0, 0, 0, 0, 0, 0))
                    output.flush()
                    throw t
                }

                if (version == 5) output.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
                else output.write(byteArrayOf(0, 90, 0, 0, 0, 0, 0, 0))
                output.flush()
                socket.soTimeout = 0
                while (running.get() && session.isConnected && channel.isConnected && !socket.isClosed) {
                    Thread.sleep(100)
                }
            } catch (_: Throwable) {
                // A malformed/aborted SOCKS handshake or an unreachable destination affects only
                // that client connection. Never let a listener worker reach the process-wide
                // uncaught-exception handler (which correctly records actual app crashes).
            } finally {
                channel?.let { channels.remove(it); runCatching { it.disconnect() } }
                clients.remove(socket)
                runCatching { socket.close() }
            }
        }

        private fun readSocks5Target(input: java.io.InputStream, output: java.io.OutputStream): Pair<String, Int>? {
            val methods = ByteArray(readByte(input))
            readFully(input, methods)
            if (methods.none { it.toInt() and 0xff == 0 }) {
                output.write(byteArrayOf(5, 0xff.toByte())); output.flush(); return null
            }
            output.write(byteArrayOf(5, 0)); output.flush()
            if (readByte(input) != 5 || readByte(input) != 1) return null
            readByte(input) // reserved
            val host = when (readByte(input)) {
                1 -> InetAddress.getByAddress(ByteArray(4).also { readFully(input, it) }).hostAddress
                3 -> ByteArray(readByte(input)).also { readFully(input, it) }.toString(Charsets.UTF_8)
                4 -> InetAddress.getByAddress(ByteArray(16).also { readFully(input, it) }).hostAddress
                else -> return null
            }
            return host to readPort(input)
        }

        private fun readSocks4Target(input: java.io.InputStream): Pair<String, Int>? {
            if (readByte(input) != 1) return null
            val port = readPort(input)
            val address = ByteArray(4).also { readFully(input, it) }
            readNullTerminated(input) // user id
            val host = if (address[0] == 0.toByte() && address[1] == 0.toByte() &&
                address[2] == 0.toByte() && address[3] != 0.toByte()
            ) readNullTerminated(input) else InetAddress.getByAddress(address).hostAddress
            return host to port
        }

        private fun readPort(input: java.io.InputStream): Int = (readByte(input) shl 8) or readByte(input)

        private fun readByte(input: java.io.InputStream): Int = input.read().also {
            if (it < 0) throw java.io.EOFException("Unexpected end of SOCKS request")
        }

        private fun readFully(input: java.io.InputStream, bytes: ByteArray) {
            var offset = 0
            while (offset < bytes.size) {
                val read = input.read(bytes, offset, bytes.size - offset)
                if (read < 0) throw java.io.EOFException("Unexpected end of SOCKS request")
                offset += read
            }
        }

        private fun readNullTerminated(input: java.io.InputStream): String {
            val out = java.io.ByteArrayOutputStream()
            repeat(1024) {
                val next = readByte(input)
                if (next == 0) return out.toString(Charsets.UTF_8.name())
                out.write(next)
            }
            throw java.io.IOException("SOCKS field exceeds 1024 bytes")
        }

        private fun thread(name: String, block: () -> Unit): Thread =
            Thread(block, name).apply { isDaemon = true; start() }
    }
}
