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
 */
internal class SecurityKeyIdentity(
    private val key: SkKey,
    private val name: String,
    private val destination: String,
    private val ask: InteractiveAuth?,
    private val signIn: KeyboardInteractiveUserInfo,
    private val timeoutMs: Long = KeyboardInteractiveUserInfo.PROMPT_TIMEOUT_MS,
) : Identity {
    override fun getAlgName(): String = key.type.sshName
    override fun getPublicKeyBlob(): ByteArray = key.publicBlob
    override fun getSignature(data: ByteArray): ByteArray? = getSignature(data, algName)

    override fun getSignature(data: ByteArray, alg: String): ByteArray? {
        val ask = ask ?: run {
            signIn.securityKeyNeeded()
            return null
        }
        val request = SecurityKeySignRequest(destination, key, SshWire.sha256(data))
        val assertion = runBlocking { withTimeoutOrNull(timeoutMs) { ask.signWithSecurityKey(request) } }
        if (assertion == null) {
            signIn.securityKeyCancelled()
            return null
        }
        signIn.securityKeyUsed()
        return SecurityKeySignatures.encode(key.type, assertion)
    }

    override fun getName(): String = name
    override fun isEncrypted(): Boolean = false
    override fun setPassphrase(passphrase: ByteArray?): Boolean = true
    override fun clear() = Unit
}
