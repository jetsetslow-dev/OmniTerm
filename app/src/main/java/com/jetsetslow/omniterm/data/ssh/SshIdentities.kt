package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Identity
import com.jcraft.jsch.KeyPair
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** A JSch [KeyPair] as an [Identity], for wrapping in a [CertificateIdentity]. */
internal class KeyPairIdentity(private val keyPair: KeyPair, private val name: String) : Identity {
    override fun getAlgName(): String = SshWire.algorithm(keyPair.publicKeyBlob)
    override fun getPublicKeyBlob(): ByteArray = keyPair.publicKeyBlob
    override fun getSignature(data: ByteArray): ByteArray? = keyPair.getSignature(data)
    override fun getSignature(data: ByteArray, alg: String): ByteArray? = keyPair.getSignature(data, alg)
    override fun getName(): String = name
    override fun isEncrypted(): Boolean = keyPair.isEncrypted
    override fun setPassphrase(passphrase: ByteArray?): Boolean = keyPair.decrypt(passphrase)
    override fun decrypt(): Boolean = !keyPair.isEncrypted
    override fun clear() = keyPair.dispose()
}

/**
 * Offers [certificate] in place of [inner]'s bare key and signs with [inner], as OpenSSH does with
 * a `-cert.pub` file beside the key.
 */
internal class CertificateIdentity(private val inner: Identity, private val certificate: SshCertificate) : Identity {
    // SHA-1 RSA (ssh-rsa-cert) is refused by OpenSSH 8.8 and later; offer the SHA-512 form.
    override fun getAlgName(): String =
        if (certificate.keyType == "ssh-rsa") RSA_SHA512_CERT else certificate.type

    override fun getPublicKeyBlob(): ByteArray = certificate.blob

    override fun getSignature(data: ByteArray): ByteArray? = getSignature(data, algName)

    override fun getSignature(data: ByteArray, alg: String): ByteArray? =
        inner.getSignature(data, signatureAlgorithm(alg))

    private fun signatureAlgorithm(alg: String): String = when (alg) {
        RSA_SHA512_CERT -> "rsa-sha2-512"
        RSA_SHA256_CERT -> "rsa-sha2-256"
        else -> inner.algName
    }

    override fun getName(): String = inner.name + "-cert"
    override fun isEncrypted(): Boolean = inner.isEncrypted
    override fun setPassphrase(passphrase: ByteArray?): Boolean = inner.setPassphrase(passphrase)
    override fun decrypt(): Boolean = inner.decrypt()
    override fun clear() = inner.clear()

    companion object {
        const val RSA_SHA512_CERT = "rsa-sha2-512-cert-v01@openssh.com"
        const val RSA_SHA256_CERT = "rsa-sha2-256-cert-v01@openssh.com"
    }
}

/**
 * A key on a FIDO security key. Each signature asks [ask] to have the user touch the key; without
 * anyone to ask (background work) it signs nothing, and [signIn] records why.
 *
 * JSch's own sign-in asks with the algorithm ([UserAuthPublicKey]); only agent forwarding asks
 * without one (ChannelAgentForwarding, for every key but RSA), when a program on the host signs in
 * somewhere else with this key. That request is answered on the thread that reads the whole
 * connection, so nothing else on it moves until the key answers: it waits [forwardedTimeoutMs],
 * within the time servers commonly allow for a keepalive reply, rather than [timeoutMs].
 */
internal class SecurityKeyIdentity(
    private val key: SkKey,
    private val name: String,
    private val destination: String,
    private val ask: InteractiveAuth?,
    private val signIn: KeyboardInteractiveUserInfo,
    private val timeoutMs: Long = KeyboardInteractiveUserInfo.PROMPT_TIMEOUT_MS,
    private val forwardedTimeoutMs: Long = FORWARDED_PROMPT_TIMEOUT_MS,
) : Identity {
    override fun getAlgName(): String = key.type.sshName
    override fun getPublicKeyBlob(): ByteArray = key.publicBlob
    override fun getSignature(data: ByteArray): ByteArray? = sign(data, forwarded = true)
    override fun getSignature(data: ByteArray, alg: String): ByteArray? = sign(data, forwarded = false)

    private fun sign(data: ByteArray, forwarded: Boolean): ByteArray? {
        val ask = ask ?: run {
            if (!forwarded) signIn.securityKeyNeeded()
            return null
        }
        val request = SecurityKeySignRequest(
            destination,
            key,
            SshWire.sha256(data),
            forwarded = forwarded,
            forwardedUser = if (forwarded) signInUser(data) else null,
        )
        val wait = if (forwarded) forwardedTimeoutMs else timeoutMs
        val assertion = runBlocking { withTimeoutOrNull(wait) { ask.signWithSecurityKey(request) } }
        // A forwarded request is someone else's sign-in: it says nothing about this connection's own.
        if (assertion == null) {
            if (!forwarded) signIn.securityKeyCancelled()
            return null
        }
        if (!forwarded) signIn.securityKeyUsed()
        return SecurityKeySignatures.encode(key.type, assertion)
    }

    companion object {
        const val FORWARDED_PROMPT_TIMEOUT_MS = 20_000L

        /**
         * The user [data] signs in as, when it is an SSH public key sign-in (RFC 4252 §7: session
         * id, then SSH_MSG_USERAUTH_REQUEST, user, service, "publickey"); null for anything else.
         */
        internal fun signInUser(data: ByteArray): String? = runCatching {
            val reader = SshReader(data)
            reader.bytes()
            if (reader.byte() != SSH_MSG_USERAUTH_REQUEST) return null
            val user = reader.string()
            reader.string()
            if (reader.string() != "publickey") return null
            user
        }.getOrNull()

        private const val SSH_MSG_USERAUTH_REQUEST = 50
    }

    override fun getName(): String = name
    override fun isEncrypted(): Boolean = false
    override fun setPassphrase(passphrase: ByteArray?): Boolean = true
    override fun clear() = Unit
}
