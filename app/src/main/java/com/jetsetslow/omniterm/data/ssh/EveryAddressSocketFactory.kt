package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSchException
import com.jcraft.jsch.SocketFactory
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Dials every address a host name resolves to, in the resolver's order, until one answers. JSch on
 * its own dials only the first, so a host whose first address does not answer from here (an IPv6
 * address on a network that cannot reach it, a dead round-robin entry) timed out even though the
 * next address would have connected at once.
 *
 * The connect timeout is shared out over the addresses still to try, so one that never answers
 * cannot use up the whole of it, and the dial as a whole still ends within [timeoutMs]. Failures
 * read as JSch's own do ("timeout: socket is not established", or the exception), so the app
 * describes them as before. JSch also dials HTTP and SOCKS proxies through this.
 */
internal class EveryAddressSocketFactory(
    private val timeoutMs: Int = DIAL_TIMEOUT_MS,
    private val resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    private val dial: (Socket, InetSocketAddress, Int) -> Unit = { socket, address, timeout -> socket.connect(address, timeout) },
    private val nanoTime: () -> Long = System::nanoTime,
) : SocketFactory {

    override fun createSocket(host: String, port: Int): Socket {
        val addresses = try {
            resolve(host)
        } catch (e: UnknownHostException) {
            throw JSchException(e.toString(), e)
        }
        val deadline = nanoTime() + timeoutMs * 1_000_000L
        var failure: Exception = SocketTimeoutException()
        for ((index, address) in addresses.withIndex()) {
            val left = ((deadline - nanoTime()) / 1_000_000L).toInt()
            if (left <= 0) break
            val share = (left / (addresses.size - index)).coerceAtLeast(MIN_SHARE_MS).coerceAtMost(left)
            val socket = Socket()
            try {
                dial(socket, InetSocketAddress(address, port), share)
                return socket
            } catch (e: Exception) {
                runCatching { socket.close() }
                failure = e
            }
        }
        val message = if (failure is SocketTimeoutException) "timeout: socket is not established" else failure.toString()
        throw JSchException(message, failure)
    }

    override fun getInputStream(socket: Socket): InputStream = socket.getInputStream()

    override fun getOutputStream(socket: Socket): OutputStream = socket.getOutputStream()

    companion object {
        /** Every session connects with 15 s ([JschSshTransport.CONNECT_TIMEOUT_MS]); JSch does not hand a factory its timeout. */
        const val DIAL_TIMEOUT_MS = 15_000

        /** No address gets less than this while time is left: an answer can take a few seconds on a slow mobile link. */
        const val MIN_SHARE_MS = 3_000
    }
}
