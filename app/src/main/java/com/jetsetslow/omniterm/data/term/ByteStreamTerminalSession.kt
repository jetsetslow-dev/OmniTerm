package com.jetsetslow.omniterm.data.term

import com.jetsetslow.omniterm.data.ssh.TerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext
import java.io.IOException
import kotlin.concurrent.thread

/**
 * A terminal over a plain byte stream with no shell behind it to report an exit: Telnet, a serial
 * line. Whatever ends it from the far side (the host hanging up, a dropped network, an unplugged
 * adapter) ends the session with its screen kept, as a shell's `exit` does, because there is
 * nothing to reconnect to that would carry on where it was. [endedBecause] says which.
 *
 * Subclasses supply the transport; [start] begins reading once they are ready.
 */
abstract class ByteStreamTerminalSession(private val readerName: String) : TerminalSession {
    private val outChannel = Channel<ByteArray>(OUTPUT_BUFFER_CHUNKS)
    private val _closed = MutableStateFlow(false)
    private val _exitStatus = MutableStateFlow<Int?>(null)
    private val _remoteExited = MutableStateFlow(false)
    private val writeLock = Any()

    override val output: Flow<ByteArray> = outChannel.receiveAsFlow()
    override val closed: StateFlow<Boolean> = _closed.asStateFlow()
    override val exitStatus: StateFlow<Int?> = _exitStatus.asStateFlow()
    override val remoteExited: StateFlow<Boolean> = _remoteExited.asStateFlow()

    /** Why the far side ended the session, for the terminal to show; null while it runs or when closed here. */
    @Volatile var endedBecause: String? = null
        private set

    /** Reads into [buffer]: the count read, 0 when nothing arrived yet, or -1 at the end of the stream. */
    protected abstract fun readSome(buffer: ByteArray): Int

    /** Sends [bytes] as they are, blocking until the transport took them. */
    protected abstract fun writeRaw(bytes: ByteArray)

    /** Releases the transport. Called once; a blocked [readSome] must return or throw after it. */
    protected abstract fun closeTransport()

    /**
     * What reaching the end of the stream means for this transport, e.g. "Connection closed by the
     * host". Read once the stream has ended, so it can say how it ended.
     */
    protected abstract val endOfStreamReason: String

    /** Turns bytes read from the transport into terminal bytes. Telnet strips its commands here. */
    protected open fun decode(buffer: ByteArray, count: Int): ByteArray = buffer.copyOf(count)

    /** Turns typed bytes into what goes on the wire. Telnet escapes its command byte here. */
    protected open fun encode(bytes: ByteArray): ByteArray = bytes

    /** What to show for [typed] once sent, when the far side does not echo it; null when it does. */
    protected open fun localEcho(typed: ByteArray): ByteArray? = null

    /** Sends protocol bytes from the reader (Telnet's option replies), in order with typed input. */
    protected fun sendFromReader(bytes: ByteArray) {
        synchronized(writeLock) { writeRaw(bytes) }
    }

    protected fun start() {
        thread(start = true, isDaemon = true, name = readerName) {
            val buffer = ByteArray(8192)
            var reason: String? = null
            try {
                while (!_closed.value) {
                    val read = readSome(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    val data = decode(buffer, read)
                    // Parks when the terminal falls behind, so no bytes are dropped (see JschTerminalSession).
                    if (data.isNotEmpty() && outChannel.trySendBlocking(data).isFailure) break
                }
            } catch (e: Throwable) {
                reason = e.message?.let { "Connection lost: $it" } ?: "Connection lost"
            } finally {
                if (!_closed.value) {
                    endedBecause = reason ?: endOfStreamReason
                    _exitStatus.value = 0
                    _remoteExited.value = true
                }
                close()
            }
        }
    }

    override suspend fun write(bytes: ByteArray) {
        if (_closed.value) throw IOException("Terminal channel is closed")
        withContext(Dispatchers.IO) {
            try {
                if (_closed.value) throw IOException("Terminal channel is closed")
                synchronized(writeLock) { writeRaw(encode(bytes)) }
                localEcho(bytes)?.let { outChannel.trySend(it) }
            } catch (failure: Throwable) {
                close()
                throw failure
            }
        }
    }

    override fun close() {
        if (_closed.compareAndSet(expect = false, update = true)) {
            runCatching { closeTransport() }
            outChannel.close()
        }
    }

    private companion object {
        const val OUTPUT_BUFFER_CHUNKS = 64
    }
}
