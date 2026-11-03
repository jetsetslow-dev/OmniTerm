package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import com.jetsetslow.omniterm.data.ssh.CertificateIdentity
import com.jetsetslow.omniterm.data.ssh.KeyPairIdentity
import com.jetsetslow.omniterm.data.ssh.SshCertificate
import com.jetsetslow.omniterm.data.ssh.SshKeyMaterial
import com.jetsetslow.omniterm.data.ssh.SshReader
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.SshWriter
import java.io.ByteArrayOutputStream
import org.bouncycastle.util.encoders.Base64
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test

class SshCertificateTest {
    @get:Rule
    val jdkProviders = JdkSecurityProviders()

    /**
     * Made by OpenSSH 10.2's `ssh-keygen -s ca -I omniterm-test -n alice,bob -z 42 -V …` for
     * [REAL_KEY]. Public material only: the user's public key, the authority's, its signature.
     */
    private val realCertificate =
        "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIOQoNwQ0OojfTCS8pGEPB7wtruyiHLh7uPH+CKVG+XQLAAAAIGRLHcRbaksxjhQ5QS0valxLQlaVLOD7SNmI64fRoDCaAAAAAAAAACoAAAABAAAADW9tbml0ZXJtLXRlc3QAAAAQAAAABWFsaWNlAAAAA2JvYgAAAABpVWuoAAAAAHwkEagAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACAY7jAncTctG9RZropei1seSQF0ezXkCp23D8sV96VvOAAAAFMAAAALc3NoLWVkMjU1MTkAAABALxyZ57DvQD2epyXRwezRmiScy2cE15kGrt2zRKfW6H4/RHng6kRIFvVMTuVPHWEeAE44jtglaPuZq6WKBkV9BA== user"

    @Test
    fun readsWhatSshKeygenWrote() {
        val cert = SshCertificate.parse(realCertificate)
        // As `ssh-keygen -L` reports it.
        assertThat(cert.type).isEqualTo("ssh-ed25519-cert-v01@openssh.com")
        assertThat(cert.keyType).isEqualTo("ssh-ed25519")
        assertThat(cert.isUserCertificate).isTrue()
        assertThat(cert.keyId).isEqualTo("omniterm-test")
        assertThat(cert.principals).containsExactly("alice", "bob").inOrder()
        assertThat(cert.validAfter).isEqualTo(1_767_205_800L)
        assertThat(cert.validBefore).isEqualTo(2_082_738_600L)
        assertThat(cert.authorityFingerprint).isEqualTo("SHA256:iAzxxhmTMWtlSSOcq/44voqRu9pwWat/ZO7reT+N30c")
        assertThat(SshWire.publicLine(cert.keyBlob, "user")).isEqualTo(REAL_KEY)
        assertThat(cert.isExpired(2_082_738_600L)).isTrue()
        assertThat(cert.isNotYetValid(1_767_205_799L)).isTrue()
        assertThat(SshCertificate.mismatch(cert, SshWire.publicBlob(REAL_KEY))).isNull()
    }

    @Test
    fun refusesWhatIsNotAUserCertificateForThisKey() {
        assertThrows(IllegalArgumentException::class.java) { SshCertificate.parse(REAL_KEY) }
        assertThrows(IllegalArgumentException::class.java) {
            SshCertificate.parse(realCertificate.replace("AAAAIHNzaC1", "AAAAIHNzaC2"))
        }
        val other = KeyPair.genKeyPair(JSch(), KeyPair.ED25519)
        assertThat(SshCertificate.mismatch(SshCertificate.parse(realCertificate), other.publicKeyBlob))
            .contains("different key")
        val user = KeyPair.genKeyPair(JSch(), KeyPair.ED25519)
        val host = certificate(user, KeyPair.genKeyPair(JSch(), KeyPair.ED25519), certType = 2)
        assertThat(SshCertificate.mismatch(SshCertificate.parse(host), user.publicKeyBlob)).contains("host certificate")
    }

    @Test
    fun aCertificateSignsWithItsKeyAndOffersSha512ForRsa() {
        for ((type, expected) in listOf(
            KeyPair.ED25519 to ("ssh-ed25519-cert-v01@openssh.com" to "ssh-ed25519"),
            KeyPair.ECDSA to ("ecdsa-sha2-nistp256-cert-v01@openssh.com" to "ecdsa-sha2-nistp256"),
            // OpenSSH 8.8+ refuses SHA-1 (ssh-rsa-cert) RSA certificates.
            KeyPair.RSA to ("rsa-sha2-512-cert-v01@openssh.com" to "rsa-sha2-512"),
        )) {
            val key = KeyPair.genKeyPair(JSch(), type, if (type == KeyPair.RSA) 2048 else 256)
            val cert = SshCertificate.parse(certificate(key, KeyPair.genKeyPair(JSch(), KeyPair.ED25519)))
            val identity = CertificateIdentity(KeyPairIdentity(key, "test"), cert)
            assertThat(identity.algName).isEqualTo(expected.first)
            assertThat(identity.publicKeyBlob).isEqualTo(cert.blob)
            val signature = identity.getSignature("session data".toByteArray(), identity.algName)!!
            assertThat(SshReader(signature).string()).isEqualTo(expected.second)
        }
    }

    @Test
    fun keysTakeOnlyTheirOwnCertificate() {
        val key = KeyPair.genKeyPair(JSch(), KeyPair.ECDSA, 256)
        val pem = ByteArrayOutputStream().also { key.writePrivateKey(it) }.toString()
        val line = certificate(key, KeyPair.genKeyPair(JSch(), KeyPair.ED25519))
        val prepared = SshKeyMaterial.prepare(pem, certificate = "\n$line\n")
        assertThat(prepared.certificate).isEqualTo(line)
        val error = assertThrows(IllegalArgumentException::class.java) {
            SshKeyMaterial.prepare(pem, certificate = realCertificate)
        }
        assertThat(error).hasMessageThat().contains("different key")
        assertThat(SshKeyMaterial.checkedCertificate("  ", key.publicKeyBlob)).isEmpty()
    }

    private companion object {
        const val REAL_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRLHcRbaksxjhQ5QS0valxLQlaVLOD7SNmI64fRoDCa user"

        /** A certificate for [key] signed by [authority], as PROTOCOL.certkeys lays it out. */
        fun certificate(key: KeyPair, authority: KeyPair, certType: Long = 1): String {
            val keyBlob = SshReader(key.publicKeyBlob)
            val keyType = keyBlob.string()
            val certTypeName = "$keyType-cert-v01@openssh.com"
            val body = SshWriter().string(certTypeName).bytes(ByteArray(32))
                .raw(key.publicKeyBlob.copyOfRange(4 + keyType.length, key.publicKeyBlob.size))
                .uint32(0).uint32(7) // serial, as a uint64
                .uint32(certType).string("test")
                .bytes(SshWriter().string("alice").toByteArray())
                .uint32(0).uint32(0).uint32(0xffffffffL).uint32(0xffffffffL)
                .bytes(ByteArray(0)).bytes(ByteArray(0)).bytes(ByteArray(0))
                .bytes(authority.publicKeyBlob)
                .toByteArray()
            val signed = SshWriter().raw(body).bytes(authority.getSignature(body)).toByteArray()
            return "$certTypeName ${Base64.toBase64String(signed)} test"
        }
    }
}
