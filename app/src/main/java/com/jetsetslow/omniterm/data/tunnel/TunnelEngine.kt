package com.jetsetslow.omniterm.data.tunnel

import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Omnitunnel
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Resolver
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Tunnel
import java.io.IOException
import java.net.InetAddress

/** What starts tunnels. The app uses [GoTunnelEngine]; tests use their own. */
interface TunnelEngine {
    /** What is wrong with [config] for [kind], or null when it can be used. */
    fun check(kind: String, config: String): String?

    /** Brings a tunnel up. [resolve] looks names up with the phone's own DNS. */
    fun start(kind: String, config: String, resolve: (String) -> List<String>): RunningTunnel
}

/** A tunnel that is up. */
interface RunningTunnel {
    fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink
    val connections: Int
    /** When the newest handshake completed, in Unix seconds; 0 before the first. */
    val lastHandshake: Long
    val bytesIn: Long
    val bytesOut: Long
    fun close()
}

/** The Go library (tunnel/omnitunnel), built for each Android ABI by scripts/build-tunnel.sh. */
object GoTunnelEngine : TunnelEngine {
    /** Null when the library loaded, else why tunnels cannot work on this phone. */
    private val unavailable: String? by lazy {
        try {
            Omnitunnel.touch()
            null
        } catch (_: UnsatisfiedLinkError) {
            "Tunnels are not available on this phone's processor."
        } catch (_: ExceptionInInitializerError) {
            "Tunnels are not available on this phone's processor."
        }
    }

    override fun check(kind: String, config: String): String? {
        unavailable?.let { return it }
        return when (kind) {
            TunnelKinds.WIREGUARD -> Omnitunnel.checkWireGuard(config).ifEmpty { null }
            else -> "This kind of tunnel is not supported."
        }
    }

    override fun start(kind: String, config: String, resolve: (String) -> List<String>): RunningTunnel {
        unavailable?.let { throw IOException(it) }
        val resolver = Resolver { host -> resolve(host).joinToString(",") }
        val tunnel = try {
            when (kind) {
                TunnelKinds.WIREGUARD -> Omnitunnel.startWireGuard(config, resolver)
                else -> throw IOException("This kind of tunnel is not supported.")
            }
        } catch (e: IOException) {
            throw e
        } catch (e: Exception) {
            throw IOException(e.message ?: "The tunnel could not start.", e)
        }
        return GoRunningTunnel(tunnel)
    }

    private class GoRunningTunnel(private val tunnel: Tunnel) : RunningTunnel {
        override fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink {
            val fd = try {
                tunnel.dialFd(host, port.toLong(), timeoutMs.toLong())
            } catch (e: Exception) {
                throw IOException(e.message ?: "The connection through the tunnel failed.", e)
            }
            return FdLink(fd.toInt())
        }

        override val connections: Int get() = tunnel.connections().toInt()
        override val lastHandshake: Long get() = tunnel.lastHandshake()
        override val bytesIn: Long get() = tunnel.bytesIn()
        override val bytesOut: Long get() = tunnel.bytesOut()
        override fun close() = tunnel.close()
    }
}

/** The phone's own resolver, for names the tunnel has no DNS server for. */
internal fun systemResolve(host: String): List<String> =
    try {
        InetAddress.getAllByName(host).mapNotNull { it.hostAddress }
    } catch (_: IOException) {
        emptyList()
    }
