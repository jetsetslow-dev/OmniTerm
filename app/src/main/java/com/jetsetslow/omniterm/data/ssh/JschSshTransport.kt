package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.Session
import com.jetsetslow.omniterm.data.term.Utf8StreamDecoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.InputStream
import java.io.OutputStream
import kotlin.concurrent.thread

private const val EXEC_OUTPUT_MAX_CHARS = 240_000

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

    override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
        withContext(Dispatchers.IO) {
            try {
                withTimeout(EXEC_TIMEOUT_MS) { execOnce(creds, command, stdin) }
            } catch (e: TimeoutCancellationException) {
                "SSH Error: command timed out"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // The request may already have reached the server. Evict the suspect transport
                // for the next call, but never retry an arbitrary command and risk executing a
                // mutation twice.
                "SSH Error: ${e.message}"
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
        val lease = pool.acquire(creds)
        val session = lease.session
        var channel: ChannelExec? = null
        return try {
            channel = (session.openChannel("exec") as ChannelExec).apply {
                setCommand(command)
                // Secrets (sudo passwords) travel via the channel's stdin, never the command string.
                setInputStream(stdin?.byteInputStream(Charsets.UTF_8))
            }
            val input = channel.inputStream
            val err = channel.errStream
            channel.connect(CONNECT_TIMEOUT_MS)
            readExecResult(input, err, channel)
        } catch (e: Throwable) {
            pool.evict(creds, session)
            throw e
        } finally {
            channel?.disconnect()
            lease.close()
        }
    }

    /** Un-pooled exec over an SSH jump host: one jump+target session per call, torn down after. */
    private suspend fun execOnceJumped(creds: SshCredentials, command: String, stdin: String? = null): String {
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
            try {
                withTimeout(STREAM_TIMEOUT_MS) { execStreamOnce(creds, command, stdin, onChunk) }
            } catch (e: TimeoutCancellationException) {
                val error = "SSH Error: command timed out"
                onChunk(error)
                error
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // Zero output does not mean the remote command did not run. Preserve at-most-once
                // semantics for destructive streaming actions too.
                val errMsg = "SSH Error: ${e.message}"
                onChunk(errMsg); errMsg
            }
        }
    }

    private suspend fun execStreamOnce(
        creds: SshCredentials,
        command: String,
        stdin: String?,
        onChunk: suspend (String) -> Unit,
    ): String {
        val accumulated = CappedTextBuffer(EXEC_OUTPUT_MAX_CHARS)
        val stdoutDecoder = Utf8StreamDecoder()
        val stderrDecoder = Utf8StreamDecoder()
        // Jump hosts can't be pooled, so they run on a dedicated un-pooled session that is torn
        // down (target + jump) in the finally block; pooled sessions are only channel-closed.
        val jumped = if (isJump(creds)) buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS) else null
        val lease = if (jumped == null) pool.acquire(creds) else null
        val session = jumped?.target?.also { it.connect(CONNECT_TIMEOUT_MS) } ?: checkNotNull(lease).session
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
                var readAny = false
                if (stdoutAvail > 0) {
                    val n = stdoutStream.read(buf, 0, minOf(stdoutAvail, buf.size))
                    if (n > 0) {
                        val chunk = stdoutDecoder.decode(buf.copyOf(n))
                        if (chunk.isNotEmpty()) { accumulated.append(chunk); onChunk(chunk) }
                        readAny = true
                    }
                }
                if (stderrAvail > 0) {
                    val n = stderrStream.read(buf, 0, minOf(stderrAvail, buf.size))
                    if (n > 0) {
                        val chunk = stderrDecoder.decode(buf.copyOf(n))
                        if (chunk.isNotEmpty()) { accumulated.append(chunk); onChunk(chunk) }
                        readAny = true
                    }
                }
                if (channel.isClosed) {
                    // Drain any remaining bytes after the channel-closed signal.
                    while (stdoutStream.available() > 0) {
                        val n = stdoutStream.read(buf, 0, minOf(stdoutStream.available(), buf.size))
                        if (n > 0) {
                            val chunk = stdoutDecoder.decode(buf.copyOf(n))
                            if (chunk.isNotEmpty()) { accumulated.append(chunk); onChunk(chunk) }
                        }
                    }
                    while (stderrStream.available() > 0) {
                        val n = stderrStream.read(buf, 0, minOf(stderrStream.available(), buf.size))
                        if (n > 0) {
                            val chunk = stderrDecoder.decode(buf.copyOf(n))
                            if (chunk.isNotEmpty()) { accumulated.append(chunk); onChunk(chunk) }
                        }
                    }
                    break
                } else if (!readAny) {
                    // Cancellable, non-blocking pause so dismissing the action ends the stream
                    // promptly and we don't park an IO-dispatcher thread in a sleep.
                    delay(50)
                }
            }
            stdoutDecoder.finish().takeIf { it.isNotEmpty() }?.let { accumulated.append(it); onChunk(it) }
            stderrDecoder.finish().takeIf { it.isNotEmpty() }?.let { accumulated.append(it); onChunk(it) }
            val output = accumulated.text()
            return if (channel.exitStatus == 0) {
                output
            } else {
                val detail = output.ifBlank { "Command exited with status ${channel.exitStatus}" }
                "SSH Error: command failed (${channel.exitStatus}): $detail"
            }
        } catch (e: Throwable) {
            if (lease != null) pool.evict(creds, session)
            throw e
        } finally {
            // Close only the channel — the pooled session stays for reuse. A jumped session is
            // un-pooled, so tear down both its target and jump connections here.
            channel?.disconnect()
            jumped?.disconnect()
            lease?.close()
        }
    }

    private suspend fun readExecResult(stdout: InputStream, stderr: InputStream, channel: ChannelExec): String {
        val out = CappedTextBuffer(EXEC_OUTPUT_MAX_CHARS)
        val err = CappedTextBuffer(EXEC_OUTPUT_MAX_CHARS)
        val stdoutDecoder = Utf8StreamDecoder()
        val stderrDecoder = Utf8StreamDecoder()
        val buf = ByteArray(4096)
        while (true) {
            currentCoroutineContext().ensureActive()
            var readAny = false
            while (stdout.available() > 0) {
                val n = stdout.read(buf, 0, minOf(stdout.available(), buf.size))
                if (n > 0) {
                    out.append(stdoutDecoder.decode(buf.copyOf(n)))
                    readAny = true
                }
            }
            while (stderr.available() > 0) {
                val n = stderr.read(buf, 0, minOf(stderr.available(), buf.size))
                if (n > 0) {
                    err.append(stderrDecoder.decode(buf.copyOf(n)))
                    readAny = true
                }
            }
            if (channel.isClosed) {
                while (stdout.available() > 0) {
                    val n = stdout.read(buf, 0, minOf(stdout.available(), buf.size))
                    if (n > 0) out.append(stdoutDecoder.decode(buf.copyOf(n)))
                }
                while (stderr.available() > 0) {
                    val n = stderr.read(buf, 0, minOf(stderr.available(), buf.size))
                    if (n > 0) err.append(stderrDecoder.decode(buf.copyOf(n)))
                }
                break
            }
            if (!readAny) delay(50)
        }
        out.append(stdoutDecoder.finish())
        err.append(stderrDecoder.finish())
        val combined = buildString {
            append(out.text())
            val errText = err.text()
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
                    newSession(creds)
                }
                if (!session.isConnected) session.connect(CONNECT_TIMEOUT_MS)
                // Prove we can actually run something, not just complete the handshake.
                val channel = session.openChannel("exec") as ChannelExec
                try {
                    channel.setCommand("true")
                    channel.connect(CONNECT_TIMEOUT_MS)
                    withTimeout(TEST_COMMAND_TIMEOUT_MS) {
                        while (!channel.isClosed) delay(25)
                    }
                    check(channel.exitStatus == 0) {
                        "Test command exited with status ${channel.exitStatus}"
                    }
                } finally {
                    channel.disconnect()
                }
                null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                e.message ?: "Connection failed"
            } finally {
                // For a jumped session, disconnect both target + jump together.
                jumped?.disconnect() ?: session?.disconnect()
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
        val cancellationHandle = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
            if (cause is CancellationException) {
                runCatching { channel?.disconnect() }
                jumped?.disconnect() ?: runCatching { session?.disconnect() }
            }
        }
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
                // Agent forwarding (ssh -A): lets onward hops from this shell reuse our auth agent.
                if (creds.agentForwarding) runCatching { setAgentForwarding(true) }
            }
            onPhaseChange?.invoke("Opening channel…")
            val input = channel.inputStream
            val output = channel.outputStream
            channel.connect(CONNECT_TIMEOUT_MS)
            JschTerminalSession(session, channel, input, output, jumped).also {
                cancellationHandle?.dispose()
            }
        } catch (e: CancellationException) {
            channel?.disconnect()
            jumped?.disconnect() ?: session?.disconnect()
            throw e
        } catch (e: Throwable) {
            channel?.disconnect()
            jumped?.disconnect() ?: session?.disconnect()
            throw SshConnectException(e.message ?: "Failed to open shell", e)
        }
    }

    override fun shutdown() = pool.closeAll()

    override fun forgetCredentials(creds: SshCredentials) = pool.evict(creds)

    private companion object {
        const val CONNECT_TIMEOUT_MS = 15_000
        const val TEST_COMMAND_TIMEOUT_MS = 10_000L
        const val EXEC_TIMEOUT_MS = 120_000L
        const val STREAM_TIMEOUT_MS = 30 * 60_000L
    }
}

