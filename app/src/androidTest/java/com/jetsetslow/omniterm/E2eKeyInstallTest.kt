package com.jetsetslow.omniterm

import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SshKeyEntity
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Install key against the repository's provisioned disposable host, which signs in by password:
 * - a key made in OmniTerm is installed from its card under Tools → Keys, the host signs in with
 *   it alone, and with "sign in with this key" the host switches to it;
 * - installed again from the host, it is found already there and nothing is added twice;
 * - signing in by key only never falls back to the host's password.
 * The host's authorized_keys, the host's sign-in and the key are put back as they were.
 */
class E2eKeyInstallTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aKeyMadeHereSignsInToTheHostItWasInstalledOn() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_key_install") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host: ServerEntity = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertEquals("the fixture host signs in by password", "password", host.authType)
        val creds = runBlocking { HostCredentials.build(repository, host, posixShell = true) }
        val transport = JschSshTransport()
        fun has(tag: String) = composeRule.showsNode(hasTestTag(tag))
        fun sh(command: String) = runBlocking { transport.exec(creds, command) }
        val alias = "E2E install ${System.currentTimeMillis()}"
        val hadFile = sh("[ -f ~/.ssh/authorized_keys ] && echo yes || echo no").trim() == "yes"
        val hadFolder = sh("[ -d ~/.ssh ] && echo yes || echo no").trim() == "yes"
        var key: SshKeyEntity? = null
        var failure: Throwable? = null
        try {
            composeRule.runOnUiThread { vm.generateSshKey(alias, "RSA") }
            composeRule.waitUntil(180_000) { runBlocking { repository.getAllKeys() }.any { it.alias == alias } }
            val made = runBlocking { repository.getAllKeys() }.single { it.alias == alias }
            key = made
            val blob = made.publicKey.trim().split(Regex("\\s+"))[1]
            fun copies() = sh("grep -cF -- '$blob' ~/.ssh/authorized_keys 2>/dev/null || true").trim()

            // From the key's card: pick the host, ask to sign in with the key, install, confirm.
            composeRule.runOnUiThread { vm.navigateTo(Screen.AuthKeys) }
            composeRule.waitUntil(15_000) { composeRule.onAllNodes(hasScrollAction()).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNode(hasScrollAction()).performScrollToNode(hasTestTag("authKeys.install.${made.id}"))
            composeRule.onNodeWithTag("authKeys.install.${made.id}").performClick()
            composeRule.waitUntil(15_000) { has("keyInstall.dialog") }
            composeRule.onNodeWithTag("keyInstall.key.${made.id}", useUnmergedTree = true).assertExists()
            composeRule.onNodeWithTag("keyInstall.host.${host.id}").performScrollTo().performClick()
            composeRule.onNodeWithTag("keyInstall.use").performScrollTo().performClick().assertIsOn()
            composeRule.onNodeWithTag("keyInstall.run").performClick()
            composeRule.waitUntil(15_000) { has("keyInstall.confirm") }
            composeRule.onNodeWithTag("keyInstall.confirm").performClick()
            composeRule.waitUntil(120_000) { !vm.keyInstallRunning && host.id in vm.keyInstallResults }

            val works = context.getString(R.string.key_install_added_works)
            val expected = works + " " + context.getString(R.string.key_install_switched, alias)
            assertEquals(AppViewModel.KeyInstallResult(true, expected), vm.keyInstallResults[host.id])
            composeRule.onNodeWithTag("keyInstall.result.${host.id}", useUnmergedTree = true).assert(hasText(expected))
            assertEquals("added once", "1", copies())
            // Made private when new (a setgid bit inherited from the home folder aside); what was
            // there keeps its own permissions.
            if (!hadFolder) assertEquals("700", sh("stat -c %a ~/.ssh").trim().takeLast(3))
            if (!hadFile) assertEquals("600", sh("stat -c %a ~/.ssh/authorized_keys").trim().takeLast(3))
            val switched = checkNotNull(runBlocking { repository.getServerById(host.id) })
            assertEquals("key", switched.authType)
            assertEquals(alias, switched.authKeyAlias)

            // Signing in by key only: the key gets in, and with no key the password is never tried.
            val keyOnly = creds.copy(privateKeyPem = made.privateKey, certificate = null, keyOnly = true)
            assertNull(runBlocking { JschSshTransport().run { try { testConnection(keyOnly.copy(password = null)) } finally { shutdown() } } })
            assertNotNull(runBlocking { JschSshTransport().run { try { testConnection(keyOnly.copy(privateKeyPem = null)) } finally { shutdown() } } })

            // Again, from the host: it is already there, the host already uses it, nothing is added.
            composeRule.onNodeWithTag("keyInstall.done").performClick()
            composeRule.waitUntil(5_000) { !has("keyInstall.dialog") }
            composeRule.runOnUiThread { vm.openKeyInstall(keyAlias = alias, serverId = host.id) }
            composeRule.waitUntil(15_000) { has("keyInstall.dialog") }
            composeRule.onNodeWithTag("keyInstall.run").performClick()
            composeRule.waitUntil(15_000) { has("keyInstall.confirm") }
            composeRule.onNodeWithTag("keyInstall.confirm").performClick()
            composeRule.waitUntil(120_000) { !vm.keyInstallRunning && host.id in vm.keyInstallResults }
            assertEquals(
                AppViewModel.KeyInstallResult(true, context.getString(R.string.key_install_present_works)),
                vm.keyInstallResults[host.id],
            )
            assertEquals("still once", "1", copies())
            composeRule.onNodeWithTag("keyInstall.done").performClick()
        } catch (t: Throwable) {
            failure = t
            t.addSuppressed(AssertionError("screen=${vm.currentScreen} running=${vm.keyInstallRunning} results=${vm.keyInstallResults.toMap()}"))
            throw t
        } finally {
            try {
                composeRule.runOnUiThread { vm.closeKeyInstall() }
                // The host signs in as it did, and its authorized_keys is as it was.
                val restored = java.util.concurrent.CountDownLatch(1)
                composeRule.runOnUiThread { vm.updateServer(host) { restored.countDown() } }
                restored.await(15, java.util.concurrent.TimeUnit.SECONDS)
                key?.let { made ->
                    val blob = made.publicKey.trim().split(Regex("\\s+"))[1]
                    sh(
                        "f=~/.ssh/authorized_keys; if [ -f \"\$f\" ]; then grep -vF -- '$blob' \"\$f\" > \"\$f.e2e\"; cat \"\$f.e2e\" > \"\$f\"; rm -f \"\$f.e2e\"; fi",
                    )
                    if (!hadFile) sh("[ -s ~/.ssh/authorized_keys ] || rm -f ~/.ssh/authorized_keys")
                    if (!hadFolder) sh("rmdir ~/.ssh 2>/dev/null || true")
                    composeRule.runOnUiThread { vm.deleteKey(made) }
                }
                transport.shutdown()
            } catch (cleanup: Throwable) {
                failure?.addSuppressed(cleanup) ?: throw cleanup
            }
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
    }
}
