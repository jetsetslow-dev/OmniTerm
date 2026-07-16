package com.jetsetslow.omniterm

import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.shares.ShareClients
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Real Files UI mutations and recreation over every browsable disposable-lab protocol. */
class E2eFilesUiStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun everyShareUiSurvivesMutationBookmarkRefreshAndRecreation() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_files_ui") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val allShares = repository.getAllNetworkShares()
            .filter { it.name.startsWith("E2E ") }
            .sortedBy { it.protocol }
        assertEquals(setOf("SMB", "FTP", "SFTP", "WEBDAV"), allShares.map { it.protocol.uppercase() }.toSet())
        val requestedProtocol = InstrumentationRegistry.getArguments()
            .getString("omniterm_e2e_files_protocol")
            .orEmpty()
            .uppercase()
        val shares = allShares.filter { requestedProtocol.isBlank() || it.protocol.uppercase() == requestedProtocol }
        assertTrue("No E2E share matched $requestedProtocol", shares.isNotEmpty())

        val originalBookmarks = shares.associate { share ->
            share.id to repository.getSetting("share_bookmarks_${share.id}")
        }
        val runId = System.currentTimeMillis().toString(36)
        val possibleLeftovers = mutableListOf<Triple<NetworkShareEntity, String, String>>()

        try {
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.SFTP)
                vm.activeSftpTab = 1
            }
            composeRule.waitUntil(15_000) { vm.currentScreen == Screen.SFTP && vm.activeSftpTab == 1 }

            for (share in shares) {
                val protocol = share.protocol.uppercase()
                // Sort before normal home-directory content so the row is composed even on a
                // compact device after the header, path bar, and transient status card.
                val originalName = "000-ui-$runId-${protocol.lowercase()}"
                val renamedName = "000-renamed-$runId-${protocol.lowercase()}"

                composeRule.runOnUiThread { vm.openShareBrowser(share) }
                await("$protocol browser load", 30_000) {
                    vm.browsingShare?.id == share.id && vm.sharePath.isNotBlank() &&
                        !vm.shareLoading && vm.shareError.isNullOrBlank()
                }
                val base = vm.sharePath
                possibleLeftovers += Triple(share, base, originalName)
                possibleLeftovers += Triple(share, base, renamedName)
                composeRule.onNodeWithText(share.name).assertExists()

                // Create through the visible dialog, not by calling the mutation API directly.
                composeRule.onNodeWithContentDescription("New folder").performClick()
                composeRule.onNode(hasText("Folder name") and hasSetTextAction()).performTextInput(originalName)
                composeRule.onNodeWithText("Create").performClick()
                await("$protocol create", 30_000) {
                    !vm.shareOpRunning && vm.shareEntries.any { it.name == originalName && it.isDirectory }
                }
                assertTrue(vm.shareStatus?.contains(originalName) == true)
                composeRule.runOnUiThread { vm.shareStatus = null }
                composeRule.waitForIdle()
                // Rename through the row overflow menu and dialog.
                composeRule.onNodeWithContentDescription(
                    "Actions for $originalName",
                    useUnmergedTree = true,
                ).performClick()
                composeRule.onNodeWithText("Rename").performClick()
                composeRule.onNode(hasText("New name") and hasSetTextAction()).performTextReplacement(renamedName)
                composeRule.onNodeWithText("Rename").performClick()
                try {
                    await("$protocol rename", 30_000) {
                        vm.shareError?.let { error ->
                            throw AssertionError(
                                "$protocol rename failed: $error; status=${vm.shareStatus}; " +
                                    "path=${vm.sharePath}; entries=${vm.shareEntries.map { it.name }}",
                            )
                        }
                        !vm.shareOpRunning && vm.shareEntries.any { it.name == renamedName } &&
                            vm.shareEntries.none { it.name == originalName }
                    }
                } catch (failure: AssertionError) {
                    throw AssertionError(
                        "$protocol rename state: running=${vm.shareOpRunning}, error=${vm.shareError}, " +
                            "status=${vm.shareStatus}, path=${vm.sharePath}, " +
                            "entries=${vm.shareEntries.map { it.name }}",
                        failure,
                    )
                }

                // Navigate into the directory, bookmark it from the UI, and prove the unified
                // bookmark model sees the persisted endpoint/path pair.
                composeRule.runOnUiThread { vm.shareNavigateInto(renamedName) }
                await("$protocol enter", 30_000) {
                    !vm.shareLoading && vm.sharePath.endsWith("/$renamedName") && vm.shareError.isNullOrBlank()
                }
                composeRule.onNodeWithContentDescription("Bookmark this folder").performClick()
                await("$protocol bookmark", 10_000) { vm.sharePath in vm.shareBookmarks }
                composeRule.runOnUiThread { vm.loadAllBookmarks() }
                await("$protocol unified bookmark", 10_000) {
                    vm.allBookmarks.any { it.shareId == share.id && it.path == vm.sharePath }
                }

                // Refresh via the visible action, then recreate the Activity while inside the
                // nested share. The ViewModel and browser/bookmark state must remain intact.
                composeRule.onNodeWithContentDescription("Refresh").performClick()
                await("$protocol refresh", 30_000) {
                    !vm.shareLoading && vm.shareError.isNullOrBlank() && vm.sharePath.endsWith("/$renamedName")
                }
                composeRule.activityRule.scenario.recreate()
                composeRule.waitForIdle()
                val recreated = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
                assertSame("$protocol ViewModel replaced during recreation", vm, recreated)
                assertEquals(share.id, recreated.browsingShare?.id)
                assertTrue(recreated.sharePath.endsWith("/$renamedName"))
                assertTrue(recreated.sharePath in recreated.shareBookmarks)

                // Remove the bookmark and navigate up using visible controls, then exercise the
                // destructive confirmation rather than bypassing it through ViewModel helpers.
                composeRule.onNodeWithContentDescription("Remove bookmark").performClick()
                await("$protocol bookmark removal", 10_000) { vm.sharePath !in vm.shareBookmarks }
                composeRule.onNodeWithContentDescription("Up one folder").performClick()
                await("$protocol up", 30_000) {
                    !vm.shareLoading && vm.sharePath == base && vm.shareEntries.any { it.name == renamedName }
                }
                composeRule.runOnUiThread { vm.shareStatus = null }
                composeRule.waitForIdle()
                composeRule.onNodeWithContentDescription(
                    "Actions for $renamedName",
                    useUnmergedTree = true,
                ).performClick()
                composeRule.onNodeWithText("Delete").performClick()
                composeRule.onNodeWithText("Delete").performClick()
                await("$protocol delete", 30_000) {
                    !vm.shareOpRunning && vm.shareEntries.none { it.name == renamedName }
                }
                composeRule.runOnUiThread { vm.closeShareBrowser() }
                composeRule.waitUntil(10_000) { vm.browsingShare == null }
            }
        } finally {
            composeRule.runOnUiThread { vm.closeShareBrowser() }
            // Restore the exact pre-test bookmark strings and remove only uniquely named empty
            // directories if an assertion interrupted the normal UI cleanup path.
            for (share in shares) {
                repository.insertSetting(
                    "share_bookmarks_${share.id}",
                    originalBookmarks[share.id].orEmpty(),
                )
            }
            for ((share, base, name) in possibleLeftovers.asReversed()) {
                val client = runCatching { ShareClients.forShare(share, share.username, share.password) }.getOrNull()
                    ?: continue
                try {
                    runCatching { client.delete(join(base, name), isDirectory = true) }
                } finally {
                    client.close()
                }
            }
        }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                while (!predicate()) delay(100)
            }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", timeout)
        }
    }

    private fun join(parent: String, child: String): String =
        if (parent == "/") "/$child" else "${parent.trimEnd('/')}/$child"
}
