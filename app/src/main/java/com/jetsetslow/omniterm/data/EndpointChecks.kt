package com.jetsetslow.omniterm.data

import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Alert rules the phone checks itself, over the network, instead of reading a metric from the
 * host: how long a TLS certificate has left, and whether a web address answers.
 *
 * A rule's alert value is a plain number so it fits the same incident and history rows as every
 * other metric. A TLS check's value is the days until the certificate expires, below zero once it
 * has. A URL check's value is the response time in ms, or below zero when it failed:
 * minus the status for an HTTP error, [URL_NO_RESPONSE] when nothing answered.
 */
object EndpointChecks {
    const val TLS_EXPIRY = "TLS Expiry"
    const val URL_CHECK = "URL Check"

    /** A URL check that got no HTTP answer at all: refused, timed out, or the TLS handshake failed. */
    const val URL_NO_RESPONSE = -1f

    /** A URL check gives up after this long; its threshold must be under it. */
    const val URL_TIMEOUT_MS = 15_000

    /** A TLS check waits this long to connect and to finish the handshake. */
    const val TLS_TIMEOUT_MS = 10_000

    const val DEFAULT_TLS_PORT = 443

    private const val DAY_MS = 24L * 60 * 60 * 1000

    fun isEndpointMetric(metricName: String) = metricName == TLS_EXPIRY || metricName == URL_CHECK

