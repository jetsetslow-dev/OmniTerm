package com.jetsetslow.omniterm.data.telnet

import com.jetsetslow.omniterm.data.term.ByteStreamTerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * A terminal on a Telnet server, or on any plain TCP service that talks text. Nothing it sends or
 * receives is encrypted. See [TelnetCodec] for the protocol.
 */
class TelnetSession private constructor(
    private val socket: Socket,
    private val codec: TelnetCodec,
    offerOptions: Boolean,
) : ByteStreamTerminalSession("telnet-reader") {
    private val input = socket.getInputStream()
    private val out = socket.getOutputStream()

    override val endOfStreamReason = "Connection closed by the host"

    init {
        if (offerOptions) sendFromReader(codec.opening())
        start()
    }

    override fun readSome(buffer: ByteArray): Int = input.read(buffer)

    override fun writeRaw(bytes: ByteArray) {
        out.write(bytes)
        out.flush()
    }

    override fun closeTransport() = socket.close()

    override fun decode(buffer: ByteArray, count: Int): ByteArray {
        val replies = ByteArrayOutputStream()
        val data = codec.decode(buffer, count, replies)
        if (replies.size() > 0) sendFromReader(replies.toByteArray())
        return data
    }

    override fun encode(bytes: ByteArray): ByteArray = codec.encode(bytes)

    override fun localEcho(typed: ByteArray): ByteArray? = codec.localEcho(typed)

    override suspend fun resize(cols: Int, rows: Int) {
        val report = codec.resize(cols, rows) ?: return
        if (closed.value) return
        withContext(Dispatchers.IO) { runCatching { sendFromReader(report) } }
    }

    companion object {
        const val DEFAULT_PORT = 23
        private const val CONNECT_TIMEOUT_MS = 10_000

        /** Connects to [host]:[port]; throws when it cannot. Options are offered only on the Telnet port. */
        suspend fun open(host: String, port: Int, cols: Int, rows: Int): TelnetSession = withContext(Dispatchers.IO) {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                socket.keepAlive = true
                TelnetSession(socket, TelnetCodec(cols, rows), offerOptions = port == DEFAULT_PORT)
            } catch (e: Exception) {
                runCatching { socket.close() }
                throw e
            }
        }
    }
}
