package com.jetsetslow.omniterm.data.ssh

import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.data.shares.RemoteFsClient
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.SftpProgressMonitor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * Real SFTP operations over JSch's `sftp` channel (Android / JVM only).
 *
 * Performance: authenticating an SSH session (RSA/ed25519 + multiple round-trips) is the expensive
 * part of every SFTP call, and it dominates on high-latency links. We therefore keep the
 * authenticated [Session] warm in a shared [SshSessionPool] and open only a lightweight `sftp`
 * channel per operation (one round-trip on an already-open connection). Navigating between folders
 * then costs a single channel open + `ls`, not a full handshake — the difference between "instant"
 * and "several seconds" on a remote host.
 *
 * Each operation gets its own short-lived channel so a long transfer never blocks a folder listing
 * on the same connection. Jump-host sessions are not pooled (see [buildJumpedJschSession]).
 */
class JschSftp(private val creds: SshCredentials) : RemoteFsClient {

    private val isJump: Boolean =
        creds.proxyType == "ssh" && creds.proxyHost.isNotBlank() && creds.proxyPort > 0

    private suspend fun <T> withChannel(
        retryBlockOnStaleSession: Boolean = false,
        timeoutMs: Long = METADATA_OPERATION_TIMEOUT_MS,
        block: (ChannelSftp) -> T,
    ): T = withTimeout(timeoutMs) {
        if (isJump) withContext(Dispatchers.IO) { withJumpedChannel(block) }
        else withPooledChannel(retryBlockOnStaleSession, block)
    }

