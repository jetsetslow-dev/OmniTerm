package com.jetsetslow.omniterm.data

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Opt-in forwarding of alerts to a service the user runs or picks: an ntfy topic, a Gotify server,
 * or any webhook. Off unless the user sets it up. Only the alert itself is sent: the same title
 * and text as the phone's notification, its severity, host, rule, reading and threshold.
 *
 * [request] builds what to send and does no I/O; [send] delivers it.
 */
object AlertForwarding {
    const val KIND_OFF = "off"
    const val KIND_NTFY = "ntfy"
    const val KIND_GOTIFY = "gotify"
    const val KIND_WEBHOOK = "webhook"
    val KINDS = listOf(KIND_OFF, KIND_NTFY, KIND_GOTIFY, KIND_WEBHOOK)

    const val DEFAULT_NTFY_SERVER = "https://ntfy.sh"

    /** Settings keys. The token is stored encrypted (see AppRepository). */
    const val SETTING_KIND = "alert_forward_kind"
    const val SETTING_URL = "alert_forward_url"
    const val SETTING_TOPIC = "alert_forward_topic"
    const val SETTING_TOKEN = "alert_forward_token"
    const val SETTING_RESOLVED = "alert_forward_resolved"

    const val TIMEOUT_MS = 10_000

    data class Config(
        val kind: String = KIND_OFF,
        val url: String = "",
        val topic: String = "",
        val token: String = "",
        val includeResolved: Boolean = true,
    ) {
        val enabled: Boolean get() = kind != KIND_OFF
    }

    /** One alert opening ([resolved] false) or recovering. [title] and [text] are the notification's. */
    data class Event(
        val resolved: Boolean,
        val severity: String,
        val host: String,
        val rule: String,
        val title: String,
        val text: String,
        val value: Float,
        val threshold: Float,
        val timeMs: Long,
    )

    /** What to send: a JSON POST to [url] with [headers]. */
    data class Request(val url: String, val headers: Map<String, String>, val body: String)

    /** How a delivery went: [ok], or why not, with the HTTP [status] when the server answered. */
    data class Outcome(val ok: Boolean, val detail: String, val status: Int? = null)

    /** Why [config] cannot be used, or null when it can. Off is always usable. */
    fun configError(config: Config): String? {
        if (!config.enabled) return null
        if (config.kind !in KINDS) return "Pick where to forward alerts"
        val url = config.url.trim().ifEmpty { if (config.kind == KIND_NTFY) DEFAULT_NTFY_SERVER else "" }
        if (url.isEmpty()) return "Enter the server's address"
        if (webAddress(url) == null) return "Enter an http:// or https:// address"
        return when (config.kind) {
            KIND_NTFY -> if (!TOPIC.matches(config.topic.trim())) "Enter a topic: letters, digits, - and _, up to 64" else null
            KIND_GOTIFY -> if (config.token.isBlank()) "Enter the Gotify application token" else null
            else -> null
        }
    }

    /** True when [config] sends over plain HTTP, so the alert and any token travel in clear text. */
    fun isCleartext(config: Config): Boolean =
        config.enabled && config.url.trim().startsWith("http://", ignoreCase = true)

    /** The delivery for [event], or null when [config] is off, unusable, or skips resolved alerts. */
    fun request(config: Config, event: Event): Request? {
        if (!config.enabled || configError(config) != null) return null
        if (event.resolved && !config.includeResolved) return null
        val base = webAddress(config.url.trim().ifEmpty { DEFAULT_NTFY_SERVER }) ?: return null
        val token = config.token.trim()
        val bearer = if (token.isNotEmpty()) mapOf("Authorization" to "Bearer $token") else emptyMap()
        return when (config.kind) {
            // ntfy's JSON publishing goes to the server root and names the topic in the body, which
            // keeps titles in any language out of HTTP headers.
            KIND_NTFY -> Request(
                url = base.trimEnd('/') + "/",
                headers = bearer,
                body = json(
                    "topic" to config.topic.trim(),
                    "title" to event.title,
                    "message" to event.text,
                    "priority" to ntfyPriority(event),
                    "tags" to listOf(if (event.resolved) "white_check_mark" else if (event.severity == "CRITICAL") "rotating_light" else "warning"),
                ),
            )
            KIND_GOTIFY -> Request(
                url = base.trimEnd('/') + "/message",
                headers = mapOf("X-Gotify-Key" to token),
                body = json("title" to event.title, "message" to event.text, "priority" to gotifyPriority(event)),
            )
            else -> Request(
                url = base,
                headers = bearer,
                body = json(
                    "source" to "OmniTerm",
                    "event" to if (event.resolved) "resolved" else "triggered",
                    "severity" to event.severity,
                    "host" to event.host,
                    "rule" to event.rule,
                    "title" to event.title,
                    "message" to event.text,
                    "value" to event.value,
                    "threshold" to event.threshold,
                    "time" to isoTime(event.timeMs),
                ),
            )
        }
    }

