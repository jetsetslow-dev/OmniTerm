package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jcraft.jsch.UserInfo
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.InteractiveAuthRequest
import com.jetsetslow.omniterm.data.ssh.NEEDS_SECURITY_KEY
import com.jetsetslow.omniterm.data.ssh.SecurityKeySignRequest
import com.jetsetslow.omniterm.data.ssh.SkKeyType
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshKeyMaterial
import com.jetsetslow.omniterm.data.ssh.SshWire
import com.jetsetslow.omniterm.data.ssh.buildJschSession
import com.jetsetslow.omniterm.data.ssh.signInFailureMessage
import java.io.File
import org.junit.Assert.assertThrows
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Certificate and security-key sign-in through the app's own session builder, against a real
 * OpenSSH server: the fleet's `certauth` host, which has no authorized keys and trusts only the
 * fleet's test certificate authority, so a certificate is the only way in.
 *
 * Opt-in, because it needs the fleet running:
 *
 *     ./scripts/test-hosts.sh up
 *     ./gradlew :app:testPlayStoreDebugUnitTest --tests '*SshSignInLiveTest' -Domniterm.liveSsh=true
 *
 * Every key but the fleet's own is made here and signed with the fleet's CA by `ssh-keygen`.
 * Security keys are [SoftwareSecurityKey]s; real FIDO2 hardware is not exercised.
 */
class SshSignInLiveTest {
    @get:Rule
    val temp = TemporaryFolder()

    // Unit tests run from the module directory.
    private val fleet = File("../scripts/test-hosts")
    private val keys = File(fleet, "keys")
    private lateinit var user: String

    @Before
    fun optIn() {
        assumeTrue("opt in with -Domniterm.liveSsh=true", System.getProperty("omniterm.liveSsh") == "true")
        check(File(keys, "omniterm_test_ca").isFile) { "No fleet CA in $keys: run ./scripts/test-hosts.sh up first." }
        user = File(fleet, ".env").readLines().first { it.startsWith("OMNITERM_TEST_USER=") }.substringAfter('=')
    }

    @Test
    fun theFleetKeySignsInWithItsCertificateAndNotWithout() {
        val key = File(keys, "omniterm_test_ed25519").readText()
        val certificate = File(keys, "omniterm_test_ed25519-cert.pub").readText()
        assertThat(signIn(key, certificate)).isEqualTo(user)
        val refused = assertThrows(JSchException::class.java) { signIn(key, null) }
        assertThat(refused).hasMessageThat().contains("Auth fail")
    }

    @Test
    fun aProtectedKeyOpenedAtImportSignsInWithItsCertificate() {
        val file = sshKeygenKey("ed25519", passphrase = "live pass")
        val prepared = SshKeyMaterial.prepare(file.readText(), passphrase = "live pass", certificate = certify(file.path + ".pub"))
        assertThat(signIn(prepared.privateKey, prepared.certificate)).isEqualTo(user)
    }

    /** OpenSSH 8.8+ refuses SHA-1 RSA certificates, so this only passes as rsa-sha2-512-cert. */
    @Test
    fun anRsaKeySignsInWithItsCertificate() {
        val file = sshKeygenKey("rsa")
        val prepared = SshKeyMaterial.prepare(file.readText(), certificate = certify(file.path + ".pub"))
        assertThat(signIn(prepared.privateKey, prepared.certificate)).isEqualTo(user)
    }

    @Test
    fun securityKeysSignInWithTheirCertificate() {
        for (type in SkKeyType.entries) {
            val token = SoftwareSecurityKey(type)
            val key = token.sshKey()
            val pub = temp.newFile("sk-${type.name}.pub").apply { writeText(SshWire.publicLine(key.publicBlob, "live") + "\n") }
            val touched = token.counter
            assertThat(signIn(key.keyFile("live"), certify(pub.path), touch(token))).isEqualTo(user)
            assertThat(token.counter).isGreaterThan(touched)
        }
    }

    @Test
    fun aSecurityKeyWithNobodyToTouchItSaysSo() {
        val key = SoftwareSecurityKey(SkKeyType.Ed25519).sshKey()
        val pub = temp.newFile("sk.pub").apply { writeText(SshWire.publicLine(key.publicBlob, "live") + "\n") }
        val session = session(key.keyFile("live"), certify(pub.path), ask = null)
        val refused = assertThrows(JSchException::class.java) { session.connect(CONNECT_TIMEOUT_MS) }
        assertThat(signInFailureMessage(session, refused)).isEqualTo(NEEDS_SECURITY_KEY)
    }

    private fun touch(token: SoftwareSecurityKey) = object : InteractiveAuth {
        override suspend fun answer(request: InteractiveAuthRequest): List<String>? = null
        override suspend fun signWithSecurityKey(request: SecurityKeySignRequest) = token.assert(request)
    }

    private fun session(privateKey: String, certificate: String?, ask: InteractiveAuth?): Session = buildJschSession(
        SshCredentials("127.0.0.1", CERTAUTH_PORT, user, privateKeyPem = privateKey, certificate = certificate),
        ask,
        MemoryHostKeys(),
    )

    /** Signs in and returns who the server says we are. */
    private fun signIn(privateKey: String, certificate: String?, ask: InteractiveAuth? = null): String {
        val session = session(privateKey, certificate, ask)
        session.connect(CONNECT_TIMEOUT_MS)
        try {
            val channel = session.openChannel("exec") as ChannelExec
            channel.setCommand("id -un")
            val output = channel.inputStream
            channel.connect(CONNECT_TIMEOUT_MS)
            return output.readBytes().toString(Charsets.UTF_8).trim().also { channel.disconnect() }
        } finally {
            session.disconnect()
        }
    }

    private fun sshKeygenKey(type: String, passphrase: String = ""): File {
        val file = File(temp.root, "key-$type")
        sshKeygen("-q", "-t", type, "-N", passphrase, "-C", "live-$type", "-f", file.path)
        return file
    }

    /** A user certificate for [publicKeyFile] from the fleet CA, valid for an hour. */
    private fun certify(publicKeyFile: String): String {
        sshKeygen("-q", "-s", File(keys, "omniterm_test_ca").path, "-I", "omniterm-live", "-n", user, "-V", "-5m:+1h", publicKeyFile)
        return File(publicKeyFile.removeSuffix(".pub") + "-cert.pub").readText()
    }

    private fun sshKeygen(vararg args: String) {
        val process = ProcessBuilder("ssh-keygen", *args).redirectErrorStream(true).start()
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        check(process.waitFor() == 0) { "ssh-keygen ${args.joinToString(" ")} failed: $output" }
    }

    /** Trusts each host's first key for this test only; the app's own store pins in Keystore. */
    private class MemoryHostKeys : HostKeyRepository {
        private val known = mutableMapOf<String, ByteArray>()

        override fun check(host: String, key: ByteArray): Int {
            val pinned = known.getOrPut(host) { key }
            return if (pinned.contentEquals(key)) HostKeyRepository.OK else HostKeyRepository.CHANGED
        }

        override fun add(hostkey: HostKey, ui: UserInfo?) = Unit
        override fun remove(host: String?, type: String?) = Unit
        override fun remove(host: String?, type: String?, key: ByteArray?) = Unit
        override fun getKnownHostsRepositoryID() = "live-test"
        override fun getHostKey(): Array<HostKey> = emptyArray()
        override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
    }

    private companion object {
        const val CERTAUTH_PORT = 2207
        const val CONNECT_TIMEOUT_MS = 15_000
    }
}
