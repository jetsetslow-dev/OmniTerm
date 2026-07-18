package com.jetsetslow.omniterm.data.shares

import com.jetsetslow.omniterm.data.SftpFile
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.apache.commons.net.ftp.FTPReply

/**
 * FTP client over commons-net. The logged-in control connection is cached across calls (login is
 * the slow part) behind a [Mutex]; a dead connection is rebuilt once per call. Anonymous shares
 * log in as `anonymous`. Transfers always run in binary mode over passive data connections
 * (passive works through NAT/mobile networks where active FTP can't).
 */
class FtpFsClient(
    private val host: String,
    private val port: Int,
    private val username: String,
    private val password: String,
    private val anonymous: Boolean,
) : RemoteFsClient {

    private val lock = Mutex()
    private var ftp: FTPClient? = null
    private val transferClients = java.util.concurrent.ConcurrentHashMap.newKeySet<FTPClient>()

    private fun connectLocked(): FTPClient {
        ftp?.let { existing ->
            if (existing.isConnected && runCatching { existing.sendNoOp() }.getOrDefault(false)) return existing
        }
        teardownLocked()
        return dial().also { ftp = it }
    }

    /** Fresh logged-in binary/passive connection; the socket never outlives a failed setup step. */
    private fun dial(): FTPClient {
        val client = FTPClient()
        client.controlEncoding = "UTF-8"
        client.connectTimeout = 10_000
        client.defaultTimeout = 15_000
        client.connect(host, if (port > 0) port else 21)
        try {
            client.soTimeout = 30_000
            if (!FTPReply.isPositiveCompletion(client.replyCode)) {
                throw IOException("FTP server refused connection: ${client.replyString?.trim()}")
            }
            val user = if (anonymous || username.isBlank()) "anonymous" else username
            val pass = if (anonymous || username.isBlank()) "guest@omniterm.app" else password
            if (!client.login(user, pass)) {
                throw IOException("FTP login failed: ${client.replyString?.trim()}")
            }
            client.enterLocalPassiveMode()
            if (!client.setFileType(FTP.BINARY_FILE_TYPE)) throw IOException("FTP server rejected binary mode.")
        } catch (e: Exception) {
            runCatching { client.disconnect() }
            throw e
        }
        return client
    }

    private fun teardownLocked() {
        ftp?.let { c ->
            runCatching { if (c.isConnected) c.logout() }
            runCatching { if (c.isConnected) c.disconnect() }
        }
        ftp = null
    }

    private suspend fun <T> withFtp(block: (FTPClient) -> T): T = withContext(Dispatchers.IO) {
        lock.withLock {
            var attempt = 0
            while (true) {
                val client = connectLocked()
                try {
                    return@withLock block(client)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Data-connection failures leave the control channel in an undefined state, so
                    // always rebuild; retry only when the transport itself died mid-command.
                    val transportDead = !client.isConnected
                    teardownLocked()
                    if (transportDead && attempt++ < 1) continue
                    throw e
                }
            }
            @Suppress("UNREACHABLE_CODE")
            throw IllegalStateException("unreachable")
        }
    }

    /**
     * Transfers run on their own dedicated connection: FTP can't multiplex one control channel,
     * so going through [withFtp]'s lock would park every directory listing behind a long
     * download/upload. No retry either — the caller-owned streams are already partially
     * written/consumed when a transfer dies, and re-running [block] would silently duplicate
     * downloaded bytes or upload only the leftover tail.
     */
    private suspend fun <T> withTransferFtp(block: (FTPClient) -> T): T = withContext(Dispatchers.IO) {
        val client = dial()
        transferClients += client
        try {
            block(client)
        } finally {
            transferClients -= client
            runCatching { if (client.isConnected) client.logout() }
            runCatching { if (client.isConnected) client.disconnect() }
        }
    }

    /** Fail with the server's own reply text instead of a boolean, so the UI can show a reason. */
    private fun FTPClient.check(ok: Boolean, action: String) {
        if (!ok) throw IOException("FTP $action failed: ${replyString?.trim().orEmpty().ifBlank { "no server reply" }}")
    }

    override suspend fun home(): String = withFtp { it.printWorkingDirectory() ?: "/" }

    override suspend fun list(path: String): List<SftpFile> = withFtp { client ->
        val files = client.listFiles(path.ifBlank { "/" })
            ?: throw IOException("FTP list failed: ${client.replyString?.trim()}")
        files
            .filter { it.name != "." && it.name != ".." }
            .map { f ->
                val modMillis = f.timestamp?.timeInMillis ?: 0L
                SftpFile(
                    name = f.name,
                    isDirectory = f.isDirectory,
                    size = if (f.isDirectory) 0L else f.size.coerceAtLeast(0L),
                    modDate = formatFsDate(modMillis),
                    modTimeSeconds = modMillis / 1000,
                )
            }
    }

    override suspend fun mkdir(path: String) {
        withFtp { it.check(it.makeDirectory(path), "mkdir") }
    }

    override suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean) {
        withFtp { it.check(it.rename(oldPath, newPath), "rename") }
    }

    override suspend fun delete(path: String, isDirectory: Boolean) {
        withFtp {
            if (isDirectory) it.check(it.removeDirectory(path), "rmdir")
            else it.check(it.deleteFile(path), "delete")
        }
    }

    override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?): Long =
        withTransferFtp { client ->
            val total = runCatching { client.mlistFile(path)?.size ?: 0L }.getOrDefault(0L)
            val input = client.retrieveFileStream(path)
                ?: throw IOException("FTP download failed: ${client.replyString?.trim()}")
            val copied = input.use { copyWithProgress(it, output, total, onProgress) }
            client.check(client.completePendingCommand(), "download")
            copied
        }

    override suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)?) {
        withTransferFtp { client ->
            val out = client.storeFileStream(path)
                ?: throw IOException("FTP upload failed: ${client.replyString?.trim()}")
            out.use { copyWithProgress(input, it, totalBytes, onProgress) }
            client.check(client.completePendingCommand(), "upload")
        }
    }

    override fun close() {
        teardownLocked()
    }

    override fun cancelActiveTransfers() {
        transferClients.toList().forEach { client -> runCatching { client.disconnect() } }
    }
}
