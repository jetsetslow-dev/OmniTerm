package com.jetsetslow.omniterm.data.tunnel

import com.jcraft.jsch.JSchException
import com.jcraft.jsch.SocketFactory
import com.jetsetslow.omniterm.data.AppRepository
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * How the phone reaches a host that has a tunnel. Every client that dials the host asks here, so
 * SSH, SFTP, shares and HTTP all follow the same rule: only through the tunnel, never directly,
 * even when the tunnel is down. Through the tunnel the host is dialled at its tunnel address when
 * it has one (a Tailscale 100.x or MagicDNS name), else at its own.
 *
 * The one exception is a rule the user sets on the tunnel ([TunnelNetworks]): on a Wi-Fi it names,
 * its hosts dial their own address. [tunnelNow] decides it for every kind of tunnel.
 */
object HostRoute {
    /** The name of the Wi-Fi the phone is on, or null: the phone's, unless a test sets its own. */
    @Volatile internal var wifiName: suspend () -> String? = { CurrentWifi.name() }

    /**
     * The tunnel a host that picked [tunnelId] goes through right now: that tunnel, or none (null)
     * when it picked none or the phone is on a Wi-Fi the tunnel goes direct on. A tunnel that no
     * longer exists stays the answer, so the dial fails and says so instead of going direct.
     */
    suspend fun tunnelNow(repository: AppRepository, tunnelId: Int?): Int? {
        tunnelId ?: return null
        val direct = repository.tunnelDirectWifi(tunnelId)
        if (direct.isNullOrEmpty()) return tunnelId
        return if (TunnelNetworks.goesDirect(direct, wifiName())) null else tunnelId
    }

    /** JSch's dialer for a host, or null when it has no tunnel and dials as before. */
    internal fun socketFactory(host: String, tunnelId: Int?, tunnelHost: String): SocketFactory? =
        tunnelId?.let { TunnelSocketFactory(it, rename(host, tunnelHost)) }

    /** Maps the host's own name to its tunnel address; anything else (a proxy, a jump host) keeps its name. */
    internal fun rename(host: String, tunnelHost: String): (String) -> String = { dialled ->
        if (tunnelHost.isNotBlank() && dialled.equals(host, ignoreCase = true)) tunnelHost.trim() else dialled
    }
}

/** JSch's dialer through tunnel [tunnelId]. Proxies and jump hosts are dialled through it too. */
internal class TunnelSocketFactory(
    private val tunnelId: Int,
    private val rename: (String) -> String = { it },
    private val timeoutMs: Int = TunnelSocket.DEFAULT_TIMEOUT_MS,
) : SocketFactory {
    override fun createSocket(host: String, port: Int): Socket {
        // JSch dials the host's SSH session, and its jump host or proxy, through here.
        val socket = javaSocket(tunnelId, TunnelUse.SSH)
        try {
            socket.connect(InetSocketAddress.createUnresolved(rename(host), port), timeoutMs)
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw JSchException(e.message ?: e.toString(), e)
        }
        return socket
    }

    override fun getInputStream(socket: Socket): InputStream = socket.getInputStream()
    override fun getOutputStream(socket: Socket): OutputStream = socket.getOutputStream()

    companion object {
        /** An unconnected socket that connects through tunnel [tunnelId] for [use], for clients that connect it themselves. */
        fun javaSocket(tunnelId: Int, use: TunnelUse): Socket =
            TunnelSocket { host, port, timeout -> TunnelManager.dial(tunnelId, host, port, timeout, use) }
    }
}

/**
 * An HTTP client's dialer through tunnel [tunnelId] (OkHttp's `socketFactory`), with [rename]
 * mapping the server's own name to its tunnel address. Use it with [TunnelDns], so the phone never
 * looks the name up itself.
 */
internal class TunnelHttpSocketFactory(
    private val tunnelId: Int,
    private val rename: (String) -> String = { it },
) : javax.net.SocketFactory() {
    override fun createSocket(): Socket =
        TunnelSocket { host, port, timeout -> TunnelManager.dial(tunnelId, rename(host), port, timeout, TunnelUse.OTHER) }
    override fun createSocket(host: String, port: Int): Socket =
        createSocket().apply { connect(InetSocketAddress.createUnresolved(host, port), TunnelSocket.DEFAULT_TIMEOUT_MS) }
    override fun createSocket(host: String, port: Int, localHost: java.net.InetAddress?, localPort: Int): Socket = createSocket(host, port)
    override fun createSocket(host: java.net.InetAddress, port: Int): Socket = createSocket(nameOf(host), port)
    override fun createSocket(address: java.net.InetAddress, port: Int, localAddress: java.net.InetAddress?, localPort: Int): Socket =
        createSocket(nameOf(address), port)

    // The name it was made with, else its address: never a reverse lookup on the phone.
    private fun nameOf(address: java.net.InetAddress) = address.toString().substringBefore('/').ifEmpty { address.hostAddress.orEmpty() }
}

/**
 * Name lookups for a client that dials through a tunnel: none on the phone. Each name comes back
 * as a placeholder address that keeps the name, which [TunnelSocket] dials by name, so the tunnel
 * resolves it (a MagicDNS name, say) and the phone's own resolver never sees it.
 */
internal object TunnelDns : okhttp3.Dns {
    override fun lookup(hostname: String): List<java.net.InetAddress> = listOf(java.net.InetAddress.getByAddress(hostname, ByteArray(4)))
}
