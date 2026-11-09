package com.jetsetslow.omniterm.data

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * An `ssh://` link, as a web page, a chat or another app hands it over:
 * `ssh://[user[;parameters][:password]@]host[:port][/…]`, as the IETF draft for SSH URIs writes it.
 *
 * Only the user, host and port are read. A password in the link is dropped and never shown or kept,
 * and so are the draft's parameters: a host key is checked by the usual first-connect prompt, not by
 * a fingerprint someone else wrote into a link. Anything after the address (a trailing slash, a
 * path, a query) is ignored rather than read as part of it, the bug electerm#4357 reported.
 */
data class SshLink(val host: String, val port: Int, val user: String?) {

    /** How the link reads to the user, without what was dropped. */
    val label: String get() = user?.let { "$it@$address" } ?: address

    /** The link again as `ssh://` text, which [parse] reads back to this same link. */
    val uri: String get() = "$SCHEME://" + (user?.let { "${percentEncoded(it)}@" } ?: "") + address

    private val address: String
        get() = (if (':' in host) "[$host]" else host) + (if (port != DEFAULT_PORT) ":$port" else "")

    /** True when [srv] is this link's host: the same address and port, and its user if the link names one. */
    fun matches(srv: ServerEntity, loginName: String): Boolean =
        srv.host.trim().removeSurrounding("[", "]").equals(host, ignoreCase = true) &&
            srv.port == port &&
            (user == null || loginName == user)

    companion object {
        const val SCHEME = "ssh"
        const val DEFAULT_PORT = 22
        private const val MAX_USER = 256
        private const val HEX = "0123456789ABCDEF"

        /** The link in [text], or null when it is not a usable `ssh://` link. */
        fun parse(text: String): SshLink? {
            val t = text.trim()
            val prefix = "$SCHEME://"
            if (!t.startsWith(prefix, ignoreCase = true)) return null
            val authority = t.substring(prefix.length).takeWhile { it !in "/?#" }
            val at = authority.lastIndexOf('@')
            val user = if (at < 0) null else userFrom(authority.substring(0, at)) ?: return null
            val (host, port) = EndpointChecks.hostAndPort(authority.substring(at + 1), DEFAULT_PORT) ?: return null
            val checked = EndpointChecks.pingHost(host) ?: return null
            return SshLink(checked, port, user.takeUnless { it.isNullOrEmpty() })
        }

        /** The user in a link's user part, without its parameters or password; null when it is malformed. */
        private fun userFrom(userInfo: String): String? {
            val raw = userInfo.substringBefore(';').substringBefore(':')
            val user = percentDecoded(raw) ?: return null
            if (user.length > MAX_USER || user.startsWith("-") || user.any { it.isISOControl() }) return null
            return user
        }

        /** [s] with everything but unreserved characters written as `%XX` UTF-8 escapes. */
        private fun percentEncoded(s: String): String = buildString {
            for (b in s.toByteArray(Charsets.UTF_8)) {
                val v = b.toInt() and 0xFF
                val c = v.toChar()
                if (v < 0x80 && (c.isLetterOrDigit() || c in "-._~")) append(c)
                else append('%').append(HEX[v shr 4]).append(HEX[v and 0xF])
            }
        }

        /** [s] with its `%XX` escapes read as UTF-8; null when an escape is malformed. */
        private fun percentDecoded(s: String): String? {
            if ('%' !in s) return s
            val out = ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    val hex = s.substring(i + 1, minOf(i + 3, s.length))
                    // toIntOrNull(16) alone would take a sign, as in "%+1".
                    if (hex.length != 2 || !hex.all { it in "0123456789abcdefABCDEF" }) return null
                    out.write(hex.toInt(16))
                    i += 3
                } else {
                    out.write(c.toString().toByteArray(Charsets.UTF_8))
                    i++
                }
            }
            return runCatching { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(out.toByteArray())).toString() }.getOrNull()
        }
    }
}
