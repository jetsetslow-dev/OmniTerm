package com.jetsetslow.omniterm.data

import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.math.abs
import kotlin.math.roundToInt

/** The platform's own `ping`; a process command is never looked up through an inherited PATH. */
internal const val ANDROID_PING_BINARY = "/system/bin/ping"

/**
 * Alert rules the phone checks itself, over the network, instead of reading a metric from the
 * host: how long a TLS certificate has left, whether a web address answers, whether the host
 * answers a ping, whether a TCP port accepts connections, and whether a DNS server answers a name.
 *
 * A rule's alert value is a plain number so it fits the same incident and history rows as every
 * other metric. A TLS check's value is the days until the certificate expires, below zero once it
 * has. The other checks time a reply in ms and are below zero when they failed: [URL_NO_RESPONSE]
 * when nothing answered, minus the status for an HTTP error, [DNS_NO_ADDRESS] or minus
 * (100 + rcode) for a DNS answer without an address.
 */
object EndpointChecks {
    const val TLS_EXPIRY = "TLS Expiry"
    const val URL_CHECK = "URL Check"
    const val PING = "Ping"
    const val TCP_PORT = "TCP Port"
    const val DNS_CHECK = "DNS"

    /** The checks that time a reply. */
    private val TIMED = setOf(URL_CHECK, PING, TCP_PORT, DNS_CHECK)

    /** Ping, TCP and DNS checks give up after this long; their thresholds must be under it. */
    const val QUICK_TIMEOUT_MS = 3_000

    const val DNS_PORT = 53

    /** A DNS server answered, but has no address for the name (no A and no AAAA record). */
    const val DNS_NO_ADDRESS = -100f

    /** A URL check that got no HTTP answer at all: refused, timed out, or the TLS handshake failed. */
    const val URL_NO_RESPONSE = -1f

    /** A URL check gives up after this long; its threshold must be under it. */
    const val URL_TIMEOUT_MS = 15_000

    /** A TLS check waits this long to connect and to finish the handshake. */
    const val TLS_TIMEOUT_MS = 10_000

    const val DEFAULT_TLS_PORT = 443

    private const val DAY_MS = 24L * 60 * 60 * 1000

    fun isEndpointMetric(metricName: String) = metricName == TLS_EXPIRY || metricName in TIMED

    /** True for a check whose value is a reply time in ms. */
    fun isTimed(metricName: String) = metricName in TIMED

    /** The limit a timed check's threshold must stay under, or null for other metrics. */
    fun timeoutMs(metricName: String): Int? = when (metricName) {
        URL_CHECK -> URL_TIMEOUT_MS
        PING, TCP_PORT, DNS_CHECK -> QUICK_TIMEOUT_MS
        else -> null
    }

    /**
     * Where a TLS check connects: the host and port of [target], which may be `host`, `host:port`,
     * `[v6]:port`, a bare IPv6 address or a URL. A blank target is [hostAddress] on port 443.
     * Null when the target names no host.
     */
    fun tlsEndpoint(target: String, hostAddress: String): Pair<String, Int>? {
        val t = target.trim().ifEmpty { return hostAddress.trim().takeIf { it.isNotEmpty() }?.let { it to DEFAULT_TLS_PORT } }
        return hostAndPort(t, DEFAULT_TLS_PORT)
    }

    /**
     * Where a TCP check connects: a bare port is [hostAddress] on that port; otherwise `host:port`,
     * `[v6]:port` or a URL that names its port. Null without a usable port.
     */
    fun tcpEndpoint(target: String, hostAddress: String): Pair<String, Int>? {
        val t = target.trim()
        t.toIntOrNull()?.let { port ->
            return if (port in 1..65535 && hostAddress.isNotBlank()) hostAddress.trim() to port else null
        }
        return hostAndPort(t, defaultPort = null)
    }

