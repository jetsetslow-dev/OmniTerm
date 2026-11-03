package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import com.jcraft.jsch.jbcrypt.BCrypt
import com.jetsetslow.omniterm.data.ssh.OpenSshKeyFile
import com.jetsetslow.omniterm.data.ssh.SshKeyMaterial
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.SshWriter
import com.jetsetslow.omniterm.data.ssh.looksLikePublicKey
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.util.encoders.Base64
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Keys protected by a passphrase. Nothing asks for a passphrase when connecting, so such a key
 * used to import fine and then fail every sign-in; now import opens it and stores it opened.
 */
class SshKeyPassphraseTest {
    @Test
    fun aPemKeyIsOpenedOnceAndStoredOpen() {
        for (type in listOf(KeyPair.RSA, KeyPair.ECDSA)) {
            val key = KeyPair.genKeyPair(JSch(), type, if (type == KeyPair.RSA) 2048 else 256)
            val protected = ByteArrayOutputStream().also { key.writePrivateKey(it, "correct horse".toByteArray()) }.toString()
            assertThat(protected).contains("ENCRYPTED")

            assertThrows(OpenSshKeyFile.PassphraseNeeded::class.java) { SshKeyMaterial.prepare(protected) }
            assertThrows(OpenSshKeyFile.WrongPassphrase::class.java) { SshKeyMaterial.prepare(protected, passphrase = "wrong") }
            val prepared = SshKeyMaterial.prepare(protected, passphrase = "correct horse")

            val stored = KeyPair.load(JSch(), prepared.privateKey.toByteArray(), null)
            assertThat(stored.isEncrypted).isFalse()
            assertThat(stored.publicKeyBlob).isEqualTo(key.publicKeyBlob)
            assertThat(prepared.fingerprint).isEqualTo(SshWire.fingerprint(key.publicKeyBlob))
        }
    }

    @Test
    fun anOpenSshKeyIsOpenedOnceAndStoredOpen() {
        val (file, publicKey) = protectedEd25519("correct horse")
        assertThat(OpenSshKeyFile.isEncrypted(file)).isTrue()
        assertThrows(OpenSshKeyFile.PassphraseNeeded::class.java) { SshKeyMaterial.prepare(file) }
        assertThrows(OpenSshKeyFile.WrongPassphrase::class.java) { SshKeyMaterial.prepare(file, passphrase = "wrong") }

        val prepared = SshKeyMaterial.prepare(file, passphrase = "correct horse")
        assertThat(OpenSshKeyFile.isEncrypted(prepared.privateKey)).isFalse()
        assertThat(prepared.keyType).isEqualTo("ED25519")
        assertThat(prepared.publicKey).isEqualTo("ssh-ed25519 ${Base64.toBase64String(edBlob(publicKey))} me@laptop")

        // JSch, which signs at connect time, reads the stored key without a passphrase.
        val stored = KeyPair.load(JSch(), prepared.privateKey.toByteArray(), null)
        assertThat(stored.isEncrypted).isFalse()
        val data = "sign me".toByteArray()
        val signature = com.jetsetslow.omniterm.data.ssh.SshReader(stored.getSignature(data)).run { string(); bytes() }
        val verifier = Ed25519Signer().apply { init(false, Ed25519PublicKeyParameters(publicKey, 0)); update(data, 0, data.size) }
        assertThat(verifier.verifySignature(signature)).isTrue()
    }

    @Test
    fun theGivenPublicKeyMustMatch() {
        val key = KeyPair.genKeyPair(JSch(), KeyPair.ECDSA, 256)
        val pem = ByteArrayOutputStream().also { key.writePrivateKey(it) }.toString()
        val line = ByteArrayOutputStream().also { key.writePublicKey(it, "mine") }.toString()
        assertThat(SshKeyMaterial.prepare(pem, publicKey = line).publicKey).isEqualTo(line.trim())
        val other = ByteArrayOutputStream().also { KeyPair.genKeyPair(JSch(), KeyPair.ECDSA, 256).writePublicKey(it, "other") }.toString()
        assertThrows(IllegalArgumentException::class.java) { SshKeyMaterial.prepare(pem, publicKey = other) }
        // Pasting a public key, a security key's included, where the private one goes.
        assertThat(looksLikePublicKey("sk-ssh-ed25519@openssh.com AAAA me")).isTrue()
        assertThrows(IllegalArgumentException::class.java) { SshKeyMaterial.prepare(line) }
    }

    private fun edBlob(publicKey: ByteArray) = SshWriter().string("ssh-ed25519").bytes(publicKey).toByteArray()

    /** An Ed25519 key in OpenSSH's own format, protected as `ssh-keygen -N` does: bcrypt and aes256-ctr. */
    private fun protectedEd25519(passphrase: String): Pair<String, ByteArray> {
        val pair = Ed25519KeyPairGenerator().apply { init(Ed25519KeyGenerationParameters(SecureRandom())) }.generateKeyPair()
        val publicKey = (pair.public as Ed25519PublicKeyParameters).encoded
        val seed = (pair.private as Ed25519PrivateKeyParameters).encoded
        val check = 0x12345678L
        var section = SshWriter().uint32(check).uint32(check).string("ssh-ed25519")
            .bytes(publicKey).bytes(seed + publicKey).string("me@laptop").toByteArray()
        section += ByteArray((16 - section.size % 16) % 16) { (it + 1).toByte() }
        val salt = ByteArray(16).also(SecureRandom()::nextBytes)
        val derived = ByteArray(48)
        BCrypt().pbkdf(passphrase.toByteArray(), salt, 16, derived)
        val cipher = Cipher.getInstance("AES/CTR/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(derived.copyOfRange(0, 32), "AES"), IvParameterSpec(derived.copyOfRange(32, 48)))
        }
        val body = SshWriter().raw("openssh-key-v1\u0000".toByteArray()).string("aes256-ctr").string("bcrypt")
            .bytes(SshWriter().bytes(salt).uint32(16).toByteArray())
            .uint32(1).bytes(edBlob(publicKey)).bytes(cipher.doFinal(section)).toByteArray()
        val file = pemBegin("OPENSSH PRIVATE KEY") + "\n" + Base64.toBase64String(body).chunked(70).joinToString("\n") +
            "\n" + pemEnd("OPENSSH PRIVATE KEY") + "\n"
        return file to publicKey
    }
}
