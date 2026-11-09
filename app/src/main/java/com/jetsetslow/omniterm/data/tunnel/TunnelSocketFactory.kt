package com.jetsetslow.omniterm.data.tunnel

import com.jcraft.jsch.JSchException
import com.jcraft.jsch.SocketFactory
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
 */
object HostRoute {
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
        val socket = javaSocket(tunnelId)
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
        /** An unconnected socket that connects through tunnel [tunnelId], for clients that connect it themselves. */
        fun javaSocket(tunnelId: Int): Socket = TunnelSocket { host, port, timeout -> TunnelManager.dial(tunnelId, host, port, timeout) }
    }
}
