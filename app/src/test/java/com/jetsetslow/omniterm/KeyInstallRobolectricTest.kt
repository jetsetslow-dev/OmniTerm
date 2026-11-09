package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.CredentialProfileEntity
import com.jetsetslow.omniterm.data.KeyInstall
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SshKeyEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Install key on several hosts at once: each host's own answer becomes its result, the check signs
 * in with the key alone, and only a host where that worked is switched to the key.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class KeyInstallRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    /** What one host answers: its OS probe, the install command, and a sign-in by key alone. */
    private data class Host(val probe: String = "Linux\n", val install: String = "${KeyInstall.ADDED}\n", val keySignIn: String? = null)

    /** Hosts answering as [hosts] says, by address; every other command gets nothing. */
    private class Hosts(val hosts: Map<String, Host>) : SshTransport {
        val installs = CopyOnWriteArrayList<Triple<SshCredentials, String, String?>>()
        val keyChecks = ConcurrentHashMap<String, SshCredentials>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            val host = hosts[creds.host] ?: return ""
            return when (command) {
                RemoteCommands.OS_PROBE -> host.probe
                KeyInstall.COMMAND -> host.install.also { installs.add(Triple(creds, command, stdin)) }
                else -> ""
            }
        }

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit) = ""

        override suspend fun testConnection(creds: SshCredentials): String? {
            if (!creds.keyOnly) return null
            keyChecks[creds.host] = creds
            return hosts[creds.host]?.keySignIn
        }

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("No shell is opened in these tests")
    }

    private val app = ApplicationProvider.getApplicationContext<Application>()
    private fun text(id: Int, vararg args: Any) = app.getString(id, *args)

    private val publicKey = fixturePublicKey("ssh-ed25519", "laptop")
    private val key = SshKeyEntity(
        alias = "Laptop",
        keyType = "ED25519",
        privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----\n",
        publicKey = publicKey,
        fingerprint = "SHA256:fixture",
        certificate = "ssh-ed25519-cert-v01@openssh.com AAAAfixture laptop",
    )

    @Test
    fun eachHostGetsItsOwnResultAndOnlyWorkingHostsSwitch() = runBlocking {
        val hosts = Hosts(
            mapOf(
                "added.invalid" to Host(),
                "refused.invalid" to Host(install = "${KeyInstall.PRESENT}\n", keySignIn = "Auth fail"),
                "windows.invalid" to Host(probe = "Windows\r\n"),
                "profile.invalid" to Host(),
                "readonly.invalid" to Host(install = "SSH Error: command failed (1): sh: cannot create .ssh/authorized_keys: Permission denied\n"),
                "down.invalid" to Host(probe = "SSH Error: Connection refused"),
                "uses-it.invalid" to Host(install = "${KeyInstall.PRESENT}\n"),
                "stays.invalid" to Host(),
            ),
        )
        withModel(hosts) { model, repository, main ->
            repository.insertKey(key)
            val profileId = repository.insertProfile(
                CredentialProfileEntity(profileName = "Team", username = "team-user", authType = "password", password = "pw"),
            ).toInt()
            suspend fun host(name: String, auth: (ServerEntity) -> ServerEntity = { it }) = repository.insertServer(
                auth(ServerEntity(name = name, host = "$name.invalid", username = "u-$name", authType = "password", authPassword = "pw")),
            ).toInt()
            val added = host("added")
            val refused = host("refused")
            val windows = host("windows")
            val profile = host("profile") { it.copy(authType = "profile", authProfileId = profileId) }
            val readonly = host("readonly")
            val down = host("down")
            val usesIt = host("uses-it") { it.copy(authType = "key", authKeyAlias = "Laptop") }
            val all = listOf(added, refused, windows, profile, readonly, down, usesIt)

            withContext(main) { model.installKey("Laptop", all, useForSignIn = true) }
            waitWhileOnMain(main, 10_000) { model.keyInstallRunning || model.keyInstallResults.size < all.size }

            val results = withContext(main) { model.keyInstallResults.toMap() }
            val works = text(R.string.key_install_added_works)
            assertThat(results[added]).isEqualTo(AppViewModel.KeyInstallResult(true, works + " " + text(R.string.key_install_switched, "Laptop")))
            assertThat(results[refused]).isEqualTo(AppViewModel.KeyInstallResult(false, text(R.string.key_install_present_refused)))
            assertThat(results[windows]).isEqualTo(AppViewModel.KeyInstallResult(false, text(R.string.key_install_windows)))
            assertThat(results[profile]).isEqualTo(AppViewModel.KeyInstallResult(true, works + " " + text(R.string.key_install_profile_kept, "Team")))
            assertThat(results[readonly]).isEqualTo(
                AppViewModel.KeyInstallResult(false, text(R.string.key_install_failed, "sh: cannot create .ssh/authorized_keys: Permission denied")),
            )
            assertThat(results[down]).isEqualTo(AppViewModel.KeyInstallResult(false, text(R.string.key_install_not_reached, "Connection refused")))
            assertThat(results[usesIt]).isEqualTo(AppViewModel.KeyInstallResult(true, text(R.string.key_install_present_works)))

            // The line goes on stdin, in sh, to each Unix host it reached, and nowhere else.
            val line = KeyInstall.line(key)
            assertThat(hosts.installs.map { it.first.host }).containsExactly(
                "added.invalid", "refused.invalid", "profile.invalid", "readonly.invalid", "uses-it.invalid",
            )
            hosts.installs.forEach { (creds, _, stdin) ->
                assertWithMessage(creds.host).that(stdin).isEqualTo(line)
                assertWithMessage(creds.host).that(creds.posixShell).isTrue()
            }

            // The check offers the key alone: no password, no certificate, nothing else to fall back on.
            assertThat(hosts.keyChecks.keys).containsExactly("added.invalid", "refused.invalid", "profile.invalid", "uses-it.invalid")
            hosts.keyChecks.values.forEach { creds ->
                assertWithMessage(creds.host).that(creds.keyOnly).isTrue()
                assertWithMessage(creds.host).that(creds.password).isNull()
                assertWithMessage(creds.host).that(creds.certificate).isNull()
                assertWithMessage(creds.host).that(creds.passphrase).isNull()
                assertWithMessage(creds.host).that(creds.privateKeyPem).isEqualTo(key.privateKey)
            }
            // As the user the host signs in as, its profile's for a profile host.
            assertThat(hosts.keyChecks.getValue("added.invalid").username).isEqualTo("u-added")
            assertThat(hosts.keyChecks.getValue("profile.invalid").username).isEqualTo("team-user")

            // Only the host where the key works and that signed in by password now uses the key.
            val saved = all.associateWith { checkNotNull(repository.getServerById(it)) }
            assertThat(saved.getValue(added).authType).isEqualTo("key")
            assertThat(saved.getValue(added).authKeyAlias).isEqualTo("Laptop")
            assertThat(saved.getValue(added).authPassword).isEqualTo("pw")
            listOf(refused, windows, readonly, down).forEach {
                assertWithMessage(saved.getValue(it).name).that(saved.getValue(it).authType).isEqualTo("password")
            }
            assertThat(saved.getValue(profile).authType).isEqualTo("profile")
            assertThat(saved.getValue(profile).authProfileId).isEqualTo(profileId)

            // Without "sign in with this key", a host where it works is left as it is.
            val stays = host("stays")
            withContext(main) { model.installKey("Laptop", listOf(stays), useForSignIn = false) }
            waitWhileOnMain(main, 10_000) { model.keyInstallRunning || stays !in model.keyInstallResults }
            assertThat(withContext(main) { model.keyInstallResults[stays] }).isEqualTo(AppViewModel.KeyInstallResult(true, works))
            assertThat(checkNotNull(repository.getServerById(stays)).authType).isEqualTo("password")
        }
    }

    @Test
    fun aSecurityKeyIsNotTriedAndAKeyWithoutAPublicHalfIsNotSent() = runBlocking {
        val hosts = Hosts(mapOf("sk.invalid" to Host(), "plain.invalid" to Host()))
        withModel(hosts) { model, repository, main ->
            repository.insertKey(
                SshKeyEntity(alias = "Token", keyType = "ED25519-SK", privateKey = "handle", publicKey = fixturePublicKey("sk-ssh-ed25519@openssh.com"), fingerprint = "f"),
            )
            repository.insertKey(SshKeyEntity(alias = "Broken", keyType = "ED25519", privateKey = "k", publicKey = "not a key", fingerprint = "f"))
            val sk = repository.insertServer(ServerEntity(name = "sk", host = "sk.invalid", username = "u")).toInt()
            val plain = repository.insertServer(ServerEntity(name = "plain", host = "plain.invalid", username = "u")).toInt()

            withContext(main) { model.installKey("Token", listOf(sk), useForSignIn = true) }
            waitWhileOnMain(main, 10_000) { model.keyInstallRunning || sk !in model.keyInstallResults }
            // A security key needs a touch, so it is not tried unattended, and the host is not switched to it.
            assertThat(withContext(main) { model.keyInstallResults[sk] })
                .isEqualTo(AppViewModel.KeyInstallResult(true, text(R.string.key_install_added_security_key)))
            assertThat(hosts.keyChecks).isEmpty()
            assertThat(checkNotNull(repository.getServerById(sk)).authType).isEqualTo("password")

            withContext(main) { model.installKey("Broken", listOf(plain), useForSignIn = true) }
            waitWhileOnMain(main, 10_000) { model.keyInstallRunning || plain !in model.keyInstallResults }
            assertThat(withContext(main) { model.keyInstallResults[plain] })
                .isEqualTo(AppViewModel.KeyInstallResult(false, text(R.string.key_install_no_public_key)))
            assertThat(hosts.installs.map { it.first.host }).containsExactly("sk.invalid")
        }
    }

    private suspend fun withModel(
        transport: SshTransport,
        body: suspend (AppViewModel, AppRepository, kotlinx.coroutines.CoroutineDispatcher) -> Unit,
    ) {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val repository = AppRepository(AppDatabase.getDatabase(app))
            val model = withContext(main) { AppViewModel(app, transport) }
            store.put("test", model)
            body(model, repository, main)
        } finally {
            clearViewModelsAndAwaitTerminalJobs(store, main)
            Dispatchers.resetMain()
            main.close()
        }
    }
}
