package com.jetsetslow.omniterm.data.shares

import com.jetsetslow.omniterm.data.SftpFile
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.StringReader
import java.net.URLDecoder
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

/**
 * WebDAV client over the app's existing OkHttp stack: PROPFIND (Depth: 1) for listings, GET/PUT
 * for transfers, MKCOL/DELETE/MOVE for management. Auth is preemptive Basic (the common case for
 * NAS/webdav servers); anonymous shares send no Authorization header. Paths are absolute from the
 * server root — the share's configured path is just the starting directory.
 */
class WebDavFsClient(
    host: String,
    port: Int,
    https: Boolean,
    private val username: String,
    private val password: String,
    private val anonymous: Boolean,
) : RemoteFsClient {

    init {
        require(https) {
            "Cleartext HTTP WebDAV is disabled. Edit this share to use HTTPS or use SFTP instead."
        }
    }

    private val base: HttpUrl = HttpUrl.Builder()
        .scheme("https")
        .host(host)
        .port(if (port > 0) port else 443)
        .build()

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun urlFor(path: String, trailingSlash: Boolean = false): HttpUrl {
        val builder = base.newBuilder()
        path.split('/').filter { it.isNotEmpty() }.forEach { builder.addPathSegment(it) }
        if (trailingSlash) builder.addPathSegment("")
        return builder.build()
    }

    private fun request(url: HttpUrl): Request.Builder {
        val b = Request.Builder().url(url)
        if (!anonymous && username.isNotBlank()) b.header("Authorization", Credentials.basic(username, password))
        return b
    }

    private fun Response.failIfNotOk(action: String) {
        if (!isSuccessful) {
            close()
            throw IOException("WebDAV $action failed: HTTP $code ${message.ifBlank { "" }}".trim())
        }
    }

    override suspend fun home(): String = "/"

    override suspend fun list(path: String): List<SftpFile> = withContext(Dispatchers.IO) {
        val body = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop>
            </d:propfind>
        """.trimIndent().toRequestBody("application/xml; charset=utf-8".toMediaType())
        val req = request(urlFor(path, trailingSlash = true))
            .method("PROPFIND", body)
            .header("Depth", "1")
            .build()
        http.newCall(req).execute().use { resp ->
            resp.failIfNotOk("list")
            val xml = resp.body?.string() ?: throw IOException("WebDAV list returned an empty body.")
            val self = path.trim('/')
            parseMultistatus(xml)
                .filter { it.path.trim('/') != self && it.name.isNotBlank() }
                .map { e ->
                    SftpFile(
                        name = e.name,
                        isDirectory = e.isDirectory,
                        size = if (e.isDirectory) 0L else e.size,
                        modDate = formatFsDate(e.modifiedMillis),
                        modTimeSeconds = e.modifiedMillis / 1000,
                    )
                }
        }
    }

    override suspend fun mkdir(path: String) = withContext(Dispatchers.IO) {
        val req = request(urlFor(path, trailingSlash = true)).method("MKCOL", null).build()
        http.newCall(req).execute().use { it.failIfNotOk("mkdir") }
    }

    override suspend fun rename(oldPath: String, newPath: String, isDirectory: Boolean) = withContext(Dispatchers.IO) {
        // Apache and several NAS implementations redirect a collection URL that omits its trailing
        // slash. OkHttp may follow that redirect as a successful GET, making a no-op MOVE look like
        // a completed rename. Emit canonical collection URLs on both sides instead.
        val req = request(urlFor(oldPath, trailingSlash = isDirectory))
            .method("MOVE", null)
            .header("Destination", urlFor(newPath, trailingSlash = isDirectory).toString())
            .header("Overwrite", "T")
            .build()
        http.newCall(req).execute().use { it.failIfNotOk("rename") }
    }

    override suspend fun delete(path: String, isDirectory: Boolean) = withContext(Dispatchers.IO) {
        val req = request(urlFor(path, trailingSlash = isDirectory)).delete().build()
        http.newCall(req).execute().use { it.failIfNotOk("delete") }
    }

    override suspend fun downloadTo(path: String, output: OutputStream, onProgress: ((Long, Long) -> Unit)?): Long =
        withContext(Dispatchers.IO) {
            val req = request(urlFor(path)).get().build()
            http.newCall(req).execute().use { resp ->
                resp.failIfNotOk("download")
                val respBody = resp.body ?: throw IOException("WebDAV download returned an empty body.")
                val total = respBody.contentLength().coerceAtLeast(0L)
                respBody.byteStream().use { input -> copyWithProgress(input, output, total, onProgress) }
            }
        }

    override suspend fun uploadStream(path: String, input: InputStream, totalBytes: Long, onProgress: ((Long, Long) -> Unit)?) {
        withContext(Dispatchers.IO) {
            val reqBody = object : RequestBody() {
                override fun contentType() = "application/octet-stream".toMediaType()
                override fun contentLength() = if (totalBytes > 0) totalBytes else -1
                // The source stream can't be rewound, so OkHttp must never silently retry the PUT.
                override fun isOneShot() = true
                override fun writeTo(sink: BufferedSink) {
                    copyWithProgress(input, sink.outputStream(), totalBytes, onProgress)
                }
            }
            val req = request(urlFor(path)).put(reqBody).build()
            http.newCall(req).execute().use { it.failIfNotOk("upload") }
        }
    }

    // ── PROPFIND multistatus parsing ──

    private data class DavEntry(
        val path: String,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
        val modifiedMillis: Long,
    )

    private fun parseMultistatus(xml: String): List<DavEntry> {
        val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
        parser.setInput(StringReader(xml))
        val entries = mutableListOf<DavEntry>()
        var href = ""
        var isDir = false
        var size = 0L
        var modified = 0L
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            val tag = parser.name?.lowercase(Locale.ROOT)
            when (event) {
                XmlPullParser.START_TAG -> when (tag) {
                    "response" -> { href = ""; isDir = false; size = 0L; modified = 0L }
                    "href" -> href = parser.nextText().trim()
                    "collection" -> isDir = true
                    "getcontentlength" -> size = parser.nextText().trim().toLongOrNull() ?: 0L
                    "getlastmodified" -> modified = parseHttpDate(parser.nextText().trim())
                }
                XmlPullParser.END_TAG -> if (tag == "response" && href.isNotBlank()) {
                    val path = hrefToPath(href)
                    entries.add(DavEntry(path, path.trimEnd('/').substringAfterLast('/'), isDir, size, modified))
                }
            }
            event = parser.next()
        }
        return entries
    }

    /** hrefs may be absolute URLs or server-relative, and are URL-encoded either way. */
    private fun hrefToPath(href: String): String {
        val raw = if (href.startsWith("http://", true) || href.startsWith("https://", true)) {
            href.substringAfter("://").let { hostAndPath ->
                val slash = hostAndPath.indexOf('/')
                if (slash >= 0) hostAndPath.substring(slash) else "/"
            }
        } else href
        return runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrDefault(raw)
    }

    private fun parseHttpDate(value: String): Long =
        runCatching {
            SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).parse(value)?.time ?: 0L
        }.getOrDefault(0L)
}
