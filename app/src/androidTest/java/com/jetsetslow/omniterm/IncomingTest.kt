package com.jetsetslow.omniterm

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.CredentialProfileEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.incoming.IncomingActivity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * What other apps hand OmniTerm, on a real device and with no host needed. Each goes through the
 * exported forwarding activity, as a browser or the share sheet would send it:
 * - an `ssh://` link opens a dialog that names what it read, never the password in it, offers the
 *   saved hosts it matches (a credential profile's user counts), and otherwise fills in a new host;
 * - shared text opens a new script with that text as its command, saving nothing;
 * - a shared `file://` path or a file from OmniTerm's own provider is refused, even when sent to
 *   the main screen directly.
 */
class IncomingTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val repository = AppRepository(AppDatabase.getDatabase(context))
    private val vm: AppViewModel get() = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
    private val made = mutableListOf<ServerEntity>()
    private var profileId: Int? = null
    private lateinit var restoreLaunchIntent: () -> Unit

    @Before fun keepLaunchIntent() {
        restoreLaunchIntent = composeRule.keepLaunchIntent()
    }

    @After fun tearDown(): Unit = runBlocking {
        restoreLaunchIntent()
        made.forEach { srv -> repository.getServerById(srv.id)?.let { repository.deleteServer(it) } }
        repository.getAllServers().filter { it.host == NEW_HOST }.forEach { repository.deleteServer(it) }
        repository.getAllScripts().filter { it.command == SHARED_TEXT }.forEach { repository.deleteScript(it) }
        profileId?.let { id -> repository.getAllProfiles().find { it.id == id }?.let { repository.deleteProfile(it) } }
        composeRule.runOnUiThread { vm.dismissSshLink(); vm.takeSharedUploads() }
    }

    @Test fun aLinkToAnUnsavedHostFillsInANewOne() {
        handOver(Intent(Intent.ACTION_VIEW, Uri.parse("ssh://new%20user:$PASSWORD@$NEW_HOST:2222/")))
        awaitTag("sshLink.dialog")
        composeRule.onNodeWithTag("sshLink.address").assertExists()
        assertEquals("new user@$NEW_HOST:2222", vm.pendingSshLink?.label)
        assertTrue("no saved host matches", vm.sshLinkMatches.isEmpty())
        assertNoText(PASSWORD)

        composeRule.onNodeWithTag("sshLink.add").performClick()
        composeRule.waitUntil(10_000) { has(hasText(NEW_HOST)) && has(hasText("2222")) }
        assertNoText(PASSWORD)
        // The user is on the sheet's Credentials tab, beside the password, which stays empty.
        composeRule.onNode(hasText(context.getString(R.string.credentials)) and hasClickAction()).performClick()
        composeRule.waitUntil(10_000) { has(hasText("new user")) }
        assertNoText(PASSWORD)
        assertTrue("nothing is saved before the user saves", runBlocking { repository.getAllServers() }.none { it.host == NEW_HOST })
    }

    @Test fun aLinkToASavedHostOffersItAndOnlyIt() {
        val plain = save(ServerEntity(name = "incoming-plain", host = SAVED_HOST, port = 22, username = "alice"))
        save(ServerEntity(name = "incoming-other-user", host = SAVED_HOST, port = 22, username = "bob"))
        val profile = runBlocking {
            repository.insertProfile(CredentialProfileEntity(profileName = "incoming-profile", username = "carol", authType = "password", password = "x")).toInt()
        }
        profileId = profile
        val viaProfile = save(ServerEntity(name = "incoming-profile-host", host = SAVED_HOST, port = 22, username = "", authType = "profile", authProfileId = profile))

        handOver(Intent(Intent.ACTION_VIEW, Uri.parse("ssh://alice@$SAVED_HOST")))
        awaitTag("sshLink.connect.${plain.id}")
        assertEquals(listOf(plain.id), vm.sshLinkMatches.map { it.id })
        composeRule.runOnUiThread { vm.dismissSshLink() }

        handOver(Intent(Intent.ACTION_VIEW, Uri.parse("ssh://carol@$SAVED_HOST:22")))
        awaitTag("sshLink.connect.${viaProfile.id}")
        assertEquals("the profile's user signs in", listOf(viaProfile.id), vm.sshLinkMatches.map { it.id })
    }

    @Test fun sharedTextBecomesANewScriptThatIsNotSavedYet() {
        handOver(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, SHARED_TEXT))
        composeRule.waitUntil(10_000) { vm.currentScreen == Screen.QuickScripts && has(hasText(SHARED_TEXT)) }
        assertTrue(runBlocking { repository.getAllScripts() }.none { it.command == SHARED_TEXT })
    }

    @Test fun pathsAndOmniTermsOwnFilesAreRefused() {
        val ownFile = "content://${context.packageName}.fileprovider/cache/crash.txt"
        val privateDb = "file://${context.dataDir.absolutePath}/databases/app.db"
        val privateDbWithHost = "file://localhost${context.dataDir.absolutePath}/databases/app.db"
        val start = vm.currentScreen
        listOf(ownFile, privateDb, privateDbWithHost).forEach { uri ->
            // The shell is another app here; `am` sends the stream extra as a share would.
            DeviceShell.run("am start -W -n ${context.packageName}/${IncomingActivity::class.java.name} -a android.intent.action.SEND -t text/plain --eu android.intent.extra.STREAM $uri")
            DeviceShell.run("am start -W -n ${context.packageName}/${MainActivity::class.java.name} -a android.intent.action.SEND -t text/plain --eu android.intent.extra.STREAM $uri")
        }
        Thread.sleep(QUIET_MS)
        composeRule.waitForIdle()
        assertTrue("nothing is waiting to upload", vm.sharedUploads.isEmpty())
        assertEquals(start, vm.currentScreen)
    }

    private fun handOver(intent: Intent) {
        context.startActivity(intent.setClassName(context.packageName, IncomingActivity::class.java.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun save(srv: ServerEntity): ServerEntity = runBlocking {
        val id = repository.insertServer(srv).toInt()
        requireNotNull(repository.getServerById(id)).also(made::add)
    }

    private fun has(matcher: androidx.compose.ui.test.SemanticsMatcher) = composeRule.showsNode(matcher)

    private fun awaitTag(tag: String) = composeRule.waitUntil(10_000) { has(hasTestTag(tag)) }

    // Strict: with no screen to look in, this fails rather than passing.
    private fun assertNoText(text: String) = assertTrue(
        "$text is on screen",
        composeRule.onAllNodes(hasText(text, substring = true), useUnmergedTree = true).fetchSemanticsNodes().isEmpty(),
    )

    private companion object {
        const val NEW_HOST = "192.0.2.55"
        const val SAVED_HOST = "192.0.2.77"
        const val PASSWORD = "topsecret-in-link"
        const val SHARED_TEXT = "df -h /srv # shared into OmniTerm"
        const val QUIET_MS = 3_000L
    }
}