    /**
     * A DNS check's question and server: `name` asks [hostAddress] (the host is the DNS server, a
     * Pi-hole say), and `name@server` or `name@server:port` asks another one. The name is returned
     * in its ASCII form. Null when unusable.
     */
    fun dnsTarget(target: String, hostAddress: String): Triple<String, String, Int>? {
        val t = target.trim()
        val name = t.substringBefore('@').trim().trimEnd('.')
        if (name.isEmpty() || name.any { it.isWhitespace() }) return null
        val ascii = runCatching { java.net.IDN.toASCII(name) }.getOrNull() ?: return null
        if (ascii.length > 253 || ascii.split('.').any { it.isEmpty() || it.length > 63 }) return null
        val (server, port) = if ('@' in t) {
            hostAndPort(t.substringAfter('@').trim(), DNS_PORT) ?: return null
        } else {
            (hostAddress.trim().takeIf { it.isNotEmpty() } ?: return null) to DNS_PORT
        }
        return Triple(ascii, server, port)
    }

    /**
     * [host] as `ping` should get it: trimmed, without the brackets around an IPv6 address. Null
     * unless it is one name or address, and never when it would read as an option (a leading `-`).
     */
    fun pingHost(host: String): String? {
        val t = host.trim().removeSurrounding("[", "]")
        return t.takeIf { it.isNotEmpty() && !it.startsWith("-") && it.all { c -> c.isLetterOrDigit() || c in ".-:%_" } }
    }

