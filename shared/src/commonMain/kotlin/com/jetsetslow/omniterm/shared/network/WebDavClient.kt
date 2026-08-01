package com.jetsetslow.omniterm.shared.network

import com.jetsetslow.omniterm.shared.platform.ByteSink
import com.jetsetslow.omniterm.shared.platform.ByteSource
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.PlatformError
import com.jetsetslow.omniterm.shared.platform.RemoteEntry
import com.jetsetslow.omniterm.shared.platform.TransferProgress
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.timeout
import io.ktor.client.request.basicAuth
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.put
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.contentType
import io.ktor.http.encodeURLPathPart
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.readAvailable
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.CancellationException

class WebDavClient(
    host: String,
    port: Int = 443,
    private val username: String = "",
    private val password: String = "",
    private val anonymous: Boolean = false,
    private val client: HttpClient = createPlatformHttpClient(),
) {
    private val baseUrl: String

    init {
        require(host.isNotBlank()) { "WebDAV host is required" }
        require(port in 1..65535) { "WebDAV port must be 1-65535" }
        require(!host.startsWith("http://", ignoreCase = true)) { "Cleartext WebDAV is disabled" }
        val normalizedHost = host.removePrefix("https://").trimEnd('/')
        baseUrl = "https://$normalizedHost${if (port == 443) "" else ":$port"}"
    }

    suspend fun list(path: String): CapabilityResult<List<RemoteEntry>> = call {
        val response = client.request(url(path, directory = true)) {
            method = HttpMethod("PROPFIND")
            authorize()
            header("Depth", "1")
            contentType(ContentType.Application.Xml)
            timeout { connectTimeoutMillis = 10_000; socketTimeoutMillis = 30_000; requestTimeoutMillis = 30_000 }
            setBody("""<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>""")
        }
        requireSuccess(response.status)
        val requested = normalizePath(path).trim('/')
        parseWebDavMultistatus(response.bodyAsText())
            .map { entry ->
                val decodedPath = decodeHrefPath(entry.href)
                RemoteEntry(
                    path = decodedPath,
                    directory = entry.directory,
                    size = if (entry.directory) 0 else entry.size,
                    modifiedEpochMillis = null,
                )
            }
            .filter { it.path.trim('/') != requested }
    }

    suspend fun makeDirectory(path: String): CapabilityResult<Unit> = call {
        val response = client.request(url(path, directory = true)) { method = HttpMethod("MKCOL"); authorize(); requestTimeout() }
        requireSuccess(response.status)
    }

    suspend fun move(from: String, to: String, directory: Boolean): CapabilityResult<Unit> = call {
        val response = client.request(url(from, directory)) {
            method = HttpMethod("MOVE")
            authorize()
            header("Destination", url(to, directory))
            header("Overwrite", "T")
            requestTimeout()
        }
        requireSuccess(response.status)
    }

    suspend fun delete(path: String, directory: Boolean): CapabilityResult<Unit> = call {
        val response = client.delete(url(path, directory)) { authorize(); requestTimeout() }
        requireSuccess(response.status)
    }

    suspend fun download(path: String, sink: ByteSink, progress: (TransferProgress) -> Unit): CapabilityResult<Unit> = call {
        val response = client.get(url(path, directory = false)) { authorize(); requestTimeout(long = true) }
        requireSuccess(response.status)
        val total = response.headers[HttpHeaders.ContentLength]?.toLongOrNull()
        val channel = response.bodyAsChannel()
        val buffer = ByteArray(64 * 1024)
        var copied = 0L
        progress(TransferProgress(0, total))
        try {
            while (!channel.isClosedForRead) {
                val count = channel.readAvailable(buffer)
                if (count < 0) break
                if (count == 0) continue
                sink.write(buffer, count)
                copied += count
                progress(TransferProgress(copied, total))
            }
            sink.close()
        } catch (error: Throwable) {
            runCatching { sink.close() }
            throw error
        }
    }

    suspend fun upload(
        path: String,
        source: ByteSource,
        totalBytes: Long?,
        progress: (TransferProgress) -> Unit,
    ): CapabilityResult<Unit> = call {
        val response = client.put(url(path, directory = false)) {
            authorize()
            contentType(ContentType.Application.OctetStream)
            requestTimeout(long = true)
            setBody(object : OutgoingContent.WriteChannelContent() {
                override val contentLength: Long? = totalBytes
                override val contentType: ContentType = ContentType.Application.OctetStream
                override suspend fun writeTo(channel: ByteWriteChannel) {
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    progress(TransferProgress(0, totalBytes))
                    try {
                        while (true) {
                            val count = source.read(buffer)
                            if (count < 0) break
                            require(count in 1..buffer.size) { "ByteSource returned an invalid count" }
                            channel.writeFully(buffer, 0, count)
                            copied += count
                            progress(TransferProgress(copied, totalBytes))
                        }
                    } finally {
                        source.close()
                    }
                }
            })
        }
        requireSuccess(response.status)
    }

    fun close() = client.close()

    private fun io.ktor.client.request.HttpRequestBuilder.authorize() {
        if (!anonymous && username.isNotBlank()) basicAuth(username, password)
    }

    private fun io.ktor.client.request.HttpRequestBuilder.requestTimeout(long: Boolean = false) {
        timeout {
            connectTimeoutMillis = 10_000
            socketTimeoutMillis = if (long) 120_000 else 30_000
            requestTimeoutMillis = if (long) null else 30_000
        }
    }

    private fun url(path: String, directory: Boolean): String {
        val encoded = normalizePath(path).split('/').filter(String::isNotEmpty).joinToString("/") { it.encodeURLPathPart() }
        return "$baseUrl/$encoded${if (directory && encoded.isNotEmpty()) "/" else ""}"
    }

    private fun normalizePath(path: String): String {
        val parts = path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
        require(parts.none { it == ".." }) { "Parent path segments are not allowed" }
        return "/" + parts.joinToString("/")
    }

    private fun decodeHrefPath(href: String): String {
        val raw = href.substringAfter("://", href).substringAfter('/', "").substringBefore('?').substringBefore('#')
        return "/" + raw.trim('/').split('/').joinToString("/") { decodePercent(it) }
    }

    private fun decodePercent(value: String): String {
        val bytes = ByteArray(value.length)
        var count = 0
        var index = 0
        val plain = StringBuilder()
        fun flush() { if (count > 0) { plain.append(bytes.copyOf(count).decodeToString()); count = 0 } }
        while (index < value.length) {
            if (value[index] == '%' && index + 2 < value.length) {
                val byte = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (byte != null) { bytes[count++] = byte.toByte(); index += 3; continue }
            }
            flush(); plain.append(value[index++])
        }
        flush()
        return plain.toString()
    }

    private fun requireSuccess(status: HttpStatusCode) {
        if (status.value !in 200..299) throw WebDavHttpException(status.value)
    }

    private suspend fun <T> call(block: suspend () -> T): CapabilityResult<T> = try {
        CapabilityResult.Available(block())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: HttpRequestTimeoutException) {
        CapabilityResult.Failed(PlatformError.NetworkUnavailable)
    } catch (error: WebDavHttpException) {
        CapabilityResult.Failed(when (error.status) {
            401, 403 -> PlatformError.AuthenticationFailed
            404 -> PlatformError.NotFound
            else -> PlatformError.Protocol("HTTP_${error.status}")
        })
    } catch (_: IllegalArgumentException) {
        CapabilityResult.Failed(PlatformError.Protocol("INVALID_REQUEST"))
    } catch (_: Throwable) {
        CapabilityResult.Failed(PlatformError.NetworkUnavailable)
    }
}

private class WebDavHttpException(val status: Int) : Exception()
