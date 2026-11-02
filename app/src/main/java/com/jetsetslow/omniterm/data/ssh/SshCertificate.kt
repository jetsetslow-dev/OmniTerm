package com.jetsetslow.omniterm.data.ssh

import org.bouncycastle.util.encoders.Base64

/**
 * An OpenSSH certificate (PROTOCOL.certkeys): a public key a certificate authority signed, naming
 * who may sign in with it and until when. Servers that trust the authority accept it without the
 * key in `authorized_keys`.
 */
class SshCertificate private constructor(
    /** The certificate's algorithm, such as `ssh-ed25519-cert-v01@openssh.com`. */
    val type: String,
    val blob: ByteArray,
    /** The certified key's own public blob. */
    val keyBlob: ByteArray,
    val isUserCertificate: Boolean,
    val keyId: String,
    /** The user names it is valid for; empty means any. */
    val principals: List<String>,
    /** Seconds since the epoch. */
    val validAfter: Long,
    /** Seconds since the epoch; [Long.MAX_VALUE] when it never expires. */
    val validBefore: Long,
    /** The fingerprint of the authority that signed it. */
    val authorityFingerprint: String,
) {
    /** The certified key's type, such as `ssh-ed25519`. */
    val keyType: String get() = keyTypeOf(type)

    fun isExpired(nowSeconds: Long): Boolean = nowSeconds >= validBefore

    fun isNotYetValid(nowSeconds: Long): Boolean = nowSeconds < validAfter

    companion object {
        private const val SUFFIX = "-cert-v01@openssh.com"
        private const val USER_CERT = 1L

        /** The certified key's type for a certificate type: `sk-` types keep their `@openssh.com`. */
        fun keyTypeOf(certificateType: String): String {
            val base = certificateType.removeSuffix(SUFFIX)
            return if (base.startsWith("sk-")) "$base@openssh.com" else base
        }

        /** How many length-prefixed public fields each key type puts after the nonce. */
        private fun publicFieldCount(keyType: String): Int? = when (keyType) {
            "ssh-ed25519" -> 1
            "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
            SkKeyType.Ed25519.sshName -> 2
            SkKeyType.EcdsaP256.sshName -> 3
            "ssh-dss" -> 4
            else -> null
        }

        /** Reads a `-cert.pub` file's line. Throws IllegalArgumentException, saying why, when it is none. */
        fun parse(text: String): SshCertificate {
            val parts = text.trim().split(Regex("\\s+"))
            val type = parts.firstOrNull().orEmpty()
            if (!type.endsWith(SUFFIX)) {
                throw IllegalArgumentException(
                    "That is not an SSH certificate. Paste the -cert.pub file ssh-keygen -s made, starting with a type ending in $SUFFIX.",
                )
            }
            val blob = parts.getOrNull(1)?.let { runCatching { Base64.decode(it) }.getOrNull() }
                ?: throw IllegalArgumentException("This certificate is damaged: its data is not valid base64.")
            return try {
                read(type, blob)
            } catch (e: IllegalArgumentException) {
                throw IllegalArgumentException("This certificate is damaged: ${e.message}")
            }
        }

        private fun read(type: String, blob: ByteArray): SshCertificate {
            val reader = SshReader(blob)
            if (reader.string() != type) throw IllegalArgumentException("its type does not match its data.")
            val keyType = keyTypeOf(type)
            val fields = publicFieldCount(keyType) ?: throw IllegalArgumentException("OmniTerm cannot use $keyType certificates.")
            reader.bytes() // nonce
            val keyBlob = SshWriter().string(keyType).apply { repeat(fields) { bytes(reader.bytes()) } }.toByteArray()
            reader.uint64() // serial
            val certType = reader.uint32()
            val keyId = reader.string()
            val principals = SshReader(reader.bytes()).let { list ->
                buildList { while (list.remaining > 0) add(list.string()) }
            }
            val validAfter = reader.uint64()
            val validBefore = reader.uint64().let { if (it < 0) Long.MAX_VALUE else it }
            reader.bytes() // critical options
            reader.bytes() // extensions
            reader.bytes() // reserved
            val authority = reader.bytes()
            reader.bytes() // the authority's signature
            return SshCertificate(
                type = type,
                blob = blob,
                keyBlob = keyBlob,
                isUserCertificate = certType == USER_CERT,
                keyId = keyId,
                principals = principals,
                validAfter = validAfter.coerceAtLeast(0),
                validBefore = validBefore,
                authorityFingerprint = SshWire.fingerprint(authority),
            )
        }

        /**
         * Why [certificate] cannot go with the key whose public blob is [keyBlob], or null when it
         * can: it must certify that very key, for signing in as a user.
         */
        fun mismatch(certificate: SshCertificate, keyBlob: ByteArray?): String? = when {
            !certificate.isUserCertificate ->
                "That is a host certificate. Use the user certificate ssh-keygen -s made for this key."
            keyBlob == null || !certificate.keyBlob.contentEquals(keyBlob) ->
                "This certificate is for a different key. Use the -cert.pub file made from this key's .pub file."
            else -> null
        }
    }
}
