package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.data.shares.RemoteFsClient
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap

/** A host's files in memory, as SFTP shows them: folders in [dirs], files by full path. */
internal class MemoryHost(private val home: String, dirs: Collection<String>) : RemoteFsClient {
    val dirs: MutableSet<String> = ConcurrentHashMap.newKeySet<String>().apply { addAll(dirs) }
    val files = ConcurrentHashMap<String, ByteArray>()
    @Volatile var short = false

    override suspend fun home(): String = home

    override suspend fun list(path: String): List<SftpFile> {
        val dir = path.trimEnd('/').ifEmpty { "/" }
        if (dir !in dirs) throw IOException("No such file")
        val prefix = if (dir == "/") "/" else "$dir/"
        fun child(full: String) = full != dir && full.startsWith(prefix) && '/' !in full.removePrefix(prefix)
        return dirs.filter(::child).map { SftpFile(it.removePrefix(prefix), true, 0, "") } +
            files.filterKeys(::child).map { (path, bytes) -> SftpFile(path.removePrefix(prefix), false, bytes.size.toLong(), "") }
    }

    override suspend fun mkdir(path: String) { dirs += path }

    override suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean) {
        if (files.containsKey(newPath)) throw IOException("Failure: file exists")
        files[newPath] = files.remove(oldPath) ?: throw IOException("No such file")
    }

    override suspend fun delete(path: String, isDirectory: Boolean) { files.remove(path) }

    override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?): Long {
        val bytes = files[path] ?: throw IOException("No such file")
        output.write(bytes)
        return bytes.size.toLong()
    }

    override suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)?) {
        if (path.substringBeforeLast('/').ifEmpty { "/" } !in dirs) throw IOException("No such file")
        val bytes = input.readBytes()
        files[path] = if (short) bytes.copyOf(bytes.size / 2) else bytes
    }
}
