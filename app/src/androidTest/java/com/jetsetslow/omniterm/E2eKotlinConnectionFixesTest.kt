package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.SecurityKeySignRequest
import com.jetsetslow.omniterm.data.ssh.SkKey
import com.jetsetslow.omniterm.data.ssh.SkKeyType
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in API 34+ checks; SFTP uses only the host provisioned from scripts/test-hosts.sh. */
class E2eKotlinConnectionFixesTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    private fun model(): AppViewModel {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_connection_fixes") == "yes")
        return ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
    }

    @Test
    fun forwardedSecurityKeyDialogNamesTheRequestingHostAndOnwardUser() = runBlocking {
        val vm = model()
        // Exercise the real request-to-dialog path without exposing a production state setter.
        val auth = AppViewModel::class.java.getDeclaredMethod("interactiveAuthFor", String::class.java)
            .apply { isAccessible = true }.invoke(vm, "Fixture bastion") as InteractiveAuth
        val key = SkKey(SkKeyType.Ed25519, ByteArray(32), SkKey.DEFAULT_APPLICATION, SkKey.USER_PRESENCE_REQUIRED, ByteArray(32))
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val response = async(Dispatchers.IO) {
            auth.signWithSecurityKey(SecurityKeySignRequest("fixture@bastion", key, ByteArray(32), forwarded = true, forwardedUser = "deploy"))
        }
        try {
            composeRule.waitUntil(10_000) { vm.pendingSecurityKey != null }
            composeRule.onNodeWithText("Fixture bastion asks to use your security key").assertIsDisplayed()
            composeRule.onNodeWithText("A program there is signing in somewhere else as deploy, through your forwarded agent. Cancel unless you started it.")
                .assertIsDisplayed()
            composeRule.onNodeWithTag("securityKey.cancel").performClick()
            assertNull(withTimeout(10_000) { response.await() })
            composeRule.runOnUiThread { assertNull(vm.pendingSecurityKey) }
        } finally {
            composeRule.runOnUiThread { vm.pendingSecurityKey?.let { vm.finishSecurityKey(it, null) } }
            response.cancel()
        }
    }

    @Test
    fun newFileShowsPendingStateOpensTheEditorAndRefusesAnExistingName() = runBlocking {
        val vm = model()
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == "E2E Foreground Demo" } }
        val host = vm.servers.value.single { it.name == "E2E Foreground Demo" }
        val home = InstrumentationRegistry.getArguments().getString("omniterm_e2e_sftp_home") ?: "/config"
        lateinit var load: kotlinx.coroutines.Job
        composeRule.runOnUiThread {
            vm.isAppLocked = false
            vm.selectedServerId = host.id
            vm.navigateTo(Screen.SFTP)
            vm.activeSftpTab = 1
            load = vm.loadSftp(home)
        }
        withTimeout(30_000) { load.join() }
        composeRule.waitForIdle()
        composeRule.waitUntil(15_000) { !vm.sftpLoading && vm.sftpPath == home }
        assertNull("Fixture listing: ${vm.sftpError}", vm.sftpError)
        val name = "omniterm-connection-fix-${System.nanoTime()}.txt"
        try {
            composeRule.runOnUiThread {
                vm.sftpNewFile(name)
                assertNotNull("Creation exposes pending state immediately", vm.sftpFileCreation)
            }
            composeRule.waitUntil(30_000) { vm.sftpFileCreation == null }
            assertNull("Create: ${vm.sftpError}", vm.sftpError)
            assertEquals(name, vm.edittingSftpFile?.name)
            composeRule.onNodeWithTag("code-editor-input").assertIsDisplayed()

            val saved = CompletableDeferred<Unit>()
            composeRule.runOnUiThread { vm.sftpSaveText(requireNotNull(vm.edittingSftpFile), "fixture text\n") { saved.complete(Unit) } }
            withTimeout(30_000) { saved.await() }
            composeRule.waitUntil(15_000) { !vm.sftpLoading }
            composeRule.runOnUiThread {
                vm.edittingSftpFile = null
                vm.sftpNewFile(name)
                assertEquals("\"$name\" already exists here.", vm.sftpError)
            }
            lateinit var read: kotlinx.coroutines.Job
            composeRule.runOnUiThread {
                read = requireNotNull(vm.openSftpFileForEdit(vm.sftpEntries.single { it.name == name }))
            }
            withTimeout(30_000) { read.join() }
            assertEquals("fixture text\n", vm.edittingSftpFile?.content)
        } finally {
            composeRule.runOnUiThread {
                vm.edittingSftpFile = null
                vm.sftpEntries.singleOrNull { it.name == name }?.let(vm::sftpDelete)
            }
            composeRule.waitUntil(15_000) { vm.sftpEntries.none { it.name == name } }
        }
    }
}
