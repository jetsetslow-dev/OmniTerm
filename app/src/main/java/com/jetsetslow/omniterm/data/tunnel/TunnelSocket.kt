package com.jetsetslow.omniterm.data.tunnel

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import java.io.Closeable
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException

/** One connection through a tunnel, as streams, with the read timeout a socket has. */
interface TunnelLink : Closeable {
    val input: InputStream
    val output: OutputStream

    /** Reads give up with [SocketTimeoutException] after this long without data; 0 waits forever. */
    fun setReadTimeout(ms: Int)
    fun shutdownInput()
    fun shutdownOutput()
}

/**
 * A connection through a tunnel as a [Socket], so every client that takes a socket factory (JSch,
 * and the HTTP, SMB and FTP clients) goes through the tunnel without knowing it is there. Nothing
 * of a real socket is ever created: options a TCP socket has are accepted and do nothing here,
 * because the tunnel's own TCP stack sets them.
 */
class TunnelSocket(private val dial: (host: String, port: Int, timeoutMs: Int) -> TunnelLink) : Socket() {
    @Volatile private var link: TunnelLink? = null
    @Volatile private var remote: InetSocketAddress? = null
    @Volatile private var closed = false
    @Volatile private var timeout = 0
    @Volatile private var inputShut = false
    @Volatile private var outputShut = false

    override fun connect(endpoint: SocketAddress) = connect(endpoint, 0)

    override fun connect(endpoint: SocketAddress, timeout: Int) {
        val address = endpoint as? InetSocketAddress ?: throw IllegalArgumentException("Unsupported address type")
        if (closed) throw SocketException("Socket is closed")
        if (link != null) throw SocketException("already connected")
        val host = address.hostString
        val opened = dial(host, address.port, if (timeout > 0) timeout else DEFAULT_TIMEOUT_MS)
        opened.setReadTimeout(this.timeout)
        link = opened
        remote = address
        if (closed) opened.close()
    }

    private fun connected(): TunnelLink = when {
        closed -> throw SocketException("Socket is closed")
        else -> link ?: throw SocketException("Socket is not connected")
    }

    override fun getInputStream(): InputStream = connected().input
    override fun getOutputStream(): OutputStream = connected().output

    override fun setSoTimeout(timeout: Int) {
        require(timeout >= 0) { "timeout can't be negative" }
        this.timeout = timeout
        link?.setReadTimeout(timeout)
    }

    override fun getSoTimeout(): Int = timeout
    override fun setTcpNoDelay(on: Boolean) = Unit
    override fun getTcpNoDelay(): Boolean = true
    override fun setKeepAlive(on: Boolean) = Unit
    override fun getKeepAlive(): Boolean = false
    override fun setSoLinger(on: Boolean, linger: Int) = Unit
    override fun getSoLinger(): Int = -1
    override fun setSendBufferSize(size: Int) = Unit
    override fun getSendBufferSize(): Int = BUFFER_BYTES
    override fun setReceiveBufferSize(size: Int) = Unit
    override fun getReceiveBufferSize(): Int = BUFFER_BYTES
    override fun setTrafficClass(tc: Int) = Unit
    override fun getTrafficClass(): Int = 0
    override fun setReuseAddress(on: Boolean) = Unit
    override fun getReuseAddress(): Boolean = false
    override fun setOOBInline(on: Boolean) = Unit
    override fun getOOBInline(): Boolean = false
    override fun sendUrgentData(data: Int) = throw SocketException("Urgent data is not supported through a tunnel")
    override fun bind(bindpoint: SocketAddress?) = Unit

    override fun isConnected(): Boolean = link != null
    override fun isBound(): Boolean = link != null
    override fun isClosed(): Boolean = closed
    override fun isInputShutdown(): Boolean = inputShut
    override fun isOutputShutdown(): Boolean = outputShut
    override fun getInetAddress(): InetAddress? = remote?.address
    override fun getPort(): Int = remote?.port ?: 0
    override fun getRemoteSocketAddress(): SocketAddress? = remote
    override fun getLocalAddress(): InetAddress = InetAddress.getByAddress(byteArrayOf(0, 0, 0, 0))
    override fun getLocalPort(): Int = -1
    override fun getLocalSocketAddress(): SocketAddress? = null

    override fun shutdownInput() {
        connected().shutdownInput()
        inputShut = true
    }

    override fun shutdownOutput() {
        connected().shutdownOutput()
        outputShut = true
    }

    override fun close() {
        if (closed) return
        closed = true
        link?.close()
    }

    override fun toString(): String = "TunnelSocket[${remote ?: "unconnected"}]"

    companion object {
        const val DEFAULT_TIMEOUT_MS = 15_000
        private const val BUFFER_BYTES = 64 * 1024
    }
}

/**
 * The app's end of the socket pair the Go library hands over. Closing it while another thread is
 * reading wakes that thread: the descriptor is shut down first, then closed through the platform's
 * own close, which never lets a reused descriptor number be read by mistake.
 */
internal class FdLink(fd: Int) : TunnelLink {
    private val pfd = ParcelFileDescriptor.adoptFd(fd)
    private val descriptor = pfd.fileDescriptor
    private val rawIn = FileInputStream(descriptor)
    private val rawOut = FileOutputStream(descriptor)
    @Volatile private var timeout = 0
    @Volatile private var closed = false

    override val input: InputStream = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (closed) throw SocketException("Socket closed")
            if (len == 0) return 0
            timeout.takeIf { it > 0 }?.let(::awaitReadable)
            return try {
                rawIn.read(b, off, len)
            } catch (e: IOException) {
                if (closed) throw SocketException("Socket closed") else throw e
            }
        }

        override fun available(): Int = if (closed) 0 else runCatching { rawIn.available() }.getOrDefault(0)
        override fun close() = this@FdLink.close()
    }

    override val output: OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (closed) throw SocketException("Socket closed")
            try {
                rawOut.write(b, off, len)
            } catch (e: IOException) {
                if (closed) throw SocketException("Socket closed") else throw SocketException("Broken pipe: ${e.message}")
            }
        }

        override fun close() = this@FdLink.close()
    }

    private fun awaitReadable(ms: Int) {
        val deadline = SystemClock.uptimeMillis() + ms
        while (true) {
            val left = (deadline - SystemClock.uptimeMillis()).toInt()
            if (left <= 0) throw SocketTimeoutException("Read timed out")
            val poll = StructPollfd().apply {
                fd = descriptor
                events = OsConstants.POLLIN.toShort()
            }
            val ready = try {
                Os.poll(arrayOf(poll), left)
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EINTR) continue
                throw SocketException(e.message)
            }
            // Readable, the end of the stream, or an error: the read itself reports which.
            if (ready > 0) return
        }
    }

    override fun setReadTimeout(ms: Int) {
        timeout = ms
    }

    override fun shutdownInput() {
        runCatching { Os.shutdown(descriptor, OsConstants.SHUT_RD) }
    }

    override fun shutdownOutput() {
        runCatching { Os.shutdown(descriptor, OsConstants.SHUT_WR) }
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { Os.shutdown(descriptor, OsConstants.SHUT_RDWR) }
        runCatching { pfd.close() }
    }
}
