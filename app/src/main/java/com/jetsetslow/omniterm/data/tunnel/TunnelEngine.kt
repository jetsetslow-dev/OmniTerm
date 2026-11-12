package com.jetsetslow.omniterm.data.tunnel

import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Omnitunnel
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Resolver
import com.jetsetslow.omniterm.gotunnel.omnitunnel.StateStore
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Tunnel
import java.io.File
import java.io.IOException
import java.net.InetAddress

/** What starts tunnels. The app uses [GoTunnelEngine]; tests use their own. */
interface TunnelEngine {
    /** What is wrong with [config] for [kind], or null when it can be used. */
    fun check(kind: String, config: String): String?

    /**
     * Brings a tunnel up. [resolve] looks names up with the phone's own DNS. A tunnel that is a node
     * of a network (Tailscale) keeps what makes it that node in [node].
     */
    fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode): RunningTunnel
}

/**
 * Where a Tailscale tunnel keeps its node: its state goes to the app's database, encrypted
 * ([load], [save]); [scratch] is a private folder for what the library writes that is no secret.
 */
interface TunnelNode {
    val scratch: File
    fun load(): String
    /** Keeps [state]; throws when it could not be kept, which the tunnel is told. */
    fun save(state: String)
}

/** The states a tunnel reports; only a running one carries connections. */
object TunnelStates {
    const val RUNNING = "running"
    const val STARTING = "starting"
    const val NEEDS_LOGIN = "needs-login"
    const val NEEDS_APPROVAL = "needs-approval"
    const val FAILED = "failed"
}

/** A tunnel that is up. */
interface RunningTunnel {
    fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink
    val connections: Int
    /** When the newest handshake completed, in Unix seconds; 0 before the first. */
    val lastHandshake: Long
    val bytesIn: Long
    val bytesOut: Long
    /** One of [TunnelStates]: a WireGuard tunnel runs from the start, a Tailscale one once signed in. */
    val state: String get() = TunnelStates.RUNNING
    /** The page where the user signs the tunnel in, while it needs that; else "". */
    val authUrl: String get() = ""
    /** The phone's own addresses inside the tunnel, joined by commas. */
    val addresses: String get() = ""
    /** What the user should know about the tunnel now (its control server refusing it, or being busy), or "". */
    val problem: String get() = ""
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

    /** Whether the library is loaded, without loading it. */
    @Volatile var loaded = false
        private set

    override fun check(kind: String, config: String): String? {
        unavailable?.let { return it }
        return when (kind) {
            TunnelKinds.WIREGUARD -> Omnitunnel.checkWireGuard(config).ifEmpty { null }
            TunnelKinds.TAILSCALE -> Omnitunnel.checkTailscale(config).ifEmpty { null }
            else -> "This kind of tunnel is not supported."
        }
    }

    override fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode): RunningTunnel {
        unavailable?.let { throw IOException(it) }
        loaded = true
        val tunnel = try {
            when (kind) {
                TunnelKinds.WIREGUARD -> Omnitunnel.startWireGuard(config, Resolver { host -> resolve(host).joinToString(",") })
                TunnelKinds.TAILSCALE -> {
                    TailscaleNetwork.tellGo()
                    val store = object : StateStore {
                        override fun load(): String = node.load()
                        override fun save(state: String) = node.save(state)
                    }
                    Omnitunnel.startTailscale(config, node.scratch.path, store, TAILSCALE_WAIT_MS)
                }
                else -> throw IOException("This kind of tunnel is not supported.")
            }
        } catch (e: IOException) {
            throw e
        } catch (e: Exception) {
            throw IOException(e.message ?: "The tunnel could not start.", e)
        }
        return GoRunningTunnel(tunnel)
    }

    /** How long a Tailscale tunnel may take to reach its control server, or to ask for a sign-in. */
    private const val TAILSCALE_WAIT_MS = 30_000L

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
        override val state: String get() = tunnel.state()
        override val authUrl: String get() = tunnel.authURL()
        override val addresses: String get() = tunnel.addresses()
        override val problem: String get() = tunnel.problem()
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
