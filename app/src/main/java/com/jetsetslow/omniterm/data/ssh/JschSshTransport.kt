package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import kotlin.concurrent.thread

/**
 * JSch-backed [SshTransport] (Android / JVM only).
 *
 * NOTE: this is the Android `actual` in spirit — when migrating to Compose Multiplatform,
 * move this file to `androidMain` and provide an iOS `actual` for [SshTransport].
 */
class JschSshTransport : SshTransport {

    // Pooled, reused sessions for one-shot exec/execStream calls (NOT for interactive shells).
    private val pool = SshSessionPool(CONNECT_TIMEOUT_MS)

    private fun isJump(creds: SshCredentials): Boolean =
        creds.proxyType == "ssh" && creds.proxyHost.isNotBlank() && creds.proxyPort > 0

    private fun newSession(creds: SshCredentials): Session = buildJschSession(creds)

    /** A transport-level drop is worth one reconnect; a genuine auth failure is not. */
    private fun isRetriable(e: Throwable): Boolean {
        if (e is kotlinx.coroutines.CancellationException) return false
        val m = (e.message ?: "").lowercase()
        return !m.contains("auth")
    }

    override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
        withContext(Dispatchers.IO) {
            try {
                execOnce(creds, command, stdin)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (isRetriable(e)) {
                    // The pooled session may have gone stale — rebuild once and retry.
                    pool.evict(creds)
                    try {
                        execOnce(creds, command, stdin)
                    } catch (e2: kotlinx.coroutines.CancellationException) {
                        throw e2
                    } catch (e2: Throwable) {
                        "SSH Error: ${e2.message}"
                    }
                } else {
                    "SSH Error: ${e.message}"
                }
            }
        }

    /**
     * Run [command] on a fresh exec channel of the pooled session; closes only the channel.
     *
     * SSH jump hosts ("ssh") cannot use the pool (it has nowhere to store/close the paired jump
     * session), so they take an un-pooled jumped path instead. HTTP/SOCKS5 proxies ride along in
     * [buildJschSession] and work on the pooled path too.
     */
    private suspend fun execOnce(creds: SshCredentials, command: String, stdin: String? = null): String {
        if (isJump(creds)) return execOnceJumped(creds, command, stdin)
        val session = pool.acquire(creds)
        val channel = (session.openChannel("exec") as ChannelExec).apply {
            setCommand(command)
            // Secrets (sudo passwords) travel via the channel's stdin, never the command string.
            setInputStream(stdin?.byteInputStream(Charsets.UTF_8))
        }
        return try {
            val input = channel.inputStream
            val err = channel.errStream
            channel.connect(CONNECT_TIMEOUT_MS)
            readExecResult(input, err, channel)
        } finally {
            channel.disconnect()
        }
    }

