package com.jetsetslow.omniterm.data.shares

import com.jetsetslow.omniterm.data.SftpFile
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * An unfinished upload's staging file is removed even while the server still holds the aborted
 * upload open, as the shares fixture's WebDAV server (rclone) does: it answers 423 Locked to a
 * delete that arrives before it has seen the upload end, then keeps the partial file.
 */
class RemoveStagedFileTest {
    private val path = "/fixture/.cancel.bin.omniterm-part-1"

    /** A folder holding the staging file; each delete fails while [refusals] lasts. */
    private class Server(var refusals: Int, val listing: () -> List<String>) : RemoteFsClient {
        var present = true
        val calls = mutableListOf<String>()
        override suspend fun home() = "/"
        override suspend fun list(path: String): List<SftpFile> {
            calls += "list $path"
            return (listing() + if (present) listOf(".cancel.bin.omniterm-part-1") else emptyList())
                .map { SftpFile(it, false, 1, "") }
        }
        override suspend fun mkdir(path: String) = Unit
        override suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean) = Unit
        override suspend fun delete(path: String, isDirectory: Boolean) {
            calls += "delete"
            if (refusals-- > 0) throw IOException("WebDAV delete failed: HTTP 423 Locked")
            if (!present) throw IOException("WebDAV delete failed: HTTP 404 Not Found")
            present = false
        }
        override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?) = 0L
        override suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)?) = Unit
    }

    @Test
    fun `a delete refused while the server holds the upload is tried again until it goes`() = runTest {
        val server = Server(refusals = 2) { listOf("other.bin") }
        server.removeStagedFile(path)
        assertEquals(false, server.present)
        assertEquals(listOf("delete", "list /fixture", "delete", "list /fixture", "delete"), server.calls)
        assertEquals("waited 250 ms, then 500 ms", 750L, currentTime)
    }

    @Test
    fun `one delete is enough when the server takes it`() = runTest {
        val server = Server(refusals = 0) { emptyList() }
        server.removeStagedFile(path)
        assertEquals(listOf("delete"), server.calls)
        assertEquals(0L, currentTime)
    }

    @Test
    fun `a staging file that is not there ends it at once`() = runTest {
        val server = Server(refusals = 0) { emptyList() }.apply { present = false }
        server.removeStagedFile(path)
        assertEquals(listOf("delete", "list /fixture"), server.calls)
        assertEquals(0L, currentTime)
    }

    @Test
    fun `a folder that cannot be listed ends it at once`() = runTest {
        val server = Server(refusals = 9) { throw IOException("network is unreachable") }
        server.removeStagedFile(path)
        assertEquals(listOf("delete", "list /fixture"), server.calls)
        assertEquals(0L, currentTime)
    }

    @Test
    fun `a server that never lets go is left after the last try, without an error`() = runTest {
        val server = Server(refusals = 99) { emptyList() }
        server.removeStagedFile(path)
        assertEquals(true, server.present)
        assertEquals(5, server.calls.count { it == "delete" })
        assertEquals(STAGED_FILE_RETRY_MS.sum(), currentTime)
    }
}
