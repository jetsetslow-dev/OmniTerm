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
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.signInFailureMessage
import org.junit.Test

/**
 * Security key sign-in, against a software authenticator that signs the way a FIDO2 key does
 * (authenticator data, then the client data hash), checked the way OpenSSH's sshd checks it
 * (ssh-ed25519-sk.c, ssh-ecdsa-sk.c).
 */
class SecurityKeyTest {
    @Test
    fun signsInTheWaySshdChecks() {
        for (type in SkKeyType.entries) {
            val token = SoftwareSecurityKey(type)
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
        val key = SoftwareSecurityKey(SkKeyType.Ed25519).sshKey()
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
            val key = SoftwareSecurityKey(type).sshKey(SkKey.USER_PRESENCE_REQUIRED or SkKey.USER_VERIFICATION_REQUIRED)
            val file = key.keyFile("laptop")
            assertThat(file).startsWith(pemBegin("OPENSSH PRIVATE KEY"))
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