    /** Un-pooled exec over an SSH jump host: one jump+target session per call, torn down after. */
    private fun execOnceJumped(creds: SshCredentials, command: String, stdin: String? = null): String {
        val jumped = buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS)
        val session = jumped.target
        var channel: ChannelExec? = null
        return try {
            session.connect(CONNECT_TIMEOUT_MS)
            channel = (session.openChannel("exec") as ChannelExec).apply {
                setCommand(command)
                setInputStream(stdin?.byteInputStream(Charsets.UTF_8))
            }
            val input = channel.inputStream
            val err = channel.errStream
            channel.connect(CONNECT_TIMEOUT_MS)
            readExecResult(input, err, channel)
        } finally {
            runCatching { channel?.disconnect() }
            jumped.disconnect()
        }
    }

    override suspend fun execStream(
        creds: SshCredentials,
        command: String,
        stdin: String?,
        onChunk: suspend (String) -> Unit,
    ): String {
        // Runs on the caller's dispatcher; the blocking read loop is offloaded to IO below and
        // chunks are posted via the suspend onChunk (whose implementation marshals to Main).
        return withContext(Dispatchers.IO) {
            // Only retry if nothing was emitted yet, so a mid-stream drop can't duplicate output.
            var emitted = false
            val tracking: suspend (String) -> Unit = { emitted = true; onChunk(it) }
            try {
                execStreamOnce(creds, command, stdin, tracking)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (isRetriable(e) && !emitted) {
                    pool.evict(creds)
                    try {
                        execStreamOnce(creds, command, stdin, tracking)
                    } catch (e2: kotlinx.coroutines.CancellationException) {
                        throw e2
                    } catch (e2: Throwable) {
                        val errMsg = "SSH Error: ${e2.message}"
                        onChunk(errMsg); errMsg
                    }
                } else {
                    val errMsg = "SSH Error: ${e.message}"
                    onChunk(errMsg); errMsg
                }
            }
        }
    }

    private suspend fun execStreamOnce(
        creds: SshCredentials,
        command: String,
        stdin: String?,
        onChunk: suspend (String) -> Unit,
    ): String {
        val accumulated = StringBuilder()
        // Jump hosts can't be pooled, so they run on a dedicated un-pooled session that is torn
        // down (target + jump) in the finally block; pooled sessions are only channel-closed.
        val jumped = if (isJump(creds)) buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS) else null
        val session = if (jumped != null) jumped.target.also { it.connect(CONNECT_TIMEOUT_MS) } else pool.acquire(creds)
        var channel: ChannelExec? = null
        try {
            channel = (session.openChannel("exec") as ChannelExec).apply {
                setCommand(command)
                setInputStream(stdin?.byteInputStream(Charsets.UTF_8))
            }
            val stdoutStream = channel.inputStream
            val stderrStream = channel.errStream
            channel.connect(CONNECT_TIMEOUT_MS)

            val buf = ByteArray(4096)
            while (true) {
                val stdoutAvail = stdoutStream.available()
                val stderrAvail = stderrStream.available()
                if (stdoutAvail > 0) {
                    val n = stdoutStream.read(buf, 0, minOf(stdoutAvail, buf.size))
                    if (n > 0) {
                        val chunk = String(buf, 0, n, Charsets.UTF_8)
                        accumulated.append(chunk)
                        onChunk(chunk)
                    }
                } else if (stderrAvail > 0) {
                    val n = stderrStream.read(buf, 0, minOf(stderrAvail, buf.size))
                    if (n > 0) {
                        val chunk = String(buf, 0, n, Charsets.UTF_8)
                        accumulated.append(chunk)
                        onChunk(chunk)
                    }
                } else if (channel.isClosed) {
                    // Drain any remaining bytes after the channel-closed signal.
                    while (stdoutStream.available() > 0) {
                        val n = stdoutStream.read(buf, 0, minOf(stdoutStream.available(), buf.size))
                        if (n > 0) {
                            val chunk = String(buf, 0, n, Charsets.UTF_8)
                            accumulated.append(chunk)
                            onChunk(chunk)
                        }
                    }
                    while (stderrStream.available() > 0) {
                        val n = stderrStream.read(buf, 0, minOf(stderrStream.available(), buf.size))
                        if (n > 0) {
                            val chunk = String(buf, 0, n, Charsets.UTF_8)
                            accumulated.append(chunk)
                            onChunk(chunk)
                        }
                    }
                    break
                } else {
                    // Cancellable, non-blocking pause so dismissing the action ends the stream
                    // promptly and we don't park an IO-dispatcher thread in a sleep.
                    delay(50)
                }
            }
            val output = accumulated.toString()
            return if (channel.exitStatus == 0) {
                output
            } else {
                val detail = output.ifBlank { "Command exited with status ${channel.exitStatus}" }
                "SSH Error: command failed (${channel.exitStatus}): $detail"
            }
        } finally {
            // Close only the channel — the pooled session stays for reuse. A jumped session is
            // un-pooled, so tear down both its target and jump connections here.
            channel?.disconnect()
            jumped?.disconnect()
        }
    }

    private fun readExecResult(stdout: InputStream, stderr: InputStream, channel: ChannelExec): String {
        val out = ByteArrayOutputStream()
        val err = ByteArrayOutputStream()
        val buf = ByteArray(4096)
        while (true) {
            var readAny = false
            while (stdout.available() > 0) {
                val n = stdout.read(buf, 0, minOf(stdout.available(), buf.size))
                if (n > 0) {
                    out.write(buf, 0, n)
                    readAny = true
                }
            }
            while (stderr.available() > 0) {
                val n = stderr.read(buf, 0, minOf(stderr.available(), buf.size))
                if (n > 0) {
                    err.write(buf, 0, n)
                    readAny = true
                }
            }
            if (channel.isClosed) {
                while (stdout.available() > 0) {
                    val n = stdout.read(buf, 0, minOf(stdout.available(), buf.size))
                    if (n > 0) out.write(buf, 0, n)
                }
                while (stderr.available() > 0) {
                    val n = stderr.read(buf, 0, minOf(stderr.available(), buf.size))
                    if (n > 0) err.write(buf, 0, n)
                }
                break
            }
            if (!readAny) Thread.sleep(50)
        }
        val combined = buildString {
            append(out.toString(Charsets.UTF_8.name()))
            val errText = err.toString(Charsets.UTF_8.name())
            if (errText.isNotBlank()) {
                if (isNotEmpty() && !endsWith("\n")) append('\n')
                append(errText)
            }
        }
        return if (channel.exitStatus == 0) {
            combined
        } else {
            val detail = combined.ifBlank { "Command exited with status ${channel.exitStatus}" }
            "SSH Error: command failed (${channel.exitStatus}): $detail"
        }
    }

    override suspend fun testConnection(creds: SshCredentials): String? =
        withContext(Dispatchers.IO) {
            var session: Session? = null
            var jumped: JumpedSession? = null
            try {
                val jumpedSession = isJump(creds)
                session = if (jumpedSession) {
                    jumped = buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS)
                    jumped.target
                } else {
                    pool.acquire(creds)
                }
                if (jumpedSession && !session.isConnected) session.connect(CONNECT_TIMEOUT_MS)
                // Prove we can actually run something, not just complete the handshake.
                val channel = session.openChannel("exec") as ChannelExec
                try {
                    channel.setCommand("true")
                    channel.connect(CONNECT_TIMEOUT_MS)
                } finally {
                    channel.disconnect()
                }
                null
            } catch (e: Throwable) {
                e.message ?: "Connection failed"
            } finally {
                // For a jumped session, disconnect both target + jump together.
                jumped?.disconnect()
            }
        }

    override suspend fun openShell(
        creds: SshCredentials,
        cols: Int,
        rows: Int,
        onPhaseChange: ((String) -> Unit)?,
    ): TerminalSession = withContext(Dispatchers.IO) {
        var session: Session? = null
        var jumped: JumpedSession? = null
        var channel: ChannelShell? = null
        try {
            onPhaseChange?.invoke("Resolving host…")
            session = if (isJump(creds)) {
                onPhaseChange?.invoke("Connecting via jump host…")
                jumped = buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS)
                jumped.target
            } else {
                newSession(creds)
            }
            onPhaseChange?.invoke("Handshaking…")
            session.connect(CONNECT_TIMEOUT_MS)
            onPhaseChange?.invoke("Authenticating…")
            channel = (session.openChannel("shell") as ChannelShell).apply {
                setPtyType("xterm-256color")
                setPtySize(cols.coerceAtLeast(1), rows.coerceAtLeast(1), cols * 8, rows * 16)
                setEnv("COLORTERM", "truecolor")
            }
            onPhaseChange?.invoke("Opening channel…")
            val input = channel.inputStream
            val output = channel.outputStream
            channel.connect(CONNECT_TIMEOUT_MS)
            JschTerminalSession(session, channel, input, output, jumped)
        } catch (e: Throwable) {
            channel?.disconnect()
            jumped?.disconnect() ?: session?.disconnect()
            throw SshConnectException(e.message ?: "Failed to open shell", e)
        }
    }

    override fun shutdown() = pool.closeAll()

    private companion object {
        const val CONNECT_TIMEOUT_MS = 15_000
    }
}