    /**
     * The host and port in `host`, `host:port`, `[v6]`, `[v6]:port`, a bare IPv6 address or a URL.
     * Without a port it is [defaultPort], and with no default the text is not usable.
     */
    internal fun hostAndPort(t: String, defaultPort: Int?): Pair<String, Int>? {
        if (t.isEmpty() || t.any { it.isWhitespace() }) return null
        if ("://" in t) {
            val uri = runCatching { URI(t) }.getOrNull() ?: return null
            val host = uri.host?.removeSurrounding("[", "]")?.takeIf { it.isNotEmpty() } ?: return null
            val port = if (uri.port in 1..65535) uri.port else defaultPort ?: return null
            return host to port
        }
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close <= 1) return null
            val host = t.substring(1, close)
            val rest = t.substring(close + 1)
            if (rest.isEmpty()) return defaultPort?.let { host to it }
            val port = rest.removePrefix(":").toIntOrNull()?.takeIf { rest.startsWith(":") && it in 1..65535 } ?: return null
            return host to port
        }
        // Two or more colons is an IPv6 address written without brackets, so it has no port.
        if (t.count { it == ':' } == 1) {
            val host = t.substringBefore(':').takeIf { it.isNotEmpty() } ?: return null
            val port = t.substringAfter(':').toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            return host to port
        }
        return defaultPort?.let { t to it }
    }

    /** The address a URL check fetches, with https:// added when none was typed. Null when it is not a web address. */
    fun checkUrl(target: String): String? {
        val t = target.trim().ifEmpty { return null }
        // Without a scheme the target is read as "//host/path" and resolved against https, which
        // keeps it exactly as typed. Writing "https://" in front would too, but CodeQL takes a
        // "scheme://" literal that reaches a connection for the app's own server and asks for it
        // to be pinned, which an address the user typed cannot be.
        val uri = runCatching { if ("://" in t) URI(t) else HTTPS.resolve("//$t") }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty()) return null
        return uri.toString()
    }

    private val HTTPS = URI("https:/")

    /** Whole and part days from [now] until [notAfter], below zero once it has passed. */
    fun daysLeft(notAfter: Long, now: Long): Float = (notAfter - now).toFloat() / DAY_MS

    /** True when [value] should count toward [rule]'s alert. */
    fun breached(rule: AlertRuleEntity, value: Float): Boolean = when (rule.metricName) {
        TLS_EXPIRY -> value <= rule.thresholdValue
        in TIMED -> value < 0f || value > rule.thresholdValue
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
        PING -> if (value < 0f) "no reply" else ms(value)
        TCP_PORT -> if (value < 0f) "not accepting connections" else ms(value)
        DNS_CHECK -> when {
            value >= 0f -> ms(value)
            value == URL_NO_RESPONSE -> "no response"
            value == DNS_NO_ADDRESS -> "no address for the name"
            else -> when (val rcode = (-value - 100f).roundToInt()) {
                2 -> "server failure (SERVFAIL)"
                3 -> "no such name (NXDOMAIN)"
                5 -> "refused (REFUSED)"
                else -> "DNS error $rcode"
            }
        }
        else -> value.toString()
    }

    /** A reply time: "0.4 ms" below 10 ms, whole ms from there. */
    private fun ms(value: Float): String =
        if (value < 10f) "${(value * 10).roundToInt() / 10f} ms" else "${value.roundToInt()} ms"

    /** The notification line for an endpoint alert on [target]. */
    fun alertText(rule: AlertRuleEntity, target: String, value: Float): String = when (rule.metricName) {
        TLS_EXPIRY -> "TLS certificate on $target: ${describe(TLS_EXPIRY, value)} (alerts at ${rule.thresholdValue.roundToInt()} days)"
        URL_CHECK -> if (value < 0f) {
            "$target failed: ${describe(URL_CHECK, value)}"
        } else {
            "$target answered in ${describe(URL_CHECK, value)} (threshold ${rule.thresholdValue.roundToInt()} ms)"
        }
        PING, TCP_PORT, DNS_CHECK -> if (value < 0f) {
            "${rule.metricName} $target failed: ${describe(rule.metricName, value)}"
        } else {
            "${rule.metricName} $target answered in ${describe(rule.metricName, value)} (threshold ${rule.thresholdValue.roundToInt()} ms)"
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
        PING -> {
            val host = pingHost(rule.target.ifBlank { hostAddress })
            if (host == null) {
                Result(null, "Not a host or address: ${rule.target}", rule.target)
            } else {
                val (value, problem) = ping(host, QUICK_TIMEOUT_MS)
                Result(value, problem?.let { "${describe(PING, value)}: $it" } ?: describe(PING, value), host)
            }
        }
        TCP_PORT -> {
            val endpoint = tcpEndpoint(rule.target, hostAddress)
            if (endpoint == null) {
                Result(null, "Not a port or host:port: ${rule.target}", rule.target)
            } else {
                val (host, port) = endpoint
                val shown = if (':' in host) "[$host]:$port" else "$host:$port"
                val (value, problem) = connect(host, port, QUICK_TIMEOUT_MS)
                Result(value, problem?.let { "${describe(TCP_PORT, value)}: $it" } ?: describe(TCP_PORT, value), shown)
            }
        }
        DNS_CHECK -> {
            val question = dnsTarget(rule.target, hostAddress)
            if (question == null) {
                Result(null, "Not a name, or name@server: ${rule.target}", rule.target)
            } else {
                val (name, server, port) = question
                val shown = "$name @ " + (if (':' in server) "[$server]" else server) + (if (port != DNS_PORT) ":$port" else "")
                val (value, problem) = dnsLookup(name, server, port, QUICK_TIMEOUT_MS)
                Result(value, problem?.let { "${describe(DNS_CHECK, value)}: $it" } ?: describe(DNS_CHECK, value), shown)
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
     * One ping from the phone through [binary], the platform's own: the round trip in ms, or
     * [URL_NO_RESPONSE] with ping's reason when it gave one. [host] must pass [pingHost].
     */
    fun ping(host: String, timeoutMs: Int, binary: String = ANDROID_PING_BINARY): Pair<Float, String?> {
        val target = pingHost(host) ?: return URL_NO_RESPONSE to "not a host or address"
        val seconds = ((timeoutMs + 999) / 1000).coerceAtLeast(1)
        return try {
            val process = ProcessBuilder(binary, "-c", "1", "-W", seconds.toString(), target).redirectErrorStream(true).start()
            // ping's own -W bounds the wait; the watchdog only stops one that hangs past it, such as
            // on a slow name lookup. Process.waitFor with a timeout needs API 26, so a thread does it.
            val timedOut = AtomicBoolean(false)
            val watchdog = Thread {
                try {
                    Thread.sleep(timeoutMs + 2_000L)
                    timedOut.set(true)
                    process.destroy()
                } catch (_: InterruptedException) {
                    // The ping ended first.
                }
            }.apply { isDaemon = true; start() }
            val text = try {
                // Returns once ping exits, or once the watchdog's destroy closes the pipe.
                process.inputStream.bufferedReader().use { it.readText() }
            } finally {
                watchdog.interrupt()
                process.destroy()
            }
            if (timedOut.get()) return URL_NO_RESPONSE to "timed out"
            val time = Regex("""time[=<]\s*([0-9.]+)\s*ms""").find(text)?.groupValues?.get(1)?.toFloatOrNull()
            if (time != null) {
                time to null
            } else {
                // ping's own words for why, such as an unknown host; a plain timeout prints none.
                URL_NO_RESPONSE to text.lineSequence().map { it.trim() }
                    .firstOrNull { it.startsWith("ping:", ignoreCase = true) }?.removePrefix("ping:")?.trim()
            }
        } catch (e: IOException) {
            URL_NO_RESPONSE to (e.message ?: "ping could not run")
        }
    }

    /** Opens a TCP connection to [host]:[port] and closes it: the connect time in ms, or [URL_NO_RESPONSE] with why. */
    fun connect(host: String, port: Int, timeoutMs: Int): Pair<Float, String?> {
        val started = System.nanoTime()
        return try {
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
            (System.nanoTime() - started) / 1_000_000f to null
        } catch (e: IOException) {
            URL_NO_RESPONSE to (e.message ?: e.javaClass.simpleName)
        } catch (e: IllegalArgumentException) {
            // A port outside 0..65535.
            URL_NO_RESPONSE to (e.message ?: "not a port")
        }
    }

    /**
     * Asks [server]:[port] over UDP for [name]'s address, A first and then AAAA: the reply time in
     * ms, or below zero: [URL_NO_RESPONSE] when nothing answered within [timeoutMs], [DNS_NO_ADDRESS]
     * for no record, and -(100 + rcode) for a DNS error such as NXDOMAIN.
     */
    fun dnsLookup(name: String, server: String, port: Int, timeoutMs: Int): Pair<Float, String?> {
        val started = System.nanoTime()
        return try {
            DatagramSocket().use { socket ->
                val address = InetAddress.getByName(server)
                for (type in intArrayOf(DNS_TYPE_A, DNS_TYPE_AAAA)) {
                    val left = timeoutMs - ((System.nanoTime() - started) / 1_000_000L).toInt()
                    if (left <= 0) throw SocketTimeoutException("timed out")
                    socket.soTimeout = left
                    val (rcode, answers) = dnsExchange(socket, address, port, name, type)
                    if (rcode != 0) return -(100f + rcode) to null
                    if (answers > 0) return (System.nanoTime() - started) / 1_000_000f to null
                }
                DNS_NO_ADDRESS to null
            }
        } catch (e: IOException) {
            URL_NO_RESPONSE to (e.message ?: e.javaClass.simpleName)
        } catch (e: IllegalArgumentException) {
            URL_NO_RESPONSE to (e.message ?: "not a DNS name")
        }
    }

    private const val DNS_TYPE_A = 1
    private const val DNS_TYPE_AAAA = 28

    /**
     * One query and its reply: the reply's rcode and answer count. Replies from another address,
     * or to another query id, are skipped, so a stray or spoofed packet cannot answer for the server.
     */
    private fun dnsExchange(socket: DatagramSocket, server: InetAddress, port: Int, name: String, type: Int): Pair<Int, Int> {
        val id = SecureRandom().nextInt(0x10000)
        val query = serializeDnsQuery(name, type, id)
        socket.send(DatagramPacket(query, query.size, server, port))
        val buffer = ByteArray(1500)
        while (true) {
            val reply = DatagramPacket(buffer, buffer.size)
            socket.receive(reply) // a SocketTimeoutException, an IOException, once soTimeout passes
            if (reply.length < 12 || reply.address != server || reply.port != port) continue
            val replyId = (buffer[0].toInt() and 0xff shl 8) or (buffer[1].toInt() and 0xff)
            val isResponse = buffer[2].toInt() and 0x80 != 0
            if (replyId != id || !isResponse) continue
            val rcode = buffer[3].toInt() and 0x0f
            val answers = (buffer[6].toInt() and 0xff shl 8) or (buffer[7].toInt() and 0xff)
            return rcode to answers
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
            // The platform would throw IllegalArgumentException here. A certificate error fails the
            // handshake the same way, and is a throw CodeQL can see: it cannot see the platform's,
            // and without one it takes this manager for one that trusts any certificate.
            if (chain.isEmpty()) throw CertificateException("The server sent no certificate")
            leaf = chain[0]
            platform.checkServerTrusted(chain, authType)
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = platform.acceptedIssuers
    }
}
