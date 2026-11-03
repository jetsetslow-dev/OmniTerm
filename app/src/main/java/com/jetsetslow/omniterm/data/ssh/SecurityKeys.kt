package com.jetsetslow.omniterm.data.ssh

import java.math.BigInteger
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1Sequence

/** The two kinds of SSH key a FIDO security key holds; [coseAlgorithm] is what CTAP calls them. */
enum class SkKeyType(val sshName: String, val coseAlgorithm: Int, val label: String) {
    Ed25519("sk-ssh-ed25519@openssh.com", -8, "ED25519-SK"),
    EcdsaP256("sk-ecdsa-sha2-nistp256@openssh.com", -7, "ECDSA-SK"),
    ;

    companion object {
        fun of(sshName: String): SkKeyType? = entries.firstOrNull { it.sshName == sshName }
    }
}

/**
 * An SSH key that lives on a FIDO security key, as OpenSSH's `ssh-keygen -t ed25519-sk` makes it
 * (PROTOCOL.u2f). The private key never leaves the security key: OmniTerm keeps [keyHandle], which
 * the security key needs to find it, and has the key sign each sign-in.
 */
class SkKey(
    val type: SkKeyType,
    /** 32 bytes for Ed25519; an uncompressed P-256 point (65 bytes) for ECDSA. */
    val publicKey: ByteArray,
    /** The FIDO relying party the key was made for: "ssh:" unless the user chose another. */
    val application: String,
    val flags: Int,
    val keyHandle: ByteArray,
) {
    val requiresTouch: Boolean get() = flags and USER_PRESENCE_REQUIRED != 0
    val requiresPin: Boolean get() = flags and USER_VERIFICATION_REQUIRED != 0

    val publicBlob: ByteArray
        get() = SshWriter().string(type.sshName).apply {
            if (type == SkKeyType.EcdsaP256) string("nistp256")
        }.bytes(publicKey).string(application).toByteArray()

    /** This key as an `id_ed25519_sk` file: no secret in it, but useless without the security key. */
    fun keyFile(comment: String): String = OpenSshKeyFile.write(
        OpenSshKeyFile.Contents(publicBlob, type.sshName, privateFields(), comment),
    )

    private fun privateFields(): ByteArray = SshWriter().apply {
        if (type == SkKeyType.EcdsaP256) string("nistp256")
    }.bytes(publicKey).string(application).byte(flags).bytes(keyHandle).bytes(ByteArray(0)).toByteArray()

    companion object {
        const val USER_PRESENCE_REQUIRED = 0x01
        const val USER_VERIFICATION_REQUIRED = 0x04
        const val DEFAULT_APPLICATION = "ssh:"

        /** The security key in an OpenSSH key file's private fields ([OpenSshKeyFile.Contents]). */
        internal fun fromFile(contents: OpenSshKeyFile.Contents): SkKey {
            val type = SkKeyType.of(contents.keyType) ?: throw IllegalArgumentException("This is not a security key file.")
            val reader = SshReader(contents.keyFields)
            if (type == SkKeyType.EcdsaP256 && reader.string() != "nistp256") {
                throw IllegalArgumentException("This security key file names a curve OmniTerm does not know.")
            }
            return SkKey(type, reader.bytes(), reader.string(), reader.byte(), reader.bytes())
        }
    }
}

/** What a security key signs to sign in: [key]'s handle and the hash of the SSH sign-in data. */
class SecurityKeySignRequest(
    /** Where the key signs in to, as `user@host`; for a [forwarded] request, the host that asks. */
    val destination: String,
    val key: SkKey,
    /** SHA-256 of the data SSH signs; CTAP's clientDataHash, as OpenSSH sends it. */
    val clientDataHash: ByteArray,
    /** A program on [destination] asks through agent forwarding, to sign in somewhere else. */
    val forwarded: Boolean = false,
    /** The user a [forwarded] request signs in as there, when the data it signs says so. */
    val forwardedUser: String? = null,
)

/** A security key's answer: CTAP authenticator data and the signature over it and the client data hash. */
class SecurityKeyAssertion(val authenticatorData: ByteArray, val signature: ByteArray)

internal object SecurityKeySignatures {
    /** Bits of the authenticator data's flags byte (WebAuthn): the user touched the key, and the key checked who they are. */
    private const val USER_PRESENT = 0x01
    private const val USER_VERIFIED = 0x04

    /**
     * Why sshd would refuse [authenticatorData] for [key], or null: a key that requires a touch or
     * the PIN only accepts a signature whose flags say it had one.
     */
    fun missingConsent(key: SkKey, authenticatorData: ByteArray): String? {
        if (authenticatorData.size < 37) return "The security key's answer is too short."
        val flags = authenticatorData[32].toInt() and 0xff
        return when {
            key.requiresTouch && flags and USER_PRESENT == 0 ->
                "The security key signed without a touch, which this SSH key requires, so the server would refuse it. Try again."
            key.requiresPin && flags and USER_VERIFIED == 0 ->
                "The security key signed without checking your PIN, which this SSH key requires, so the server would refuse it. " +
                    "Try again, and if it happens again, set a PIN on the key with its maker's app."
            else -> null
        }
    }

    /**
     * [assertion] as the SSH signature blob for [type] (PROTOCOL.u2f): the algorithm, the raw
     * signature, then the flags and counter the security key signed over.
     */
    fun encode(type: SkKeyType, assertion: SecurityKeyAssertion): ByteArray {
        val data = assertion.authenticatorData
        if (data.size < 37) throw IllegalArgumentException("The security key's answer is too short.")
        val flags = data[32].toInt() and 0xff
        val counter = SshReader(data, 33).uint32()
        val signature = when (type) {
            SkKeyType.Ed25519 -> assertion.signature
            SkKeyType.EcdsaP256 -> {
                // CTAP returns DER; SSH wants the two integers as mpints.
                val sequence = ASN1Sequence.getInstance(assertion.signature)
                val r: BigInteger = ASN1Integer.getInstance(sequence.getObjectAt(0)).value
                val s: BigInteger = ASN1Integer.getInstance(sequence.getObjectAt(1)).value
                SshWriter().mpint(r).mpint(s).toByteArray()
            }
        }
        return SshWriter().string(type.sshName).bytes(signature).byte(flags).uint32(counter).toByteArray()
    }
}
