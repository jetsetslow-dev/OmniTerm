package com.jetsetslow.omniterm

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.incoming.IncomingActivity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.SftpTransferStatus
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * What other apps hand OmniTerm, against the repository's provisioned disposable host:
 * - an `ssh://` link to that host offers it, and Connect opens its terminal;
 * - a contact card another app shares (the shell, which may read contacts and grants OmniTerm one
 *   read) waits in SFTP → Files, and uploads to the folder the user opened after the forwarding
 *   screen has finished: the read grant moved with it. OmniTerm cannot read the card without it;
 * - shared again into the same folder, the card replaces the first copy only after the user agrees
 *   to overwrite it, and leaves no staged or previous copy behind.
 */
class E2eIncomingTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aLinkConnectsAndASharedFileUploadsWhereTheUserChooses() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_incoming") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        val creds = runBlocking { HostCredentials.build(repository, host, posixShell = true) }
        val transport = JschSshTransport()
        fun has(tag: String) = composeRule.onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        val restoreLaunchIntent = composeRule.keepLaunchIntent()
        var rawContactId: String? = null
        var uploaded: String? = null
        var failure: Throwable? = null
        try {
            // The link: the saved host is offered, and Connect signs in.
            handOver(context, Intent(Intent.ACTION_VIEW, Uri.parse("ssh://${host.username}@${host.host}:${host.port}/")))
            composeRule.waitUntil(15_000) { has("sshLink.connect.${host.id}") }
            composeRule.onNodeWithTag("sshLink.connect.${host.id}").performClick()
            composeRule.waitUntil(60_000) { vm.currentScreen == Screen.Shell && vm.isTerminalConnected }
            composeRule.runOnUiThread { vm.closeAllSessions() }

            // A contact card only the shell may read.
            DeviceShell.run("content insert --uri content://com.android.contacts/raw_contacts --bind account_name:n: --bind account_type:n:")
            rawContactId = Regex("_id=(\\d+)").findAll(
                DeviceShell.run("content query --uri content://com.android.contacts/raw_contacts --projection _id"),
            ).maxOf { it.groupValues[1].toLong() }.toString()
            DeviceShell.run("content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$rawContactId --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:$NAME")
            val lookup = Regex("lookup=(\\S+)").find(
                DeviceShell.run("content query --uri content://com.android.contacts/contacts --projection lookup --where name_raw_contact_id=$rawContactId"),
            )!!.groupValues[1]
            val card = "content://com.android.contacts/contacts/as_vcard/$lookup"
            assertThrows("OmniTerm cannot read it by itself", SecurityException::class.java) {
                context.contentResolver.openInputStream(Uri.parse(card))?.close()
            }

            fun shareCard() = DeviceShell.run(
                "am start -W -n ${context.packageName}/${IncomingActivity::class.java.name} -a android.intent.action.SEND " +
                    "-t text/x-vcard -d $card --eu android.intent.extra.STREAM $card --grant-read-uri-permission",
            )
            // Newest first, as the Transfers list shows them.
            fun uploads() = vm.sftpTransfers.filter { it.direction == "Upload" && it.name.startsWith(NAME) }
            shareCard()
            composeRule.waitUntil(15_000) { vm.currentScreen == Screen.SFTP && vm.sharedUploads.size == 1 }
            // The forwarding screen, and the grant Android gave it, are gone before anything uploads.
            composeRule.waitUntil(15_000) { !DeviceShell.run("dumpsys activity activities").contains(IncomingActivity::class.java.simpleName) }

            // The user picks the host, waits for its first folder, then opens another one.
            composeRule.runOnUiThread { vm.selectedServerId = host.id }
            composeRule.waitUntil(30_000) { vm.activeSftpTab == 1 && !vm.sftpLoading && vm.sftpPath.isNotEmpty() && has("sftp.shared.upload") }
            composeRule.runOnUiThread { vm.loadSftp(REMOTE_DIR) }
            composeRule.waitUntil(30_000) { !vm.sftpLoading && vm.sftpPath == REMOTE_DIR && has("sftp.shared.upload") }
            composeRule.onNodeWithTag("sftp.shared.upload").performClick()
            composeRule.waitUntil(60_000) { uploads().any { it.status != SftpTransferStatus.InProgress } }
            val transfer = uploads().first()
            uploaded = transfer.remotePath
            assertEquals(transfer.message, SftpTransferStatus.Success, transfer.status)
            assertTrue("nothing waits any more", vm.sharedUploads.isEmpty())
            val content = runBlocking { transport.exec(creds, "cat '${transfer.remotePath}'") }
            assertTrue(content, content.contains("BEGIN:VCARD") && content.contains(NAME))

            // The same card again, into the same folder: the user is asked before it is replaced.
            runBlocking { transport.exec(creds, "printf old > '${transfer.remotePath}'") }
            shareCard()
            composeRule.waitUntil(15_000) { vm.sharedUploads.size == 1 && has("sftp.shared.upload") }
            assertEquals("the folder the user opened stays open", REMOTE_DIR, vm.sftpPath)
            composeRule.onNodeWithTag("sftp.shared.upload").performClick()
            val overwrite = hasText(context.getString(R.string.overwrite)) and hasAnyAncestor(isDialog())
            composeRule.waitUntil(15_000) { composeRule.onAllNodes(overwrite).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithText(context.getString(R.string.overwrite_existing_file_s)).assertExists()
            assertEquals("nothing uploads before the user answers", 1, uploads().size)
            composeRule.onNode(overwrite).performClick()
            composeRule.waitUntil(60_000) { uploads().size == 2 && uploads().first().status != SftpTransferStatus.InProgress }
            val second = uploads().first()
            assertEquals(second.message, SftpTransferStatus.Success, second.status)
            assertEquals("the same file", transfer.remotePath, second.remotePath)
            val replaced = runBlocking { transport.exec(creds, "cat '${transfer.remotePath}'") }
            assertTrue(replaced, replaced.startsWith("BEGIN:VCARD"))
            val left = runBlocking { transport.exec(creds, "ls -a $REMOTE_DIR") }.lines().filter { it.contains(NAME) }
            assertEquals("no staged or previous copy is left behind", listOf(transfer.remotePath.substringAfterLast('/')), left)
        } catch (t: Throwable) {
            failure = t
            val now = vm.servers.value.find { it.id == host.id }
            t.addSuppressed(
                AssertionError(
                    "screen=${vm.currentScreen} tab=${vm.activeSftpTab} status=${now?.status} path=${vm.sftpPath} " +
                        "loading=${vm.sftpLoading} error=${vm.sftpError} waiting=${vm.sharedUploads.size}",
                ),
            )
            throw t
        } finally {
            try {
                restoreLaunchIntent()
                composeRule.runOnUiThread { vm.closeAllSessions(); vm.takeSharedUploads() }
                uploaded?.let { path -> runBlocking { transport.exec(creds, "rm -f '$path'") } }
                rawContactId?.let { DeviceShell.run("content delete --uri content://com.android.contacts/raw_contacts?caller_is_syncadapter=true --where _id=$it") }
                transport.shutdown()
            } catch (cleanup: Throwable) {
                failure?.addSuppressed(cleanup) ?: throw cleanup
            }
        }
    }

    private fun handOver(context: android.content.Context, intent: Intent) {
        context.startActivity(intent.setClassName(context.packageName, IncomingActivity::class.java.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        // One word: UiAutomation's shell splits on spaces and has no quoting.
        const val NAME = "OmniTermShareE2E"
        const val REMOTE_DIR = "/tmp"
    }
}
