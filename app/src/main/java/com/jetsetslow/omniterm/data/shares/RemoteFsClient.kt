package com.jetsetslow.omniterm.data.shares

import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.data.ssh.JschSftp
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Protocol-agnostic remote filesystem operations, so the Shares browser and the cross-endpoint
 * copy/paste engine work identically over SFTP, SMB, FTP and WebDAV. Paths are absolute,
 * "/"-separated, from the endpoint's root (for SMB: the root of the connected share).
 *
 * Implementations may cache an authenticated connection between calls; callers own the instance
 * and must [close] it when the browsing session or transfer ends.
 */
interface RemoteFsClient : Closeable {
    /** Directory to start browsing at when the caller has no better idea. */
    suspend fun home(): String
    suspend fun list(path: String): List<SftpFile>
    suspend fun mkdir(path: String)
    suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean = false)
    suspend fun delete(path: String, isDirectory: Boolean)
    /** Stream the remote file into [output]; returns bytes copied. Does not close [output]. */
    suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)? = null): Long
    /** Stream [input] to the remote path, overwriting. Does not close [input]. */
    suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)? = null)
    override fun close() {}
}

/** Thrown for protocols we can save/test but not browse (NFS, CUSTOM). */
class UnsupportedShareProtocolException(protocol: String) :
    UnsupportedOperationException("Browsing $protocol shares isn't supported yet — SMB, FTP, SFTP and WebDAV are.")

object ShareClients {
    /**
     * Build a client for [share] with credentials already resolved (profile lookup + decryption is
     * the caller's job). For SMB the first segment of [NetworkShareEntity.sharePath] is the share
     * name; everything after it is just a starting directory (see [startPath]).
     */
    fun forShare(share: NetworkShareEntity, username: String, password: String): RemoteFsClient =
        when (share.protocol.uppercase(Locale.ROOT)) {
            "SMB" -> SmbFsClient(
                host = share.address,
                port = share.port,
                shareName = smbShareName(share)
                    ?: throw IllegalArgumentException("SMB needs a share name — set Share/path (e.g. \"Public\")."),
                domain = share.workgroup,
                username = username,
                password = password,
                anonymous = share.anonymous,
            )
            "FTP" -> FtpFsClient(share.address, share.port, username, password, share.anonymous)
            "WEBDAV" -> WebDavFsClient(
                host = share.address,
                port = share.port,
                https = share.useHttps,
                username = username,
                password = password,
                anonymous = share.anonymous,
            )
            "SFTP" -> JschSftp(SshCredentials(share.address, share.port, username, password = password))
            else -> throw UnsupportedShareProtocolException(share.protocol)
        }

    /** Directory the browser should open first; falls back to the client's [RemoteFsClient.home]. */
    suspend fun startPath(share: NetworkShareEntity, client: RemoteFsClient): String {
        val configured = share.sharePath.trim('/')
        return when (share.protocol.uppercase(Locale.ROOT)) {
            // First segment is the share name and already consumed by the connection.
            "SMB" -> "/" + configured.split('/').drop(1).filter { it.isNotEmpty() }.joinToString("/")
            else -> if (configured.isBlank()) client.home() else "/$configured"
        }
    }

    fun smbShareName(share: NetworkShareEntity): String? =
        share.sharePath.trim('/').split('/').firstOrNull()?.takeIf { it.isNotBlank() }
}

private val fsModDateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)

internal fun formatFsDate(epochMillis: Long): String =
    if (epochMillis <= 0L) "" else fsModDateFormat.format(Date(epochMillis))

/**
 * Pump [input] into [output] with the same throttled progress cadence JschSftp uses (every 64 KiB
 * or 150 ms), so transfer rows update smoothly without flooding the main thread.
 */
internal fun copyWithProgress(
    input: InputStream,
    output: OutputStream,
    totalBytes: Long,
    onProgress: ((Long, Long) -> Unit)?,
): Long {
    onProgress?.invoke(0L, totalBytes)
    val buffer = ByteArray(64 * 1024)
    var copied = 0L
    var lastReportedBytes = 0L
    var lastReportedAt = System.currentTimeMillis()
    while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        output.write(buffer, 0, read)
        copied += read
        if (onProgress != null) {
            val now = System.currentTimeMillis()
            if (copied - lastReportedBytes >= 64 * 1024 || now - lastReportedAt >= 150) {
                lastReportedBytes = copied
                lastReportedAt = now
                onProgress(copied, totalBytes)
            }
        }
    }
    onProgress?.invoke(copied, if (totalBytes > 0) totalBytes else copied)
    return copied
}