/**
 * Classify how an interactive shell channel ended.
 *
 * A real shell/tmux exit should tear the app session down. A transport loss should keep the app
 * session around and reconnect, especially for tmux-backed sessions where the remote process keeps
 * running. JSch can report channel EOF for both cases, so EOF alone is not strong enough: during a
 * network handoff the socket/session can already be gone and no exit-status will ever arrive.
 */
internal fun classifyTerminalClose(
    remoteEof: Boolean,
    channelIsEof: Boolean,
    sessionConnected: Boolean,
    exitStatus: Int?,
): TerminalCloseClassification {
    val hasRealExitStatus = exitStatus != null && exitStatus >= 0
    val cleanRemoteExit = remoteEof && channelIsEof && (hasRealExitStatus || sessionConnected)
    val normalizedExitStatus = when {
        cleanRemoteExit && !hasRealExitStatus -> 0
        else -> exitStatus
    }
    return TerminalCloseClassification(
        remoteExited = cleanRemoteExit,
        exitStatus = normalizedExitStatus,
    )
}

internal data class TerminalCloseClassification(
    val remoteExited: Boolean,
    val exitStatus: Int?,
)

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
    private val _remoteExited = MutableStateFlow(false)

    override val output: Flow<ByteArray> = outChannel.receiveAsFlow()
    override val closed: StateFlow<Boolean> = _closed.asStateFlow()
    override val exitStatus: StateFlow<Int?> = _exitStatus.asStateFlow()
    override val remoteExited: StateFlow<Boolean> = _remoteExited.asStateFlow()

    // True when the reader loop ended because the remote closed the stream gracefully (EOF), as
    // opposed to us closing the channel from this side or the connection dropping mid-read. A
    // graceful EOF is what `exit` on the remote shell produces, so it must be treated as a clean
    // exit even if JSch hasn't surfaced the numeric exit-status message yet (it often lags the EOF).
    @Volatile private var remoteEof = false

    private val reader = thread(start = true, isDaemon = true, name = "ssh-shell-reader") {
        val buf = ByteArray(8192)
        try {
            while (true) {
                val n = shellIn.read(buf)
                if (n < 0) { remoteEof = true; break }
                // trySendBlocking parks this thread when the buffer is full (backpressure — bytes
                // must not be dropped or the emulator's escape-sequence state corrupts) without
                // spinning up a runBlocking event loop per chunk, and fails out cleanly the moment
                // close() closes the channel instead of blocking forever.
                if (n > 0 && outChannel.trySendBlocking(buf.copyOf(n)).isFailure) break
                if (channel.isClosed && shellIn.available() == 0) { remoteEof = true; break }
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
            // Decide whether this is a CLEAN remote exit (shell `exit` → tear down) or a transport
            // loss (network change/drop → caller should auto-reconnect). These look similar at the
            // stream level — both end the reader loop — so we lean on JSch's channel state:
            //
            //   • Clean `exit`: the remote sends an SSH EOF + an `exit-status` message. JSch marks the
            //     channel isEOF()=true and exitStatus() becomes a real code (≥ 0). That status message
            //     can arrive a few ms AFTER the data EOF, so we briefly poll for it.
            //   • Network loss: the socket dies. exitStatus() stays -1 forever and the channel is NOT
            //     cleanly EOF'd. We must NOT normalise this to 0, or a drop gets mistaken for `exit`
            //     and the session is killed instead of reconnected.
            var status = runCatching { channel.exitStatus }.getOrNull()
            var channelIsEof = runCatching { channel.isEOF }.getOrDefault(false)
            if (remoteEof) {
                var waited = 0
                while (status == -1 && channelIsEof && waited < EXIT_STATUS_SETTLE_MS
                ) {
                    try { Thread.sleep(EXIT_STATUS_POLL_MS.toLong()) } catch (_: InterruptedException) { break }
                    waited += EXIT_STATUS_POLL_MS
                    status = runCatching { channel.exitStatus }.getOrNull()
                    channelIsEof = runCatching { channel.isEOF }.getOrDefault(false)
                }
            }
            val close = classifyTerminalClose(
                remoteEof = remoteEof,
                channelIsEof = channelIsEof,
                sessionConnected = runCatching { session.isConnected }.getOrDefault(false),
                exitStatus = status,
            )
            _remoteExited.value = close.remoteExited
            _exitStatus.value = close.exitStatus
            try { channel.disconnect() } catch (_: Throwable) {}
            // For a jumped session, tear down target + jump together; otherwise just this session.
            if (jumped != null) jumped.disconnect() else try { session.disconnect() } catch (_: Throwable) {}
            outChannel.close()
        }
    }

    private companion object {
        const val OUTPUT_BUFFER_CHUNKS = 64
        // How long to wait for JSch's lagging exit-status message after a graceful remote EOF.
        const val EXIT_STATUS_SETTLE_MS = 250
        const val EXIT_STATUS_POLL_MS = 10
    }
}