    /**
     * Where a TLS check connects: the host and port of [target], which may be `host`, `host:port`,
     * `[v6]:port`, a bare IPv6 address or a URL. A blank target is [hostAddress] on port 443.
     * Null when the target names no host.
     */
    fun tlsEndpoint(target: String, hostAddress: String): Pair<String, Int>? {
        val t = target.trim().ifEmpty { return hostAddress.trim().takeIf { it.isNotEmpty() }?.let { it to DEFAULT_TLS_PORT } }
        if ("://" in t) {
            val uri = runCatching { URI(t) }.getOrNull() ?: return null
            val host = uri.host?.removeSurrounding("[", "]")?.takeIf { it.isNotEmpty() } ?: return null
            return host to (if (uri.port in 1..65535) uri.port else DEFAULT_TLS_PORT)
        }
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close <= 1) return null
            val host = t.substring(1, close)
            val rest = t.substring(close + 1)
            if (rest.isEmpty()) return host to DEFAULT_TLS_PORT
            val port = rest.removePrefix(":").toIntOrNull()?.takeIf { rest.startsWith(":") && it in 1..65535 } ?: return null
            return host to port
        }
        // Two or more colons is an IPv6 address written without brackets, so it has no port.
        if (t.count { it == ':' } == 1) {
            val host = t.substringBefore(':').takeIf { it.isNotEmpty() } ?: return null
            val port = t.substringAfter(':').toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            return host to port
        }
        return t.takeIf { ' ' !in it }?.let { it to DEFAULT_TLS_PORT }
    }

    /** The address a URL check fetches, with https:// added when none was typed. Null when it is not a web address. */
    fun checkUrl(target: String): String? {
        val t = target.trim().ifEmpty { return null }
        val url = if ("://" in t) t else "https://$t"
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty()) return null
        return url
    }

    /** Whole and part days from [now] until [notAfter], below zero once it has passed. */
    fun daysLeft(notAfter: Long, now: Long): Float = (notAfter - now).toFloat() / DAY_MS

    /** True when [value] should count toward [rule]'s alert. */
    fun breached(rule: AlertRuleEntity, value: Float): Boolean = when (rule.metricName) {
        TLS_EXPIRY -> value <= rule.thresholdValue
        URL_CHECK -> value < 0f || value > rule.thresholdValue
        else -> false
    }

    /** [value] in words: "41 days left", "expired 3 days ago", "320 ms", "HTTP 503", "no response". */
    fun describe(metricName: String, value: Float): String = when (metricName) {
        TLS_EXPIRY -> {
            val shown = when (val whole = abs(value).toInt()) {
                0 -> "less than a day"
                1 -> "1 day"
                else -> "$whole days"
            }
            if (value < 0f) "expired $shown ago" else "$shown left"
        }
        URL_CHECK -> when {
            value == URL_NO_RESPONSE -> "no response"
            value < 0f -> "HTTP ${(-value).roundToInt()}"
            else -> "${value.roundToInt()} ms"
        }
        else -> value.toString()
    }

    /** The notification line for an endpoint alert on [target]. */
    fun alertText(rule: AlertRuleEntity, target: String, value: Float): String = when (rule.metricName) {
        TLS_EXPIRY -> "TLS certificate on $target: ${describe(TLS_EXPIRY, value)} (alerts at ${rule.thresholdValue.roundToInt()} days)"
        URL_CHECK -> if (value < 0f) {
            "$target failed: ${describe(URL_CHECK, value)}"
        } else {
            "$target answered in ${describe(URL_CHECK, value)} (threshold ${rule.thresholdValue.roundToInt()} ms)"
        }
        else -> describe(rule.metricName, value)
    }

    /** What one check saw: [value] for the alert (null when the check could not observe anything), and [summary] for the rule list. */
    data class Result(val value: Float?, val summary: String, val target: String)

    /**
     * Runs [rule]'s check from this phone against its target, or [hostAddress] when it names none.
     * Blocks for up to the check's timeout, so call it off the main thread.
     */
    fun run(rule: AlertRuleEntity, hostAddress: String, now: () -> Long = System::currentTimeMillis): Result = when (rule.metricName) {
        TLS_EXPIRY -> {
            val endpoint = tlsEndpoint(rule.target, hostAddress)
            if (endpoint == null) {
                Result(null, "Not a host or address: ${rule.target}", rule.target)
            } else {
                val (host, port) = endpoint
                val shown = if (':' in host) "[$host]:$port" else "$host:$port"
                try {
                    val cert = serverCertificate(host, port, TLS_TIMEOUT_MS)
                    val days = daysLeft(cert.notAfter.time, now())
                    Result(days, describe(TLS_EXPIRY, days), shown)
                } catch (e: IOException) {
                    // Nothing to measure: no TLS there, or it could not be reached from the phone.
                    Result(null, "Could not read a certificate: ${e.message ?: e.javaClass.simpleName}", shown)
                }
            }
        }
        URL_CHECK -> {
            val url = checkUrl(rule.target)
            if (url == null) {
                Result(null, "Not a web address: ${rule.target}", rule.target)
            } else {
                val (value, problem) = fetch(url, URL_TIMEOUT_MS)
                Result(value, problem?.let { "${describe(URL_CHECK, value)}: $it" } ?: describe(URL_CHECK, value), url)
            }
        }
        else -> Result(null, "", rule.target)
    }

    /**
     * Fetches [url] and returns its alert value with, on failure, why. Redirects are followed, any
     * status below 400 is an answer, and the body is never read.
     */
    fun fetch(url: String, timeoutMs: Int): Pair<Float, String?> {
        val started = System.nanoTime()
        val conn = try {
            URI(url).toURL().openConnection() as HttpURLConnection
        } catch (e: Exception) {
            return URL_NO_RESPONSE to (e.message ?: "invalid address")
        }
        return try {
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.instanceFollowRedirects = true
            conn.useCaches = false
            conn.setRequestProperty("User-Agent", "OmniTerm URL check")
            val status = conn.responseCode
            val elapsedMs = (System.nanoTime() - started) / 1_000_000f
            when {
                status < 0 -> URL_NO_RESPONSE to "not an HTTP answer"
                status >= 400 -> -status.toFloat() to conn.responseMessage?.takeIf { it.isNotBlank() }
                else -> elapsedMs to null
            }
        } catch (e: IOException) {
            URL_NO_RESPONSE to (e.message ?: e.javaClass.simpleName)
        } finally {
            conn.disconnect()
        }
    }

    /**
     * The leaf certificate [host]:[port] presents. The phone's usual trust check still runs, but a
     * certificate it rejects (self-signed, expired, wrong name) is still read: only its expiry
     * matters here. Nothing is sent after the handshake.
     */
    fun serverCertificate(host: String, port: Int, timeoutMs: Int): X509Certificate {
        val recorder = RecordingTrustManager(platformTrustManager())
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(recorder), null) }
        val plain = Socket()
        try {
            plain.connect(InetSocketAddress(host, port), timeoutMs)
            plain.soTimeout = timeoutMs
            // Layering on a connected socket with the host name sends SNI, so a server hosting
            // several names returns the certificate for this one.
            (context.socketFactory.createSocket(plain, host, port, true) as SSLSocket).use { ssl ->
                ssl.soTimeout = timeoutMs
                try {
                    ssl.startHandshake()
                } catch (e: IOException) {
                    // The handshake fails on an untrusted certificate, after it was recorded.
                    if (recorder.leaf == null) throw e
                }
            }
        } finally {
            plain.close()
        }
        return recorder.leaf ?: throw IOException("The server sent no certificate")
    }

    private fun platformTrustManager(): X509TrustManager {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    /** Remembers the server's leaf certificate, then leaves the trust decision to [platform]. */
    private class RecordingTrustManager(private val platform: X509TrustManager) : X509TrustManager {
        @Volatile var leaf: X509Certificate? = null

        override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
            platform.checkClientTrusted(chain, authType)

        @Throws(CertificateException::class)
        override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
            leaf = chain.firstOrNull()
            platform.checkServerTrusted(chain, authType)
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = platform.acceptedIssuers
    }
}