    /**
     * POSTs [request] and reports how it went. Redirects are not followed: a redirect would take
     * the token to an address the user did not enter, so it is reported instead.
     */
    fun send(request: Request, timeoutMs: Int = TIMEOUT_MS): Outcome {
        val conn = try {
            URI(request.url).toURL().openConnection() as HttpURLConnection
        } catch (e: Exception) {
            return Outcome(false, e.message ?: "not a web address")
        }
        return try {
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            conn.setRequestProperty("User-Agent", "OmniTerm alert forwarding")
            request.headers.forEach { (name, value) -> conn.setRequestProperty(name, value) }
            val bytes = request.body.toByteArray(Charsets.UTF_8)
            conn.setFixedLengthStreamingMode(bytes.size)
            conn.outputStream.use { it.write(bytes) }
            val status = conn.responseCode
            when {
                status in 200..299 -> Outcome(true, "HTTP $status", status)
                status in 300..399 -> Outcome(false, "HTTP $status: redirected to ${conn.getHeaderField("Location") ?: "another address"}; enter that address instead", status)
                else -> Outcome(false, "HTTP $status" + (conn.responseMessage?.takeIf { it.isNotBlank() }?.let { " $it" } ?: ""), status)
            }
        } catch (e: IOException) {
            Outcome(false, e.message ?: e.javaClass.simpleName)
        } finally {
            conn.disconnect()
        }
    }

    /** Worth trying again: no answer, or the server's own error. A refusal (4xx) or redirect is not. */
    fun isRetryable(outcome: Outcome): Boolean = !outcome.ok && (outcome.status == null || outcome.status >= 500)

    private val TOPIC = Regex("[A-Za-z0-9_-]{1,64}")

    private fun webAddress(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty()) return null
        return uri.toString()
    }

    // ntfy priorities run 1 (min) to 5 (max); Gotify's 0 to 10, where clients alert from 4 or so.
    private fun ntfyPriority(event: Event) = when {
        event.resolved -> 3
        event.severity == "CRITICAL" -> 5
        else -> 4
    }

    private fun gotifyPriority(event: Event) = when {
        event.resolved -> 2
        event.severity == "CRITICAL" -> 8
        else -> 5
    }

    private fun isoTime(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(ms))

    /** A JSON object of strings, numbers and string lists, in the given order. */
    internal fun json(vararg fields: Pair<String, Any>): String = fields.joinToString(",", "{", "}") { (key, value) ->
        quote(key) + ":" + when (value) {
            is String -> quote(value)
            is Float -> if (value.isFinite()) value.toString() else "null"
            is Number -> value.toString()
            is List<*> -> value.joinToString(",", "[", "]") { quote(it.toString()) }
            else -> quote(value.toString())
        }
    }

    internal fun quote(s: String): String = buildString(s.length + 2) {
        append('"')
        for (c in s) {
            when {
                c == '"' -> append("\\\"")
                c == '\\' -> append("\\\\")
                c == '\n' -> append("\\n")
                c == '\r' -> append("\\r")
                c == '\t' -> append("\\t")
                c < ' ' || c == '\u2028' || c == '\u2029' -> append("\\u").append(c.code.toString(16).padStart(4, '0'))
                else -> append(c)
            }
        }
        append('"')
    }
}
