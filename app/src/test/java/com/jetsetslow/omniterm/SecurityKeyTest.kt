package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.fido.SecurityKeyCtap
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.KeyboardInteractiveUserInfo
import com.jetsetslow.omniterm.data.ssh.NEEDS_SECURITY_KEY
import com.jetsetslow.omniterm.data.ssh.OpenSshKeyFile
import com.jetsetslow.omniterm.data.ssh.SecurityKeyAssertion
import com.jetsetslow.omniterm.data.ssh.SecurityKeyIdentity
import com.jetsetslow.omniterm.data.ssh.SecurityKeySignRequest
import com.jetsetslow.omniterm.data.ssh.SkKey
import com.jetsetslow.omniterm.data.ssh.SkKeyType
import com.jetsetslow.omniterm.data.ssh.SshKeyMaterial
import com.jetsetslow.omniterm.data.ssh.SshReader
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.SshWriter
import com.jetsetslow.omniterm.data.ssh.signInFailureMessage
import java.math.BigInteger
import java.security.KeyPairGenerator
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
import org.junit.Test
import java.security.SecureRandom

/**
 * Security key sign-in, against a software authenticator that signs the way a FIDO2 key does
 * (authenticator data, then the client data hash), checked the way OpenSSH's sshd checks it
 * (ssh-ed25519-sk.c, ssh-ecdsa-sk.c).
 */
class SecurityKeyTest {
    /** A FIDO2 authenticator in software: one credential, user presence always given. */
    private class SoftwareKey(val type: SkKeyType) {
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

    @Test
    fun signsInTheWaySshdChecks() {
        for (type in SkKeyType.entries) {
            val token = SoftwareKey(type)
            val key = token.sshKey()
            var asked: SecurityKeySignRequest? = null
            val ask = object : InteractiveAuth {
                override suspend fun answer(request: com.jetsetslow.omniterm.data.ssh.InteractiveAuthRequest) = null
                override suspend fun signWithSecurityKey(request: SecurityKeySignRequest): SecurityKeyAssertion {
                    asked = request
                    return token.assert(request)
                }
            }
            val signIn = KeyboardInteractiveUserInfo(null, ask)
            val identity = SecurityKeyIdentity(key, "test", "me@host", ask, signIn)
            assertThat(identity.algName).isEqualTo(type.sshName)
            assertThat(identity.publicKeyBlob).isEqualTo(key.publicBlob)

            val data = "userauth request".toByteArray()
            val blob = identity.getSignature(data, identity.algName)!!
            assertThat(token.sshdAccepts(blob, data)).isTrue()
            assertThat(token.sshdAccepts(blob, "other data".toByteArray())).isFalse()
            assertThat(asked!!.destination).isEqualTo("me@host")
            assertThat(asked!!.clientDataHash).isEqualTo(SshWire.sha256(data))
            assertThat(signIn.answeredByUser).isTrue()
        }
    }

    @Test
    fun withNobodyToTouchTheKeyItSaysSo() {
        val key = SoftwareKey(SkKeyType.Ed25519).sshKey()
        val signIn = KeyboardInteractiveUserInfo(null, null)
        assertThat(SecurityKeyIdentity(key, "test", "me@host", null, signIn).getSignature(ByteArray(8), key.type.sshName)).isNull()
        assertThat(signIn.neededUser).isTrue()

        val session = com.jcraft.jsch.JSch().getSession("me", "host", 22).apply { userInfo = signIn }
        assertThat(signInFailureMessage(session, Exception("Auth fail"))).isEqualTo(NEEDS_SECURITY_KEY)

        val cancelled = KeyboardInteractiveUserInfo(null, InteractiveAuth { null })
        assertThat(SecurityKeyIdentity(key, "test", "me@host", InteractiveAuth { null }, cancelled).getSignature(ByteArray(8), key.type.sshName))
            .isNull()
        assertThat(cancelled.cancelledByUser).isTrue()
    }

    @Test
    fun keyFilesRoundTripLikeSshKeygens() {
        for (type in SkKeyType.entries) {
            val key = SoftwareKey(type).sshKey(SkKey.USER_PRESENCE_REQUIRED or SkKey.USER_VERIFICATION_REQUIRED)
            val file = key.keyFile("laptop")
            assertThat(file).startsWith("-----BEGIN OPENSSH PRIVATE KEY-----")
            assertThat(OpenSshKeyFile.keyType(file)).isEqualTo(type.sshName)
            val back = SkKey.fromFile(OpenSshKeyFile.read(file, null))
            assertThat(back.publicBlob).isEqualTo(key.publicBlob)
            assertThat(back.keyHandle).isEqualTo(key.keyHandle)
            assertThat(back.requiresPin).isTrue()
            assertThat(back.requiresTouch).isTrue()

            // Importing it reads the security key's public key and keeps the file as it is.
            val prepared = SshKeyMaterial.prepare(file)
            assertThat(prepared.keyType).isEqualTo(type.label)
            assertThat(prepared.publicKey).isEqualTo(SshWire.publicLine(key.publicBlob, "laptop"))
            assertThat(prepared.fingerprint).isEqualTo(SshWire.fingerprint(key.publicBlob))
            assertThat(prepared.privateKey).isEqualTo(file.trim())
        }
    }

    @Test
    fun publicKeysComeFromTheSecurityKeysCoseKey() {
        val x = ByteArray(32) { 1 }
        val y = ByteArray(32) { 2 }
        assertThat(SecurityKeyCtap.publicKey(SkKeyType.Ed25519, mapOf(1 to 1, 3 to -8, -1 to 6, -2 to x))).isEqualTo(x)
        assertThat(SecurityKeyCtap.publicKey(SkKeyType.EcdsaP256, mapOf(1 to 2, 3 to -7, -1 to 1, -2 to x, -3 to y)))
            .isEqualTo(byteArrayOf(4) + x + y)
    }
}
