package com.jetsetslow.omniterm

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Real control-mode tmux switch while the clipboard confirmation remains open. */
class E2eTerminalPasteOwnershipTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun pendingClipboardPasteDoesNotFollowAChangedTmuxPane() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_paste_ownership") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val fixture = requireNotNull(repository.getServerByName(HOST)) { "Provision the repository fixture first" }
        val originalControlMode = repository.getSetting("tmux_control_mode") == "true"
        val originalReadOnly = vm.terminalReadOnly
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        var ownedTmuxName: String? = null
        TerminalSessionManager.clearAll()
        try {
            repository.updateServer(fixture.copy(persistentSession = true))
            await("persistent fixture published", 15_000) {
                vm.servers.value.any { it.id == fixture.id && it.persistentSession }
            }
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.updateTerminalReadOnly(false)
                vm.saveTmuxControlMode(true)
            }
            await("control-mode setting published", 15_000) {
                vm.tmuxControlMode && repository.getSetting("tmux_control_mode") == "true"
            }
            composeRule.runOnUiThread {
                vm.selectedServerId = fixture.id
                vm.navigateTo(Screen.Shell)
                vm.connectTerminal()
            }
            await("fixture control-mode shell", 30_000) {
                composeRule.runOnUiThread {
                    if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
                    if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
                }
                val shell = vm.currentSession
                !vm.isTerminalConnecting && shell?.isConnected == true && shell.controlMode &&
                    shell.controlReady && shell.activePaneId != null
            }
            val shell = requireNotNull(vm.currentSession)
            val transport = shell.session
            val revision = shell.controlPaneChangeRevision.get()
            ownedTmuxName = shell.tmuxName
            val target = RemoteCommands.shellQuote(shell.tmuxName)
            val pane = vm.executeSshCommand(
                fixture,
                "tmux new-window -d -P -F '#{pane_id}' -t $target -n paste-owner-check 'stty -echo; cat'",
            ).trim()
            check(Regex("%[0-9]+").matches(pane)) { "Fixture did not return a tmux pane id" }
            await("quiet fixture pane running cat", 15_000) {
                vm.executeSshCommand(
                    fixture,
                    "tmux display-message -p -t ${RemoteCommands.shellQuote(pane)} '#{pane_current_command}'",
                ).trim() == "cat"
            }
            val marker = "PENDING-PASTE-OWNER-" + "x".repeat(170)
            composeRule.runOnUiThread { clipboard.setPrimaryClip(ClipData.newPlainText("fixture", marker)) }
            composeRule.onNodeWithContentDescription("Open terminal options").performClick()
            composeRule.onNodeWithText("Paste from clipboard").performClick()
            composeRule.onNodeWithText("Paste ${marker.length} characters?").assertIsDisplayed()

            vm.executeSshCommand(fixture, "tmux select-window -t ${RemoteCommands.shellQuote(shell.tmuxName + ":paste-owner-check")}")
            await("same shell has settled on the replacement pane", 15_000) {
                vm.currentSession === shell && shell.session === transport && shell.controlReady &&
                    shell.activePaneId == pane && shell.controlPaneChangeRevision.get() > revision
            }
            composeRule.onNodeWithText("Paste").performClick()
            // This fence uses the same ordered terminal queue after the confirmation. Seeing it
            // remotely proves that preceding paste bytes had their opportunity to arrive; an
            // arbitrary delay or an empty capture would not establish suppression.
            composeRule.runOnUiThread { vm.pasteText("\nPASTE-OWNER-FENCE\n") }
            var capture = ""
            await("ordered terminal fence observed remotely", 15_000) {
                capture = vm.executeSshCommand(fixture, "tmux capture-pane -p -J -t ${RemoteCommands.shellQuote(pane)}")
                capture.contains("PASTE-OWNER-FENCE")
            }
            assertSame("No reconnect may disguise a pane change", transport, shell.session)
            assertFalse("Pending clipboard paste was redirected into the replacement pane", capture.contains("PENDING-PASTE-OWNER-"))
            composeRule.onNodeWithText("Terminal pane changed.", substring = true).assertIsDisplayed()
            composeRule.onNodeWithText("OK").assertIsDisplayed().performClick()
            val delivered = "PASTE-RECEIPT-OK"
            composeRule.runOnUiThread { clipboard.setPrimaryClip(ClipData.newPlainText("fixture", delivered)) }
            composeRule.onNodeWithContentDescription("Open terminal options").performClick()
            composeRule.onNodeWithText("Paste from clipboard").performClick()
            await("paste transport result", 15_000) { shell.pasteFeedback?.busy == false }
            composeRule.onNodeWithText("Sent ${delivered.length} characters to terminal.").assertIsDisplayed()
            composeRule.onNodeWithText("OK").assertIsDisplayed().performClick()
            composeRule.runOnUiThread { vm.pasteText("\nPASTE-RECEIPT-FENCE\n") }
            await("successful paste observed on its captured pane", 15_000) {
                val after = vm.executeSshCommand(fixture, "tmux capture-pane -p -J -t ${RemoteCommands.shellQuote(pane)}")
                after.contains(delivered) && after.contains("PASTE-RECEIPT-FENCE")
            }
        } finally {
            try {
                ownedTmuxName?.let { name ->
                    try {
                        vm.executeSshCommand(fixture, "tmux kill-session -t ${RemoteCommands.shellQuote(name)}")
                    } finally {
                        repository.deletePersistentSession(name)
                    }
                }
            } finally {
                TerminalSessionManager.clearAll()
                repository.updateServer(fixture)
                composeRule.runOnUiThread {
                    clipboard.clearPrimaryClip()
                    vm.saveTmuxControlMode(originalControlMode)
                    vm.updateTerminalReadOnly(originalReadOnly)
                }
                await("control-mode preference restored", 15_000) {
                    vm.tmuxControlMode == originalControlMode &&
                        (repository.getSetting("tmux_control_mode") == "true") == originalControlMode
                }
            }
        }
    }

    private suspend fun await(label: String, timeoutMs: Long, ready: suspend () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!ready()) delay(100) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private companion object { const val HOST = "E2E Foreground Demo" }
}
