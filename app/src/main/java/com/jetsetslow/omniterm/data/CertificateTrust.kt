package com.jetsetslow.omniterm.data

import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSession
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Trust on first use for an HTTPS server with its own certificate, as SSH host keys are trusted:
 * a certificate the phone's CAs trust is accepted as usual; any other is accepted only when its
 * SHA-256 fingerprint is the one the user trusted, and otherwise refused with that fingerprint so
 * the app can show it and ask.
 */
object CertificateTrust {
    /** A certificate's SHA-256 fingerprint as Proxmox and OpenSSL print it: `AB:CD:…`. */
    fun fingerprint(certificate: X509Certificate): String =
        MessageDigest.getInstance("SHA-256").digest(certificate.encoded).joinToString(":") { "%02X".format(it) }

    /** Whether [a] and [b] are one fingerprint, however its bytes are separated or cased. */
    fun same(a: String, b: String): Boolean {
        fun norm(s: String) = s.filter { it.isLetterOrDigit() }.uppercase()
        return norm(a).isNotEmpty() && norm(a) == norm(b)
    }

    /** The phone's own CAs. */
    fun platformTrustManager(): X509TrustManager {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    /** The server's certificate is neither trusted by the phone nor the one the user trusted. */
    class Untrusted(val fingerprint: String, val changed: Boolean, cause: Throwable? = null) :
        CertificateException(if (changed) "The server's certificate changed" else "The server's certificate is not trusted yet", cause)

    /** The [Untrusted] refusal somewhere in [error]'s causes, if that is why it failed. */
    fun untrustedIn(error: Throwable?): Untrusted? =
        generateSequence(error) { it.cause.takeIf { cause -> cause !== it } }.filterIsInstance<Untrusted>().firstOrNull()

    /** Trusts the phone's CAs, or the one leaf certificate whose fingerprint is [pinned]. */
    class Pinned(private val pinned: String, private val platform: X509TrustManager = platformTrustManager()) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
            platform.checkClientTrusted(chain, authType)

        @Throws(CertificateException::class)
        override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
            if (chain.isEmpty()) throw CertificateException("The server sent no certificate")
            val presented = fingerprint(chain[0])
            if (same(presented, pinned)) return
            try {
                platform.checkServerTrusted(chain, authType)
            } catch (e: CertificateException) {
                throw Untrusted(presented, changed = pinned.isNotBlank(), cause = e)
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = platform.acceptedIssuers

        /**
         * Host names are checked as usual, except for the trusted certificate itself: a server's own
         * certificate seldom names the address it is reached at, and its fingerprint already says
         * it is that server.
         */
        fun hostnameVerifier(default: HostnameVerifier = HttpsURLConnection.getDefaultHostnameVerifier()) =
            HostnameVerifier { host: String, session: SSLSession ->
                val leaf = runCatching { session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull()
                (leaf != null && same(fingerprint(leaf), pinned)) || default.verify(host, session)
            }
    }
}