    /**
     * Reuse a warm authenticated session from the pool; open a fresh channel per call. Both the
     * (potential) session handshake and the channel work run on [Dispatchers.IO] — never the caller's
     * (UI) thread — since [SshSessionPool.acquire] may dial+authenticate a brand-new connection.
     *
     * A stale pooled session usually fails at channel open — before [block] has done anything —
     * and that phase is always evict-and-retried once. Failures *inside* [block] retry only when
     * [retryBlockOnStaleSession] allows it: streaming transfers must pass false, because their
     * caller-owned streams are already partially written/consumed, and re-running the block would
     * silently duplicate downloaded bytes or upload only the leftover tail.
     */
    private suspend fun <T> withPooledChannel(retryBlockOnStaleSession: Boolean, block: (ChannelSftp) -> T): T = withContext(Dispatchers.IO) {
        var attempt = 0
        while (true) {
            val lease = pool.acquire(creds)
            val session = lease.session
            val channel: ChannelSftp = try {
                (session.openChannel("sftp") as ChannelSftp).also { it.connect(CONNECT_TIMEOUT_MS) }
            } catch (e: CancellationException) {
                lease.close()
                throw e
            } catch (e: Exception) {
                if (!session.isConnected) {
                    pool.evict(creds, session)
                    if (attempt++ < 1) {
                        lease.close()
                        continue
                    }
                }
                lease.close()
                throw e
            }
            val cancellationHandle = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
                if (cause is CancellationException) runCatching { channel.disconnect() }
            }
            try {
                return@withContext block(channel)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Only a dropped/stale session warrants eviction + one reconnect; a logical error
                // (e.g. "No such file") must NOT throw away the warm session — rethrow it as-is.
                if (!session.isConnected) {
                    pool.evict(creds, session)
                    if (retryBlockOnStaleSession && attempt++ < 1) continue
                }
                throw e
            } finally {
                cancellationHandle?.dispose()
                channel.disconnect()
                lease.close()
            }
        }
        @Suppress("UNREACHABLE_CODE")
        throw IllegalStateException("withPooledChannel loop exited unexpectedly")
    }

    /** Jump hosts can't be pooled: build a dedicated tunnelled session per call and tear it down. */
    private suspend fun <T> withJumpedChannel(block: (ChannelSftp) -> T): T {
        var jumped: JumpedSession? = null
        var channel: ChannelSftp? = null
        val cancellationHandle = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
            if (cause is CancellationException) {
                runCatching { channel?.disconnect() }
                jumped?.disconnect()
            }
        }
        try {
            val session = buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS).also { jumped = it }.target
            session.connect(CONNECT_TIMEOUT_MS)
            channel = (session.openChannel("sftp") as ChannelSftp).also { it.connect(CONNECT_TIMEOUT_MS) }
            return block(channel)
        } finally {
            cancellationHandle?.dispose()
            channel?.disconnect()
            jumped?.disconnect()
        }
    }

    override suspend fun list(path: String): List<SftpFile> = withChannel(retryBlockOnStaleSession = true) { ch ->
        val target = path.ifBlank { ch.pwd() ?: "/" }
        @Suppress("UNCHECKED_CAST")
        val entries = ch.ls(target) as java.util.Vector<ChannelSftp.LsEntry>
        entries
            .filter { it.filename != "." && it.filename != ".." }
            .map { e ->
                val attrs = e.attrs
                SftpFile(
                    name = e.filename,
                    isDirectory = attrs.isDir,
                    size = attrs.size,
                    modDate = attrs.mtimeString?.trim().orEmpty(),
                    modTimeSeconds = attrs.mTime.toLong(),
                )
            }
    }

    /** Resolve the absolute home/working directory to start the browser at. */
    override suspend fun home(): String = withChannel(retryBlockOnStaleSession = true) { ch -> ch.pwd() ?: "/" }

    override suspend fun mkdir(path: String) { withChannel { ch -> ch.mkdir(path) } }

    override suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean) { withChannel { ch -> ch.rename(oldPath, newPath) } }

    override suspend fun delete(path: String, isDirectory: Boolean): Unit = withChannel { ch ->
        if (isDirectory) ch.rmdir(path) else ch.rm(path)
    }

    suspend fun readText(path: String, maxBytes: Int = 512 * 1024): String = withChannel(retryBlockOnStaleSession = true) { ch ->
        ch.get(path).use { input ->
            // Stop reading at the cap instead of buffering the whole file first — opening a
            // multi-GB file for editing must cost at most maxBytes of memory, not the file size.
            val out = java.io.ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (out.size() < maxBytes) {
                val read = input.read(buffer, 0, minOf(buffer.size, maxBytes - out.size()))
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            String(out.toByteArray(), Charsets.UTF_8)
        }
    }

    /**
     * Write [content] to [path] and confirm persistence by reading back the remote size. Returns the
     * number of bytes the remote reports for the file after the write; callers compare it against the
     * expected length to prove the edit actually landed. Throws on a transport/permission failure.
     */
    suspend fun writeText(path: String, content: String): Long = withChannel { ch ->
        val bytes = content.toByteArray(Charsets.UTF_8)
        ByteArrayInputStream(bytes).use { input ->
            ch.put(input, path, ChannelSftp.OVERWRITE)
        }
        runCatching { ch.lstat(path).size }.getOrDefault(-1L)
    }

    /** Upload a stream without buffering the whole local file in memory. */
    override suspend fun uploadStream(
        path: String,
        input: InputStream,
        totalBytes: Long,
        onProgress: ((Long, Long) -> Unit)?,
    ) {
        val job = currentCoroutineContext()[Job]
        withChannel(retryBlockOnStaleSession = false, timeoutMs = TRANSFER_TIMEOUT_MS) { ch ->
            ch.put(input, path, progressMonitor(totalBytes, onProgress, job), ChannelSftp.OVERWRITE)
        }
    }

    // Deliberately no whole-file ByteArray download/upload helpers: every transfer path must
    // stream, so a multi-GB file can never be pulled into the heap by accident.

    /** Stream a remote file into [output] without closing the caller-owned output stream. */
    override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?): Long {
        val job = currentCoroutineContext()[Job]
        return withChannel(retryBlockOnStaleSession = false, timeoutMs = TRANSFER_TIMEOUT_MS) { ch ->
        val total = runCatching { ch.lstat(path).size }.getOrDefault(0L)
        var copied = 0L
        ch.get(path, progressMonitor(total, onProgress, job)).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                output.write(buffer, 0, read)
                copied += read
            }
        }
        copied
        }
    }

    private fun progressMonitor(
        totalBytes: Long,
        onProgress: ((Long, Long) -> Unit)?,
        job: Job?,
    ): SftpProgressMonitor? {
        if (onProgress == null) return null
        return object : SftpProgressMonitor {
            private var transferred = 0L
            private var lastReportedBytes = 0L
            private var lastReportedAt = 0L
            override fun init(op: Int, src: String?, dest: String?, max: Long) {
                transferred = 0L
                lastReportedBytes = 0L
                lastReportedAt = System.currentTimeMillis()
                onProgress(0L, if (totalBytes > 0) totalBytes else max)
            }
            override fun count(count: Long): Boolean {
                if (job?.isCancelled == true) return false
                transferred += count
                val now = System.currentTimeMillis()
                if (transferred - lastReportedBytes >= PROGRESS_REPORT_BYTES || now - lastReportedAt >= PROGRESS_REPORT_MS) {
                    lastReportedBytes = transferred
                    lastReportedAt = now
                    onProgress(transferred, totalBytes)
                }
                return true
            }
            override fun end() {
                onProgress(if (totalBytes > 0) totalBytes else transferred, totalBytes)
            }
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val METADATA_OPERATION_TIMEOUT_MS = 2 * 60_000L
        private const val TRANSFER_TIMEOUT_MS = 6 * 60 * 60_000L
        private const val PROGRESS_REPORT_BYTES = 64 * 1024L
        private const val PROGRESS_REPORT_MS = 150L

        /**
         * Sessions are keyed by full credentials, so this pool is safely shared across every
         * [JschSftp] instance for the lifetime of the process. Browsing one host keeps that host's
         * session warm; the editor, transfers and folder listings all reuse it.
         */
        private val pool = SshSessionPool(CONNECT_TIMEOUT_MS)

        /** Disconnect and forget every pooled SFTP session. Call when the owning ViewModel is cleared. */
        fun shutdownPool() = pool.closeAll()

        /** Drop one host's cached SFTP transport after its host or credentials are removed. */
        fun forgetCredentials(creds: SshCredentials) = pool.evict(creds)
    }
}
