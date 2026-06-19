package com.jetsetslow.omniterm.data.ssh

import com.jetsetslow.omniterm.data.SftpFile
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.SftpProgressMonitor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
class JschSftp(private val creds: SshCredentials) {

    private val isJump: Boolean =
        creds.proxyType == "ssh" && creds.proxyHost.isNotBlank() && creds.proxyPort > 0

    private suspend fun <T> withChannel(block: (ChannelSftp) -> T): T =
        if (isJump) withContext(Dispatchers.IO) { withJumpedChannel(block) } else withPooledChannel(block)

    /**
     * Reuse a warm authenticated session from the pool; open a fresh channel per call. Both the
     * (potential) session handshake and the channel work run on [Dispatchers.IO] — never the caller's
     * (UI) thread — since [SshSessionPool.acquire] may dial+authenticate a brand-new connection.
     */
    private suspend fun <T> withPooledChannel(block: (ChannelSftp) -> T): T = withContext(Dispatchers.IO) {
        var attempt = 0
        while (true) {
            val session = pool.acquire(creds)
            var channel: ChannelSftp? = null
            try {
                channel = (session.openChannel("sftp") as ChannelSftp).also { it.connect(CONNECT_TIMEOUT_MS) }
                return@withContext block(channel)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Only a dropped/stale session warrants eviction + one reconnect; a logical error
                // (e.g. "No such file") must NOT throw away the warm session — rethrow it as-is.
                if (!session.isConnected && attempt++ < 1) {
                    pool.evict(creds)
                } else {
                    if (!session.isConnected) pool.evict(creds)
                    throw e
                }
            } finally {
                channel?.disconnect()
            }
            // Reached only after a stale-session eviction above: loop to rebuild + retry once.
        }
        @Suppress("UNREACHABLE_CODE")
        throw IllegalStateException("withPooledChannel loop exited unexpectedly")
    }

    /** Jump hosts can't be pooled: build a dedicated tunnelled session per call and tear it down. */
    private fun <T> withJumpedChannel(block: (ChannelSftp) -> T): T {
        var jumped: JumpedSession? = null
        var channel: ChannelSftp? = null
        try {
            val session = buildJumpedJschSession(creds, CONNECT_TIMEOUT_MS).also { jumped = it }.target
            session.connect(CONNECT_TIMEOUT_MS)
            channel = (session.openChannel("sftp") as ChannelSftp).also { it.connect(CONNECT_TIMEOUT_MS) }
            return block(channel)
        } finally {
            channel?.disconnect()
            jumped?.disconnect()
        }
    }

    suspend fun list(path: String): List<SftpFile> = withChannel { ch ->
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
    suspend fun home(): String = withChannel { ch -> ch.pwd() ?: "/" }

    suspend fun mkdir(path: String) = withChannel { ch -> ch.mkdir(path) }

    suspend fun rename(oldPath: String, newPath: String) = withChannel { ch -> ch.rename(oldPath, newPath) }

    suspend fun delete(path: String, isDirectory: Boolean) = withChannel { ch ->
        if (isDirectory) ch.rmdir(path) else ch.rm(path)
    }

    suspend fun readText(path: String, maxBytes: Int = 512 * 1024): String = withChannel { ch ->
        ch.get(path).use { input ->
            val bytes = input.readBytes()
            val slice = if (bytes.size > maxBytes) bytes.copyOf(maxBytes) else bytes
            String(slice, Charsets.UTF_8)
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

    /** Upload raw bytes (e.g. a local file picked via SAF) to [path] on the remote. */
    suspend fun upload(path: String, bytes: ByteArray, onProgress: ((Long, Long) -> Unit)? = null) = withChannel { ch ->
        ByteArrayInputStream(bytes).use { input ->
            ch.put(input, path, progressMonitor(bytes.size.toLong(), onProgress), ChannelSftp.OVERWRITE)
        }
    }

    /** Upload a stream without buffering the whole local file in memory. */
    suspend fun uploadStream(
        path: String,
        input: InputStream,
        totalBytes: Long,
        onProgress: ((Long, Long) -> Unit)? = null,
    ) = withChannel { ch ->
        ch.put(input, path, progressMonitor(totalBytes, onProgress), ChannelSftp.OVERWRITE)
    }

    /** Download the full remote file at [path] as raw bytes. */
    suspend fun download(path: String, onProgress: ((Long, Long) -> Unit)? = null): ByteArray = withChannel { ch ->
        val total = runCatching { ch.lstat(path).size }.getOrDefault(0L)
        ch.get(path, progressMonitor(total, onProgress)).use { it.readBytes() }
    }

    /** Stream a remote file into [output] without closing the caller-owned output stream. */
    suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)? = null): Long = withChannel { ch ->
        val total = runCatching { ch.lstat(path).size }.getOrDefault(0L)
        var copied = 0L
        ch.get(path, progressMonitor(total, onProgress)).use { input ->
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

    private fun progressMonitor(totalBytes: Long, onProgress: ((Long, Long) -> Unit)?): SftpProgressMonitor? {
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
    }
}
