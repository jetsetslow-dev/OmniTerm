package com.jetsetslow.omniterm

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/** A throttled, repeatable Storage Access Framework endpoint compiled only into debug builds. */
class SlowTransferContentProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> uri.lastPathSegment ?: "slow-transfer.bin"
                    OpenableColumns.SIZE -> uri.getQueryParameter("bytes")?.toLongOrNull() ?: 0L
                    else -> null
                }
            })
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        val bytes = uri.getQueryParameter("bytes")?.toLongOrNull()?.coerceAtLeast(0L) ?: 0L
        val delayMs = uri.getQueryParameter("delay_ms")?.toLongOrNull()?.coerceIn(0L, 100L) ?: 0L
        val key = uri.toString()
        if (mode.contains('w')) {
            thread(name = "e2e-slow-transfer-sink", isDaemon = true) {
                var received = 0L
                val captured = ByteArrayOutputStream()
                runCatching {
                    FileInputStream(pipe[0].fileDescriptor).use { input ->
                        val buffer = ByteArray(CHUNK_BYTES)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (captured.size() + count <= MAX_CAPTURE_BYTES) captured.write(buffer, 0, count)
                            if (delayMs > 0) Thread.sleep(delayMs)
                        }
                    }
                }
                receivedBytes[key] = received
                payloads[key] = captured.toByteArray()
                pipe[0].close()
            }
            return pipe[1]
        }

        thread(name = "e2e-slow-transfer-source", isDaemon = true) {
            runCatching {
                FileOutputStream(pipe[1].fileDescriptor).use { output ->
                    payloads[key]?.let { payload ->
                        output.write(payload)
                        return@use
                    }
                    val block = ByteArray(CHUNK_BYTES) { index -> ((index * 31 + 17) and 0xff).toByte() }
                    val opened = openCounts.merge(key, 1, Int::plus) ?: 1
                    val failOnce = uri.getQueryParameter("fail_once") == "true" && opened == 1
                    var remaining = if (failOnce) bytes / 2 else bytes
                    while (remaining > 0) {
                        val count = minOf(block.size.toLong(), remaining).toInt()
                        output.write(block, 0, count)
                        remaining -= count
                        if (delayMs > 0) Thread.sleep(delayMs)
                    }
                }
            }
            pipe[1].close()
        }
        return pipe[0]
    }

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        deletedUris += uri.toString()
        return 1
    }

    override fun getType(uri: Uri): String = "application/octet-stream"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        private const val CHUNK_BYTES = 64 * 1024
        private const val MAX_CAPTURE_BYTES = 20 * 1024 * 1024
        val deletedUris = ConcurrentHashMap.newKeySet<String>()
        val receivedBytes = ConcurrentHashMap<String, Long>()
        val payloads = ConcurrentHashMap<String, ByteArray>()
        private val openCounts = ConcurrentHashMap<String, Int>()
        fun reset() {
            deletedUris.clear()
            receivedBytes.clear()
            payloads.clear()
            openCounts.clear()
        }
    }
}