/**
 * One persistent PTY shell. A dedicated daemon thread does the blocking reads (JSch streams
 * are blocking) and funnels bytes into a bounded coroutine [Channel]. If the terminal emulator
 * falls behind during very large output, the reader applies backpressure instead of growing memory
 * without limit. [output] exposes that as a [Flow]. Writes are marshalled onto [Dispatchers.IO].
 */
private class JschTerminalSession(
    private val session: Session,
    private val channel: ChannelShell,
    private val shellIn: InputStream,
    private val shellOut: OutputStream,
    // Non-null when reached via an SSH jump host; closed together with this session.
    private val jumped: JumpedSession? = null,
) : TerminalSession {

    private val outChannel = Channel<ByteArray>(OUTPUT_BUFFER_CHUNKS)
    private val _closed = MutableStateFlow(false)
    private val _exitStatus = MutableStateFlow<Int?>(null)

    override val output: Flow<ByteArray> = outChannel.receiveAsFlow()
    override val closed: StateFlow<Boolean> = _closed.asStateFlow()
    override val exitStatus: StateFlow<Int?> = _exitStatus.asStateFlow()

    private val reader = thread(start = true, isDaemon = true, name = "ssh-shell-reader") {
        val buf = ByteArray(8192)
        try {
            while (true) {
                val n = shellIn.read(buf)
                if (n < 0) break
                // trySendBlocking parks this thread when the buffer is full (backpressure — bytes
                // must not be dropped or the emulator's escape-sequence state corrupts) without
                // spinning up a runBlocking event loop per chunk, and fails out cleanly the moment
                // close() closes the channel instead of blocking forever.
                if (n > 0 && outChannel.trySendBlocking(buf.copyOf(n)).isFailure) break
                if (channel.isClosed && shellIn.available() == 0) break
            }
        } catch (_: Throwable) {
            // stream closed / connection dropped — fall through to teardown
        } finally {
            close()
        }
    }

    override suspend fun write(bytes: ByteArray) {
        if (_closed.value) return
        withContext(Dispatchers.IO) {
            try {
                shellOut.write(bytes)
                shellOut.flush()
            } catch (_: Throwable) {
                close()
            }
        }
    }

    override suspend fun resize(cols: Int, rows: Int) {
        if (_closed.value) return
        withContext(Dispatchers.IO) {
            try {
                channel.setPtySize(cols.coerceAtLeast(1), rows.coerceAtLeast(1), cols * 8, rows * 16)
            } catch (_: Throwable) {
                // benign — remote may not honour resize
            }
        }
    }

    override fun close() {
        if (_closed.compareAndSet(expect = false, update = true)) {
            _exitStatus.value = runCatching { channel.exitStatus }.getOrNull()
            try { channel.disconnect() } catch (_: Throwable) {}
            // For a jumped session, tear down target + jump together; otherwise just this session.
            if (jumped != null) jumped.disconnect() else try { session.disconnect() } catch (_: Throwable) {}
            outChannel.close()
        }
    }

    private companion object {
        const val OUTPUT_BUFFER_CHUNKS = 64
    }
}
