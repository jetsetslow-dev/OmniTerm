package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupContents
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.Screen
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Runs the shared document fixtures through the actual Android inspection/restore entrypoints. */
class BackupCompatibilityInstrumentedTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    /**
     * The row as the user configured it, with the five fields the background host check owns
     * normalised away.
     *
     * `updateConnectionState` and `updateAuthState` (`data/Daos.kt`) write `status`, `healthScore`,
     * `lastLatency`, `authStatus` and `authError` on the probe loop's own schedule, and the fixture
     * host here is deliberately unroutable. Comparing whole entities therefore raced that probe:
     * an otherwise identical row came back as `healthScore=0, status=connecting` simply because the
     * check had started. The question these assertions ask is whether a REJECTED profile edit
     * altered a server's identity, credentials or configuration, and that has nothing to do with
     * what the last probe found — so those five fields are excluded and every other field is still
     * compared exactly.
     */
    private fun com.jetsetslow.omniterm.data.ServerEntity.asConfigured() = copy(
        status = "offline",
        healthScore = 100,
        lastLatency = 0,
        authStatus = "unknown",
        authError = null,
    )

    @Test
    fun profileEditCannotSilentlyCreateDuplicateServerLogins() = runBlocking {
        val repository = com.jetsetslow.omniterm.data.AppRepository(AppDatabase.getDatabase(composeRule.activity))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val profileId = repository.insertProfile(com.jetsetslow.omniterm.data.CredentialProfileEntity(
            profileName = "Identity edit fixture", username = "deploy", authType = "password",
            password = "original fixture secret",
        )).toInt()
        val profile = checkNotNull(repository.getCredentialProfileById(profileId))
        val direct = com.jetsetslow.omniterm.data.ServerEntity(
            name = "Identity edit direct", host = "profile-identity.invalid", port = 2222,
            username = "root", authType = "password",
        )
        val directId = repository.insertServer(direct).toInt()
        val indirectId = repository.insertServer(direct.copy(
            name = "Identity edit indirect", username = "", authType = "profile", authProfileId = profileId,
        )).toInt()
        try {
            val result = AtomicReference<Pair<Boolean, String>>()
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.navigateTo(Screen.AuthKeys)
                vm.updateCredentialProfile(profile, profile.profileName, "root", "replacement fixture secret") { ok, message ->
                    result.set(ok to message)
                }
            }
            composeRule.waitUntil(15_000) { result.get() != null }
            assertTrue("Conflicting profile edit must be rejected: ${result.get()}", !result.get().first)
            assertTrue(result.get().second, result.get().second.contains(direct.name))
            assertTrue(result.get().second, result.get().second.contains("Identity edit indirect"))
            assertEquals(profile, repository.getCredentialProfileById(profileId))
            assertEquals(
                direct.copy(id = directId).asConfigured(),
                repository.getServerById(directId)?.asConfigured(),
            )
            assertEquals(profileId, repository.getServerById(indirectId)?.authProfileId)
            // The same rejection must be visible inside the actual editor, not behind its dialog.
            composeRule.onNodeWithTag("profile.edit.$profileId").performScrollTo().performClick()
            composeRule.onNodeWithText("Username").performTextReplacement("root")
            composeRule.onNodeWithText("Save Changes").performClick()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodesWithTag("profile.save.error").fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("profile.save.error").performScrollTo()
                .assertTextContains(direct.name, substring = true)
                .assertTextContains("Identity edit indirect", substring = true)
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.onNodeWithContentDescription("Add").performClick()
            composeRule.onNodeWithText("Profile (User/Pass)").performClick()
            composeRule.onNodeWithText("Create Credential Profile").assertIsDisplayed()
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.runOnUiThread { vm.navigateTo(Screen.Servers) }
        } finally {
            repository.deleteServerAndDependents(indirectId)
            repository.deleteServerAndDependents(directId)
            repository.deleteProfile(profile)
        }
    }

    @Test
    fun renamedServerIsReusedAndReportedWithoutChangingCredentials() = runBlocking {
        val repository = com.jetsetslow.omniterm.data.AppRepository(AppDatabase.getDatabase(composeRule.activity))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val server = com.jetsetslow.omniterm.data.ServerEntity(
            name = "Restore identity fixture current", host = "192.0.2.231", port = 2222,
            username = "fixture", authType = "password", authPassword = "current fixture secret",
        )
        check(repository.getServerByName(server.name) == null)
        val id = repository.insertServer(server).toInt()
        try {
            val document = org.json.JSONObject().put("format", "omniterm-backup").put("schema", 5)
                .put("servers", org.json.JSONArray().put(org.json.JSONObject()
                    .put("id", 77).put("name", "Restore identity fixture old")
                    .put("host", server.host).put("port", server.port)
                    .put("username", server.username).put("authType", server.authType)
                    .put("authPassword", "old fixture secret")))
                .put("settings", org.json.JSONObject().put("sftp_bookmarks_77", "/fixture"))
            val result = AtomicReference<Pair<Boolean, String>>()
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.navigateTo(Screen.Backup)
                vm.restoreEncryptedBackup(document.toString(), "", BackupSelection()) { ok, message ->
                    result.set(ok to message)
                }
            }
            composeRule.waitUntil(15_000) { result.get() != null }
            assertTrue(result.get().second, result.get().first)
            assertTrue(result.get().second, result.get().second.contains("already exist as \"${server.name}\""))
            assertEquals(1, repository.getAllServers().count { it.host == server.host })
            assertEquals(server.authPassword, repository.getServerById(id)?.authPassword)
            assertEquals("/fixture", repository.getSetting("sftp_bookmarks_$id"))
            composeRule.runOnUiThread { vm.navigateTo(Screen.Servers) }
            composeRule.waitForIdle()
        } finally {
            repository.deleteServerAndDependents(id)
        }
    }

    @Test
    fun bothDocumentFormatsInspectAndRestoreScriptsOnAndroid() = runBlocking {
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val dao = AppDatabase.getDatabase(composeRule.activity).quickScriptDao()
        val selection = BackupSelection(
            servers = false, sshKeys = false, credentialProfiles = false,
            scripts = true, alertRules = false, activeAlerts = false, alertHistory = false,
            wolTargets = false, networkShares = false, portForwards = false, settings = false,
        )
        // Unique fixture name: never delete an existing row as part of test cleanup.
        val name = "Compatibility instrumented fixture"
        check(dao.getAllScripts().none { it.name == name })
        try {
            for (file in listOf("kotlin-schema5.json", "flutter-v2.json")) {
                val text = InstrumentationRegistry.getInstrumentation().context.assets
                    .open("backup/$file").bufferedReader().use { it.readText() }
                    .replace("Fixture script", name)
                val inspection = AtomicReference<Triple<Boolean, BackupContents?, String>>()
                composeRule.runOnUiThread {
                    vm.isAppLocked = false
                    vm.navigateTo(Screen.Backup)
                    vm.inspectBackupContents(text, "") { ok, contents, error ->
                        inspection.set(Triple(ok, contents, error))
                    }
                }
                composeRule.waitUntil(15_000) { inspection.get() != null }
                assertTrue("$file: ${inspection.get().third}", inspection.get().first)
                assertEquals(1, inspection.get().second?.scripts)
                assertEquals(3, inspection.get().second?.settings)
                val restored = AtomicReference<Pair<Boolean, String>>()
                composeRule.runOnUiThread {
                    vm.restoreEncryptedBackup(text, "", selection) { ok, error ->
                        restored.set(ok to error)
                    }
                }
                composeRule.waitUntil(15_000) { restored.get() != null }
                assertTrue("$file: ${restored.get().second}", restored.get().first)
                val row = dao.getAllScripts().single { it.name == name }
                assertEquals("printf fixture", row.command)
                composeRule.runOnUiThread { vm.navigateTo(Screen.QuickScripts) }
                composeRule.waitForIdle()
                dao.deleteScript(row)
            }
        } finally {
            dao.getAllScripts().filter { it.name == name }.forEach { dao.deleteScript(it) }
        }
    }
}
