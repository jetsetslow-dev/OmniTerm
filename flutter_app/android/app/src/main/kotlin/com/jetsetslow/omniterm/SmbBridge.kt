package com.jetsetslow.omniterm

import android.os.Handler
import android.os.Looper
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
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * SMB2/3 for the Dart side, over smbj.
 *
 * Ported from `data/shares/SmbFsClient.kt` in the Kotlin app, which is the same library and the same
 * connection-caching and retry behaviour. What is new is the boundary: sessions are handles the Dart
 * side owns, so two shares can be browsed at once and a copy between them works.
 */
object SmbBridge {
    private const val METHOD_CHANNEL = "omniterm/smb"
    private const val EVENT_CHANNEL = "omniterm/smb/transfers"

    /** 64 KB: large enough that the channel round-trip is not the bottleneck, small enough that a
     *  transfer's progress moves visibly and cancelling takes effect promptly. */
    private const val CHUNK_BYTES = 64 * 1024

    private val sessions = ConcurrentHashMap<String, SmbSession>()
    private val uploads = ConcurrentHashMap<String, OutputStream>()

    /** All SMB I/O is blocking; none of it may touch the platform thread. */
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            io.execute { handle(call, result) }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(DownloadStreamHandler)
    }

    private fun reply(result: MethodChannel.Result, value: Any?) = main.post { result.success(value) }

    private fun fail(result: MethodChannel.Result, e: Exception) = main.post {
        // "transport" is the one code the Dart side acts on: it drops the cached session so the next
        // call reconnects. A protocol error (access denied, not found) must NOT be classified this
        // way, or a permissions problem would silently tear down a perfectly good connection.
        val code = if (e is IOException) "transport" else "smb"
        result.error(code, e.message ?: e.javaClass.simpleName, null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isSupported" -> reply(result, true)
                "connect" -> reply(result, connect(call))
                "list" -> reply(result, session(call).list(call.argument<String>("path").orEmpty()))
                "mkdir" -> {
                    session(call).mkdir(call.argument<String>("path").orEmpty())
                    reply(result, true)
                }
                "rename" -> {
                    session(call).rename(
                        call.argument<String>("from").orEmpty(),
                        call.argument<String>("to").orEmpty(),
                        call.argument<Boolean>("isDirectory") ?: false,
                    )
                    reply(result, true)
                }
                "delete" -> {
                    session(call).delete(
                        call.argument<String>("path").orEmpty(),
                        call.argument<Boolean>("isDirectory") ?: false,
                    )
                    reply(result, true)
                }
                "uploadBegin" -> {
                    val key = transferKey(call)
                    uploads[key] = session(call).openForWrite(call.argument<String>("path").orEmpty())
                    reply(result, true)
                }
                "uploadChunk" -> {
                    val stream = uploads[transferKey(call)]
                        ?: throw IOException("That upload is no longer open.")
                    stream.write(call.argument<ByteArray>("bytes") ?: ByteArray(0))
                    reply(result, true)
                }
                "uploadEnd" -> {
                    uploads.remove(transferKey(call))?.close()
                    reply(result, true)
                }
                "uploadAbort" -> {
                    // Closed rather than left dangling: an abandoned handle keeps a truncated file
                    // locked open on the share until the whole session drops.
                    runCatching { uploads.remove(transferKey(call))?.close() }
                    reply(result, true)
                }
                "disconnect" -> {
                    sessions.remove(call.argument<String>("session"))?.close()
                    reply(result, true)
                }
                else -> main.post { result.notImplemented() }
            }
        } catch (e: Exception) {
            fail(result, e)
        }
    }

    private fun transferKey(call: MethodCall) =
        "${call.argument<String>("session")}/${call.argument<String>("transfer")}"

    private fun session(call: MethodCall): SmbSession =
        sessions[call.argument<String>("session")]
            ?: throw IOException("That share connection is no longer open.")

    private fun connect(call: MethodCall): String {
        val session = SmbSession(
            host = call.argument<String>("host").orEmpty(),
            port = call.argument<Int>("port") ?: 0,
            shareName = call.argument<String>("share").orEmpty(),
            domain = call.argument<String>("domain").orEmpty(),
            username = call.argument<String>("username").orEmpty(),
            password = call.argument<String>("password").orEmpty(),
            anonymous = call.argument<Boolean>("anonymous") ?: false,
        )
        // Connected eagerly so a bad host, share name or credential is reported by the action the
        // user just took, rather than by whatever screen happens to list a directory first.
        session.connect()
        val id = UUID.randomUUID().toString()
        sessions[id] = session
        return id
    }

    /** Streams one download's chunks; the arguments name the session, transfer and path. */
    private object DownloadStreamHandler : EventChannel.StreamHandler {
        private val running = ConcurrentHashMap<String, Thread>()

        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            @Suppress("UNCHECKED_CAST")
            val args = arguments as? Map<String, Any?> ?: return
            val sessionId = args["session"] as? String ?: return
            val transferId = args["transfer"] as? String ?: return
            val path = args["path"] as? String ?: return
            val session = sessions[sessionId] ?: run {
                main.post { events.error("transport", "That share connection is no longer open.", null) }
                return
            }

            val thread = Thread {
                try {
                    session.download(path) { bytes, total, done ->
                        main.post {
                            events.success(
                                mapOf(
                                    "transfer" to transferId,
                                    "bytes" to bytes,
                                    "total" to total,
                                    "done" to done,
                                )
                            )
                        }
                    }
                    // The transfer-scoped `done` message is the terminator. Do not also call
                    // endOfStream(): this EventChannel name is shared by sequential downloads, so
                    // a delayed end event from read A can land after read B has subscribed and end
                    // B before its first chunk. Dart cancels this subscription as soon as it sees
                    // `done`; failures still use events.error below.
                } catch (e: InterruptedException) {
                    // Cancelled by onCancel; the Dart side is already tearing the transfer down.
                } catch (e: Exception) {
                    val code = if (e is IOException) "transport" else "smb"
                    main.post { events.error(code, e.message ?: e.javaClass.simpleName, null) }
                } finally {
                    running.remove(transferId)
                }
            }
            running[transferId] = thread
            thread.start()
        }

        override fun onCancel(arguments: Any?) {
            @Suppress("UNCHECKED_CAST")
            val args = arguments as? Map<String, Any?>
            val transferId = args?.get("transfer") as? String ?: return
            // Interrupted so a cancelled download stops pulling bytes off the wire, rather than
            // running to completion into a sink nobody is reading.
            running.remove(transferId)?.interrupt()
        }
    }

    /** One authenticated connection + tree connect, kept warm. */
    private class SmbSession(
        private val host: String,
        private val port: Int,
        private val shareName: String,
        private val domain: String,
        private val username: String,
        private val password: String,
        private val anonymous: Boolean,
    ) {
        private val config: SmbConfig = SmbConfig.builder()
            .withTimeout(15, TimeUnit.SECONDS)
            .withSoTimeout(30, TimeUnit.SECONDS)
            .build()

        private val lock = Any()
        private var client: SMBClient? = null
        private var connection: Connection? = null
        private var session: Session? = null
        private var share: DiskShare? = null

        private fun auth(): AuthenticationContext =
            if (anonymous || (username.isBlank() && password.isBlank())) {
                AuthenticationContext.guest()
            } else {
                AuthenticationContext(username, password.toCharArray(), domain.ifBlank { null })
            }

        fun connect(): DiskShare = synchronized(lock) { connectLocked() }

        private fun connectLocked(): DiskShare {
            share?.takeIf { it.isConnected }?.let { return it }
            teardown()
            val c = SMBClient(config).also { client = it }
            val conn = c.connect(host, if (port > 0) port else SMBClient.DEFAULT_PORT)
                .also { connection = it }
            val sess = conn.authenticate(auth()).also { session = it }
            val disk = sess.connectShare(shareName) as? DiskShare
                ?: throw IOException("\\\\$host\\$shareName is not a disk share.")
            share = disk
            return disk
        }

        /**
         * [retryOnDeadTransport] must be false for streaming transfers: the caller's sink is already
         * partially written when the transport dies, so re-running would duplicate downloaded bytes
         * or upload only the leftover tail.
         */
        private fun <T> withShare(retryOnDeadTransport: Boolean = true, block: (DiskShare) -> T): T {
            synchronized(lock) {
                var attempt = 0
                while (true) {
                    val disk = connectLocked()
                    try {
                        return block(disk)
                    } catch (e: Exception) {
                        // Only a dead transport warrants rebuild+retry. An SMB status error (access
                        // denied, not found) must surface as-is without burning the warm session.
                        val transportDead = !disk.isConnected || e is IOException
                        teardown()
                        if (retryOnDeadTransport && transportDead && attempt++ < 1) continue
                        throw e
                    }
                }
            }
        }

        private fun smbPath(path: String) = path.trim('/').replace('/', '\\')

        fun list(path: String): List<Map<String, Any?>> = withShare { disk ->
            disk.list(smbPath(path))
                .filter { it.fileName != "." && it.fileName != ".." }
                .map { info ->
                    val isDir =
                        info.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L
                    mapOf(
                        "name" to info.fileName,
                        "isDirectory" to isDir,
                        "size" to if (isDir) 0L else info.endOfFile,
                        "modTimeSeconds" to ((info.lastWriteTime?.toEpochMillis() ?: 0L) / 1000),
                    )
                }
        }

        fun mkdir(path: String) = withShare { it.mkdir(smbPath(path)) }

        fun rename(from: String, to: String, isDirectory: Boolean) = withShare { disk ->
            val access = EnumSet.of(AccessMask.DELETE, AccessMask.GENERIC_READ)
            val entry = if (isDirectory) {
                disk.openDirectory(
                    smbPath(from), access, null, SMB2ShareAccess.ALL,
                    SMB2CreateDisposition.FILE_OPEN, null,
                )
            } else {
                disk.openFile(
                    smbPath(from), access, null, SMB2ShareAccess.ALL,
                    SMB2CreateDisposition.FILE_OPEN, null,
                )
            }
            entry.use { it.rename(smbPath(to), true) }
        }

        fun delete(path: String, isDirectory: Boolean) = withShare { disk ->
            if (isDirectory) disk.rmdir(smbPath(path), false) else disk.rm(smbPath(path))
        }

        fun openForWrite(path: String): OutputStream = withShare { disk ->
            disk.openFile(
                smbPath(path), EnumSet.of(AccessMask.GENERIC_WRITE), null,
                SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OVERWRITE_IF, null,
            ).outputStream
        }

        fun download(path: String, onChunk: (ByteArray, Long, Boolean) -> Unit) =
            withShare(retryOnDeadTransport = false) { disk ->
                val p = smbPath(path)
                val total = runCatching {
                    disk.getFileInformation(p).standardInformation.endOfFile
                }.getOrDefault(0L)
                disk.openFile(
                    p, EnumSet.of(AccessMask.GENERIC_READ), null,
                    SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, null,
                ).use { file ->
                    file.inputStream.use { input ->
                        val buffer = ByteArray(CHUNK_BYTES)
                        while (true) {
                            // Checked every chunk so a cancelled transfer stops promptly rather than
                            // at the end of the file.
                            if (Thread.currentThread().isInterrupted) throw InterruptedException()
                            val read = input.read(buffer)
                            if (read <= 0) break
                            onChunk(buffer.copyOf(read), total, false)
                        }
                        onChunk(ByteArray(0), total, true)
                    }
                }
            }

        fun close() = synchronized(lock) { teardown() }

        private fun teardown() {
            runCatching { share?.close() }
            runCatching { session?.close() }
            runCatching { connection?.close() }
            runCatching { client?.close() }
            share = null; session = null; connection = null; client = null
        }
    }
}
