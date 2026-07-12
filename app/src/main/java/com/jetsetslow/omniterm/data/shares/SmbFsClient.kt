package com.jetsetslow.omniterm.data.shares

import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.jetsetslow.omniterm.data.SftpFile
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.EnumSet
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * SMB2/3 client over smbj, scoped to a single share ([shareName]). Paths are "/"-separated from
 * the share root and converted to the backslash form SMB expects.
 *
 * The authenticated connection + tree connect is cached across calls (it's the expensive part —
 * negotiate, session setup, tree connect are several round-trips), guarded by a [Mutex] because
 * one instance serves one browsing session or one transfer at a time. A dropped connection is
 * evicted and rebuilt once per call, mirroring JschSftp's pooled-channel retry.
 */
class SmbFsClient(
    private val host: String,
    private val port: Int,
    private val shareName: String,
    private val domain: String,
    private val username: String,
    private val password: String,
    private val anonymous: Boolean,
) : RemoteFsClient {

    private val config = SmbConfig.builder()
        .withTimeout(15, TimeUnit.SECONDS)
        .withSoTimeout(30, TimeUnit.SECONDS)
        .build()

    private val lock = Mutex()
    private var client: SMBClient? = null
    private var connection: Connection? = null
    private var session: Session? = null
    private var share: DiskShare? = null

    private fun auth(): AuthenticationContext =
        if (anonymous || (username.isBlank() && password.isBlank())) AuthenticationContext.guest()
        else AuthenticationContext(username, password.toCharArray(), domain.ifBlank { null })

    private fun connectLocked(): DiskShare {
        share?.takeIf { it.isConnected }?.let { return it }
        teardownLocked()
        val c = SMBClient(config).also { client = it }
        val conn = c.connect(host, if (port > 0) port else SMBClient.DEFAULT_PORT).also { connection = it }
        val sess = conn.authenticate(auth()).also { session = it }
        val s = sess.connectShare(shareName) as? DiskShare
            ?: throw IOException("\\\\$host\\$shareName is not a disk share.")
        share = s
        return s
    }

    private fun teardownLocked() {
        runCatching { share?.close() }
        runCatching { session?.close() }
        runCatching { connection?.close() }
        runCatching { client?.close() }
        share = null; session = null; connection = null; client = null
    }

    /**
     * [retryOnDeadTransport] must be false for streaming transfers: their caller-owned streams are
     * already partially written/consumed when the transport dies, so re-running [block] would
     * silently duplicate downloaded bytes or upload only the leftover tail.
     */
    private suspend fun <T> withShare(retryOnDeadTransport: Boolean = true, block: (DiskShare) -> T): T = withContext(Dispatchers.IO) {
        lock.withLock {
            var attempt = 0
            while (true) {
                val s = connectLocked()
                try {
                    return@withLock block(s)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Only a dead transport warrants rebuild+retry; SMB status errors (access
                    // denied, not found) must surface as-is without burning the warm session.
                    val transportDead = !s.isConnected || e is IOException
                    teardownLocked()
                    if (retryOnDeadTransport && transportDead && attempt++ < 1) continue
                    throw e
                }
            }
            @Suppress("UNREACHABLE_CODE")
            throw IllegalStateException("unreachable")
        }
    }

    private fun smbPath(path: String): String = path.trim('/').replace('/', '\\')

    override suspend fun home(): String = "/"

    override suspend fun list(path: String): List<SftpFile> = withShare { s ->
        s.list(smbPath(path))
            .filter { it.fileName != "." && it.fileName != ".." }
            .map { info ->
                val isDir = info.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L
                val modMillis = info.lastWriteTime?.toEpochMillis() ?: 0L
                SftpFile(
                    name = info.fileName,
                    isDirectory = isDir,
                    size = if (isDir) 0L else info.endOfFile,
                    modDate = formatFsDate(modMillis),
                    modTimeSeconds = modMillis / 1000,
                )
            }
    }

    override suspend fun mkdir(path: String) { withShare { it.mkdir(smbPath(path)) } }

    override suspend fun rename(oldPath: String, newPath: String) {
        withShare { s ->
            val old = smbPath(oldPath)
            val isDir = s.folderExists(old)
            val access = EnumSet.of(AccessMask.DELETE, AccessMask.GENERIC_READ)
            val entry = if (isDir) {
                s.openDirectory(old, access, null, SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, null)
            } else {
                s.openFile(old, access, null, SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, null)
            }
            entry.use { it.rename(smbPath(newPath), true) }
        }
    }

    override suspend fun delete(path: String, isDirectory: Boolean) {
        withShare { s -> if (isDirectory) s.rmdir(smbPath(path), false) else s.rm(smbPath(path)) }
    }

    override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?): Long =
        withShare(retryOnDeadTransport = false) { s ->
            val p = smbPath(path)
            val total = runCatching { s.getFileInformation(p).standardInformation.endOfFile }.getOrDefault(0L)
            s.openFile(
                p, EnumSet.of(AccessMask.GENERIC_READ), null,
                SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, null,
            ).use { file ->
                file.inputStream.use { input -> copyWithProgress(input, output, total, onProgress) }
            }
        }

    override suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)?) {
        withShare(retryOnDeadTransport = false) { s ->
            s.openFile(
                smbPath(path), EnumSet.of(AccessMask.GENERIC_WRITE), null,
                SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OVERWRITE_IF, null,
            ).use { file ->
                file.outputStream.use { out -> copyWithProgress(input, out, totalBytes, onProgress) }
            }
        }
    }

    override fun close() {
        // Best-effort teardown without suspending; safe because close is called after the last op.
        teardownLocked()
    }
}
