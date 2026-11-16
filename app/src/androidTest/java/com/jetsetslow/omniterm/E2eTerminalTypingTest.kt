package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.MultiSshLayout
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TermKey
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Real SSH input to two distinct repository fixtures, with the same UI used in single/split view.
 * After E2eLabHostProvisioner, run with
 * `./scripts/test-hosts.sh suite E2eTerminalTypingTest omniterm_e2e_terminal_typing=yes host port second_port`.
 */
class E2eTerminalTypingTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun typingOnceReachesBothHostsAndLocksAndBannersStayVisible() = runBlocking {
        assumeTrue(E2eArgs.on("omniterm_e2e_terminal_typing"))
        val secondPort = E2eArgs.require("second_port").toInt()
        val repository = AppRepository(AppDatabase.getDatabase(InstrumentationRegistry.getInstrumentation().targetContext))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        await("provisioned repository host") { vm.servers.value.any { it.name == HOST } }
        val fixture = vm.servers.value.single { it.name == HOST }
        assertEquals(E2eArgs.require("host"), fixture.host)
        assertEquals(E2eArgs.require("port").toInt(), fixture.port)
        repository.getAllServers().filter { it.name == SECOND }.forEach { repository.deleteServerAndDependents(it.id) }
        val secondId = repository.insertServer(fixture.copy(id = 0, name = SECOND,
            port = secondPort, persistentSession = false)).toInt()
        assertNotEquals("Use two distinct fixture endpoints", fixture.port, secondPort)
        try {
            composeRule.runOnUiThread {
                TerminalSessionManager.clearAll()
                vm.isAppLocked = false
                vm.navigateTo(Screen.Shell)
                vm.saveTmuxControlMode(false)
            }
            suspend fun connect(id: Int): ShellSession {
                composeRule.runOnUiThread {
                    vm.selectedServerId = id
                    vm.connectTerminal()
                }
                await("SSH fixture $id", 40_000) {
                    if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
                    if (vm.offlineConnectPromptServer != null) vm.connectTerminalConfirmedOffline()
                    !vm.isTerminalConnecting && vm.currentSession?.serverId == id && vm.currentSession?.isConnected == true
                }
                return checkNotNull(vm.currentSession)
            }
            val first = connect(fixture.id)
            val second = connect(secondId)
            composeRule.runOnUiThread { vm.currentSessionId = first.id }
            composeRule.waitForIdle()
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            composeRule.onNodeWithContentDescription("Open terminal options").performClick()
            composeRule.onNodeWithTag("terminal.typing.options").performScrollTo().performClick()
            composeRule.onNodeWithText("Type to several terminals").assertIsDisplayed()
            composeRule.onNodeWithTag("terminal.typing.pick.${first.id}").assertIsDisplayed().assertTextContains(HOST)
            composeRule.onNodeWithTag("terminal.typing.pick.${second.id}").assertIsDisplayed().assertTextContains(SECOND)
            composeRule.onNodeWithTag("terminal.typing.all").performClick()
            composeRule.onNodeWithTag("terminal.typing.apply").performClick()
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").assertIsDisplayed()
            composeRule.onNodeWithText("Typing to 2 terminals · tap for hosts").assertIsDisplayed()
            // A single interactive action enters the same command on the two live SSH sessions.
            // The contiguous marker appears only in output, never in the echoed command.
            fun typeMarker(left: String, right: String) {
                vm.typeText("printf '%s%s\\n' '$left' '$right'")
                vm.sendKey(TermKey.ENTER)
            }
            composeRule.onNodeWithTag("terminal.input.${first.id}")
                .performTextInput("printf '%s%s\\n' 'BROADCAST-' 'REACHED-BOTH'")
            composeRule.onNodeWithText("↵").performClick()
            await("output on both hosts") {
                listOf(first, second).all { vm.terminalBufferTextFor(it, true).contains("BROADCAST-REACHED-BOTH") }
            }
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").performClick()
            composeRule.onAllNodesWithText("Receiving your typing").assertCountEquals(2)
            composeRule.onNodeWithText("Cancel").performClick()

            composeRule.runOnUiThread {
                vm.enterMultiSsh()
                vm.assignMultiSshPane(1, first.id)
                vm.assignMultiSshPane(2, second.id)
                vm.multiSshLayout = MultiSshLayout.Stacked
                vm.setMultiSshFocus(2)
                vm.updateTerminalReadOnly(true)
                vm.setMultiSshFocus(1)
            }
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").assertIsDisplayed()
            composeRule.onNodeWithTag("terminal.typing.banner.${second.id}").assertIsDisplayed().performClick()
            composeRule.onNodeWithText("Left out: input locked").assertIsDisplayed()
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.runOnUiThread { typeMarker("ONLY-", "UNLOCKED") }
            await("unlocked fixture output") { vm.terminalBufferTextFor(first, true).contains("ONLY-UNLOCKED") }
            // This ordered round trip on the omitted host is a barrier, not a timing assertion.
            composeRule.runOnUiThread {
                vm.setMultiSshFocus(2)
                vm.updateTerminalReadOnly(false)
                vm.selectTerminalTyping(setOf(second.id))
                typeMarker("SECOND-", "BARRIER")
            }
            await("excluded host barrier") { vm.terminalBufferTextFor(second, true).contains("SECOND-BARRIER") }
            assertFalse(vm.terminalBufferTextFor(second, true).contains("ONLY-UNLOCKED"))
            // One receiver reads as one, in the banner and in the paste confirmation.
            composeRule.runOnUiThread {
                vm.selectTerminalTyping(setOf(first.id))
                vm.setMultiSshFocus(1)
                vm.pasteText("printf 'one\\n'\nprintf 'two\\n'")
            }
            composeRule.onNodeWithText("Typing to 1 terminal · tap for hosts").assertIsDisplayed()
            composeRule.onNodeWithText("Paste into 1 terminal?", substring = true).assertIsDisplayed()
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.onNodeWithText("OK").performClick()
            composeRule.runOnUiThread {
                vm.selectTerminalTyping(setOf(first.id, second.id))
                vm.setMultiSshFocus(1)
                vm.pasteText("printf 'line-one\\n'\nprintf 'line-two\\n'")
            }
            composeRule.onNodeWithText("Paste into 2 terminals?", substring = true).assertIsDisplayed()
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.onNodeWithText("OK").performClick() // session-owned cancellation feedback
            composeRule.runOnUiThread { vm.multiSshLayout = MultiSshLayout.SideBySide }
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").assertIsDisplayed()
            composeRule.onNodeWithTag("terminal.typing.banner.${second.id}").assertIsDisplayed()
            composeRule.runOnUiThread { vm.exitMultiSsh(); vm.currentSessionId = first.id }
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").assertIsDisplayed().performClick()
            composeRule.onNodeWithTag("terminal.typing.stop").performClick()
            assertFalse(vm.terminalTyping.enabled)
            composeRule.onNodeWithTag("terminal.typing.banner.${first.id}").assertDoesNotExist()
            composeRule.runOnUiThread {
                vm.selectTerminalTyping(setOf(first.id, second.id))
                vm.isAppLocked = true
            }
            assertFalse(vm.terminalTyping.enabled)
            composeRule.runOnUiThread { vm.isAppLocked = false }
        } finally {
            composeRule.runOnUiThread { vm.stopTerminalTyping(); TerminalSessionManager.clearAll() }
            repository.deleteServerAndDependents(secondId)
        }
    }

    /** Read related ViewModel state and approve fixture keys together on main. */
    private suspend fun await(label: String, timeoutMs: Long = 20_000, ready: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                var done = false
                while (!done) {
                    composeRule.runOnUiThread { done = ready() }
                    if (!done) delay(50)
                }
            }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish", failure)
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val SECOND = "E2E Typing Direct Fixture"
    }
}
