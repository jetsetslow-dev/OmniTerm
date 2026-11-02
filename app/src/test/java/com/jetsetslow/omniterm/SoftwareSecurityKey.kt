package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ssh.SecurityKeyAssertion
import com.jetsetslow.omniterm.data.ssh.SecurityKeySignRequest
import com.jetsetslow.omniterm.data.ssh.SkKey
import com.jetsetslow.omniterm.data.ssh.SkKeyType
import com.jetsetslow.omniterm.data.ssh.SshReader
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.SshWriter
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import org.bouncycastle.asn1.ASN1EncodableVector
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.DERSequence
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

/**
 * A FIDO2 authenticator in software: one credential, user presence always given. It signs the way
 * a FIDO2 key does (authenticator data, then the client data hash) and checks the way OpenSSH's sshd
 * checks (ssh-ed25519-sk.c, ssh-ecdsa-sk.c).
 */
internal class SoftwareSecurityKey(val type: SkKeyType) {
    private val ed25519 = if (type == SkKeyType.Ed25519) {
        Ed25519KeyPairGenerator().apply { init(Ed25519KeyGenerationParameters(SecureRandom())) }.generateKeyPair()
    } else {
        null
    }
    private val ecdsa = if (type == SkKeyType.EcdsaP256) {
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    } else {
        null
    }
    var counter = 41L

    val publicKey: ByteArray = when (type) {
        SkKeyType.Ed25519 -> (ed25519!!.public as Ed25519PublicKeyParameters).encoded
        SkKeyType.EcdsaP256 -> {
            val point = (ecdsa!!.public as ECPublicKey).w
            byteArrayOf(4) + fixed(point.affineX) + fixed(point.affineY)
        }
    }

    fun sshKey(flags: Int = SkKey.USER_PRESENCE_REQUIRED) =
        SkKey(type, publicKey, SkKey.DEFAULT_APPLICATION, flags, byteArrayOf(9, 8, 7, 6))

    fun assert(request: SecurityKeySignRequest): SecurityKeyAssertion {
        counter++
        val authData = SshWire.sha256(request.key.application.toByteArray()) + byteArrayOf(0x01) +
            SshWriter().uint32(counter).toByteArray()
        val signed = authData + request.clientDataHash
        val signature = when (type) {
            SkKeyType.Ed25519 -> Ed25519Signer().run {
                init(true, ed25519!!.private as Ed25519PrivateKeyParameters)
                update(signed, 0, signed.size)
                generateSignature()
            }
            SkKeyType.EcdsaP256 -> Signature.getInstance("SHA256withECDSA").run {
                initSign(ecdsa!!.private)
                update(signed)
                sign() // DER, as CTAP returns it
            }
        }
        return SecurityKeyAssertion(authData, signature)
    }

    /** sshd's check of a signature blob over [data]. */
    fun sshdAccepts(blob: ByteArray, data: ByteArray, application: String = SkKey.DEFAULT_APPLICATION): Boolean {
        val reader = SshReader(blob)
        if (reader.string() != type.sshName) return false
        val signature = reader.bytes()
        val flags = reader.byte()
        val counter = reader.uint32()
        if (flags and 0x01 == 0) return false // user presence not set
        val message = SshWire.sha256(application.toByteArray()) + byteArrayOf(flags.toByte()) +
            SshWriter().uint32(counter).toByteArray() + SshWire.sha256(data)
        return when (type) {
            SkKeyType.Ed25519 -> Ed25519Signer().run {
                init(false, Ed25519PublicKeyParameters(publicKey, 0))
                update(message, 0, message.size)
                verifySignature(signature)
            }
            SkKeyType.EcdsaP256 -> {
                val rs = SshReader(signature)
                val der = DERSequence(
                    ASN1EncodableVector().apply {
                        add(ASN1Integer(BigInteger(rs.bytes())))
                        add(ASN1Integer(BigInteger(rs.bytes())))
                    },
                ).encoded
                Signature.getInstance("SHA256withECDSA").run {
                    initVerify(ecdsa!!.public)
                    update(message)
                    verify(der)
                }
            }
        }
    }

    private fun fixed(value: BigInteger): ByteArray = value.toByteArray().takeLast(32).toByteArray().let {
        ByteArray(32 - it.size) + it
    }
}
