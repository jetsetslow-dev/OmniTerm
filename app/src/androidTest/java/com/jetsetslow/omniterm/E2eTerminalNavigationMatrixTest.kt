package com.jetsetslow.omniterm

import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.withTagValue
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.espresso.matcher.RootMatchers.isDialog
import org.hamcrest.Matchers.containsString
import org.hamcrest.Matchers.equalTo
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Physical UI coverage for every leave-terminal route without contacting a remote host. */
class E2eTerminalNavigationMatrixTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()
    private lateinit var vm: AppViewModel

    @Test
    fun switchingSameSizeSessionsRefreshesViewportAndVisibleCopy() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString(ARGUMENT) == "yes")
        vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val wasReadOnly = vm.terminalReadOnly
        val repository = AppRepository(AppDatabase.getDatabase(composeRule.activity))
        val createdHosts = mutableListOf<ServerEntity>()
        try {
            repeat(2) { index ->
                val host = ServerEntity(name = "E2E Copy $index", host = "copy-$index.invalid", username = "fixture")
                createdHosts += host.copy(id = repository.insertServer(host).toInt())
            }
            await("fixture hosts loaded", 5_000) { createdHosts.all { host -> vm.servers.value.any { it.id == host.id } } }
            // Keep IME geometry stable: a keyboard resize must not accidentally repair the switch.
            composeRule.runOnUiThread { vm.updateTerminalReadOnly(true) }
            val sessions = seed(vm, persistent = listOf(false, false), split = false, serverIds = createdHosts.map { it.id })
            // Establish the same host-selection chrome for BOTH synthetic hosts. Leaving a real
            // saved host selected initially can change the layout at the second attach and mask
            // the bug with an unrelated resize.
            composeRule.runOnUiThread { vm.attachSession(sessions[0].id) }
            composeRule.waitForIdle()
            composeRule.mainClock.advanceTimeBy(200) // Drive the pane's 120ms Compose resize debounce.
            composeRule.waitForIdle()
            composeRule.onNode(hasContentDescription("Terminal output:", substring = true), useUnmergedTree = true).assertIsDisplayed()
            composeRule.runOnUiThread {
                sessions.forEachIndexed { index, session ->
                    synchronized(session.emulator) {
                        session.emulator.feed((1..80).joinToString("") { "HOST_${index}_ROW_$it\r\n" }.toByteArray())
                    }
                    TerminalSessionManager.publishTerminalSnapshot(session)
                }
            }
            await("first viewport measured", 5_000) { sessions[0].viewportRowCount > 1 }
            composeRule.runOnUiThread { vm.attachSession(sessions[1].id) }
            composeRule.waitForIdle()
            composeRule.mainClock.advanceTimeBy(200)
            composeRule.waitForIdle()
            val selected = sessions[1]
            try {
                await("switched viewport matches its rendered grid", 5_000) {
                    selected.viewportRowCount > 1 && selected.viewportRowCount == selected.termRows
                }
            } catch (error: AssertionError) {
                throw AssertionError("Selected viewport=${selected.viewportRowCount}, grid=${selected.termCols}x${selected.termRows}; " +
                    "previous viewport=${sessions[0].viewportRowCount}, grid=${sessions[0].termCols}x${sessions[0].termRows}", error)
            }
            val visible = vm.terminalBufferTextFor(selected, false, selected.viewportFirstRow, selected.viewportRowCount)
            assertTrue("visible copy must contain the selected host", visible.contains("HOST_1_ROW_80"))
            assertFalse("visible copy must not contain another host", visible.contains("HOST_0_"))
            assertTrue("full copy remains available", vm.terminalBufferTextFor(selected, true).contains("HOST_1_ROW_1"))
            // Long press must expose the full-range action without hunting through another menu.
            composeRule.onNode(hasContentDescription("Terminal output:", substring = true), useUnmergedTree = true)
                .performTouchInput { longClick() }
            composeRule.onNodeWithText("Show full buffer").assertIsDisplayed()
            onView(withTagValue(equalTo("terminal_copy_text"))).inRoot(isDialog())
                .check(matches(withText(containsString("HOST_1_ROW_80"))))
            composeRule.onNodeWithText("Show full buffer").assertIsDisplayed().performClick()
            composeRule.onNodeWithText("Full buffer").assertIsDisplayed()
            composeRule.onNodeWithText("Show visible screen").assertIsDisplayed().performClick()
            composeRule.onNodeWithText("Visible screen").assertIsDisplayed()
            clickText("Close")
            clickText("⋮ OPT")
            composeRule.onNode(SemanticsMatcher("content below is indicated") {
                it.config.contains(SemanticsProperties.StateDescription) &&
                    it.config[SemanticsProperties.StateDescription].contains("More below")
            }, useUnmergedTree = true).assertExists()
            composeRule.onNodeWithText("Full buffer").performScrollTo().assertIsDisplayed()
            composeRule.onNode(SemanticsMatcher("content above is indicated") {
                it.config.contains(SemanticsProperties.StateDescription) &&
                    it.config[SemanticsProperties.StateDescription].contains("More above")
            }, useUnmergedTree = true).assertExists()
            clickText("Full buffer")
            composeRule.onNodeWithText("Show visible screen").assertIsDisplayed()
            clickText("Close")
        } finally {
            composeRule.runOnUiThread {
                vm.updateTerminalReadOnly(wasReadOnly)
                TerminalSessionManager.clearAll()
            }
            createdHosts.forEach { repository.deleteServerAndDependents(it.id) }
        }
    }

    @Test
    fun recoverySaveProgressFailureAndRetryAreVisibleWithoutClosingPanes() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString(ARGUMENT) == "yes")
        vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val priorKeepAlive = vm.isBackgroundKeepAlive
        val created = linkedSetOf<String>()
        val db = AppDatabase.getDatabase(composeRule.activity)
        val repository = AppRepository(db)
        val release = CompletableDeferred<Unit>()
        var blocker: kotlinx.coroutines.Job? = null
        try {
            composeRule.runOnUiThread { vm.saveBackgroundKeepAliveToggle(false) }
            val sessions = seed(vm, persistent = listOf(true, true), split = true, createdTmuxNames = created)
            withContext(Dispatchers.IO) {
                // Test-owned names contain only letters, digits and hyphens.
                db.openHelper.writableDatabase.execSQL(
                    "CREATE TRIGGER e2e_reject_leave BEFORE INSERT ON persistent_sessions " +
                        "WHEN NEW.tmuxName = '${sessions[1].tmuxName}' " +
                        "BEGIN SELECT RAISE(ABORT, 'fixture storage unavailable'); END",
                )
            }
            val entered = CompletableDeferred<Unit>()
            blocker = launch(Dispatchers.IO) {
                repository.inTransaction { entered.complete(Unit); release.await() }
            }
            withTimeout(5_000) { entered.await() }
            clickText("Monitor")
            awaitPrompt("2 active SSH sessions")
            clickText("Leave resumable")
            assertUiText("Saving resumable sessions… Please wait.")
            composeRule.onNodeWithText("Stay").assertIsNotEnabled()
            composeRule.onNodeWithText("Leave resumable").assertIsNotEnabled()
            assertEquals(Screen.Shell, vm.currentScreen)
            assertSplitAttached(vm, sessions)
            assertFalse(sessions.any { it.userClosed })
            release.complete(Unit)
            blocker.join()
            await("visible recovery error", 5_000) { !vm.isLeavingTerminalSessions && vm.terminalLeaveError != null }
            composeRule.onNodeWithText("Could not save session recovery.", substring = true, useUnmergedTree = true).assertExists()
            assertSplitAttached(vm, sessions)
            assertTrue(repository.getPersistentSessions().none { it.tmuxName in created })
            withContext(Dispatchers.IO) { db.openHelper.writableDatabase.execSQL("DROP TRIGGER e2e_reject_leave") }
            clickText("Leave resumable")
            await("retry saves before navigating", 10_000) {
                !vm.isLeavingTerminalSessions && vm.currentScreen == Screen.Monitor && vm.activeSessions.isEmpty()
            }
            assertTrue(repository.getPersistentSessions().map { it.tmuxName }.containsAll(created))
        } finally {
            release.complete(Unit)
            blocker?.join()
            withContext(Dispatchers.IO) { db.openHelper.writableDatabase.execSQL("DROP TRIGGER IF EXISTS e2e_reject_leave") }
            composeRule.runOnUiThread {
                vm.cancelTerminalNavigation()
                TerminalSessionManager.clearAll()
                vm.saveBackgroundKeepAliveToggle(priorKeepAlive)
            }
            created.forEach { repository.deletePersistentSession(it) }
        }
    }

    @Test
    fun directTabsAccidentalClicksAndEveryPaneLifecycleCombinationRemainOneShot() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString(ARGUMENT) == "yes")
        vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val priorKeepAlive = vm.isBackgroundKeepAlive
        val createdTmuxNames = linkedSetOf<String>()

        TerminalSessionManager.clearAll()
        try {
            composeRule.runOnUiThread { vm.saveBackgroundKeepAliveToggle(false) }
            await("disable permission overlay", 5_000) { !vm.isBackgroundKeepAlive }

            // A two-pane terminal must intercept every direct bottom-tab route exactly once. Stay
            // models an accidental tap: it may not detach, disconnect, or change the destination.
            val split = seed(vm, persistent = listOf(false, false), split = true)
            for (tab in DESTINATION_TABS) {
                clickText(tab)
                awaitPrompt("2 active SSH sessions")
                assertEquals(Screen.Shell, vm.currentScreen)
                clickText("Stay")
                await("dismiss $tab transaction", 5_000) { !vm.showDisconnectTerminalDialog }
                assertSplitAttached(vm, split)
            }

            // System Back uses the same transaction and a dismissed dialog remains retryable.
            shell("input keyevent KEYCODE_BACK")
            awaitPrompt("2 active SSH sessions")
            shell("input keyevent KEYCODE_BACK")
            await("system dismiss", 5_000) { !vm.showDisconnectTerminalDialog }
            assertSplitAttached(vm, split)
            clickText("Monitor")
            awaitPrompt("2 active SSH sessions")
            clickText("Send to background")
            await("both ordinary panes backgrounded", 5_000) {
                vm.currentScreen == Screen.Monitor && vm.isMultiSsh &&
                    vm.multiSshSessionId1 == null && vm.multiSshSessionId2 == null &&
                    vm.activeSessions.size == 2
            }
            clickText("Files")
            await("background sessions do not re-prompt", 5_000) {
                vm.currentScreen == Screen.SFTP && !vm.showDisconnectTerminalDialog
            }
            clickText("Term")
            await("return to preserved empty split", 5_000) {
                vm.currentScreen == Screen.Shell && vm.isMultiSsh &&
                    vm.multiSshSessionId1 == null && vm.multiSshSessionId2 == null
            }
            clickText("Containers")
            await("empty split can leave without a prompt", 5_000) {
                vm.currentScreen == Screen.Infra && !vm.showDisconnectTerminalDialog
            }

            // An unsplit session follows the same accidental-click and background contract.
            val single = seed(vm, persistent = listOf(false), split = false).single()
            clickText("Files")
            awaitPrompt("Active SSH session")
            clickText("Stay")
            await("single stays attached", 5_000) {
                vm.currentScreen == Screen.Shell && vm.currentSessionId == single.id
            }
            clickText("Monitor")
            awaitPrompt("Active SSH session")
            clickText("Send to background")
            await("single background", 5_000) {
                vm.currentScreen == Screen.Monitor && vm.currentSessionId == null && vm.activeSessions.singleOrNull()?.id == single.id
            }

            // Split mode with only one connected pane still prompts for exactly that pane.
            val loneSplit = seed(vm, persistent = listOf(false), split = true).single()
            clickText("Fleet")
            awaitPrompt("Active SSH session")
            assertEquals(listOf(loneSplit.id), vm.pendingTerminalNavigationSessions.map { it.id })
            clickText("Disconnect")
            await("one-pane split disconnect", 5_000) {
                vm.currentScreen == Screen.Fleet && vm.activeSessions.isEmpty()
            }

            // If one pane was already disconnected, only the remaining pane is captured. If both
            // are gone, direct navigation commits immediately with no stale dialog.
            val oneRemaining = seed(vm, persistent = listOf(false, false), split = true)
            composeRule.runOnUiThread { vm.disconnectSession(oneRemaining.first().id) }
            await("first split pane disconnected", 5_000) { vm.activeSessions.size == 1 }
            clickText("Files")
            awaitPrompt("Active SSH session")
            assertEquals(listOf(oneRemaining.last().id), vm.pendingTerminalNavigationSessions.map { it.id })
            clickText("Send to background")
            await("remaining pane backgrounded", 5_000) { vm.currentScreen == Screen.SFTP }

            val noneRemaining = seed(vm, persistent = listOf(false, false), split = true)
            composeRule.runOnUiThread {
                noneRemaining.forEach { vm.disconnectSession(it.id) }
            }
            await("both split panes disconnected", 5_000) { vm.activeSessions.isEmpty() }
            clickText("Containers")
            await("zero-pane direct navigation", 5_000) {
                vm.currentScreen == Screen.Infra && !vm.showDisconnectTerminalDialog
            }

            // A mixed split applies the correct non-destructive action per pane from one dialog:
            // ordinary SSH remains live in background; tmux is closed locally and saved resumable.
            val mixed = seed(vm, persistent = listOf(false, true), split = true, createdTmuxNames)
            clickText("Monitor")
            awaitPrompt("2 active SSH sessions")
            assertUiText("Keep sessions")
            clickText("Keep sessions")
            await("mixed split lifecycle", 10_000) {
                vm.currentScreen == Screen.Monitor &&
                    vm.activeSessions.map { it.id } == listOf(mixed.first().id) &&
                    mixed.last().session.closed.value
            }
            assertFalse(mixed.first().session.closed.value)
            assertTrue(mixed.last().session.closed.value)

            // Unsplit and all-tmux split routes expose Leave resumable directly and never disguise
            // it as background. Both cases must complete the original direct-tab destination.
            val persistentSingle = seed(vm, persistent = listOf(true), split = false, createdTmuxNames).single()
            clickText("Tools")
            awaitPrompt("Persistent SSH session")
            assertUiText("Leave resumable")
            clickText("Leave resumable")
            await("single tmux left resumable", 10_000) {
                vm.currentScreen == Screen.Tools && vm.activeSessions.none { it.id == persistentSingle.id }
            }

            seed(vm, persistent = listOf(true, true), split = true, createdTmuxNames)
            clickText("Files")
            awaitPrompt("2 active SSH sessions")
            assertUiText("Leave resumable")
            clickText("Leave resumable")
            await("both tmux panes left resumable", 10_000) {
                vm.currentScreen == Screen.SFTP && vm.activeSessions.isEmpty()
            }

            // The destructive split decision remains a single gate and disconnects both panes.
            seed(vm, persistent = listOf(false, false), split = true)
            clickText("Tools")
            awaitPrompt("2 active SSH sessions")
            clickText("Disconnect all")
            await("split disconnect all", 5_000) {
                vm.currentScreen == Screen.Tools && vm.activeSessions.isEmpty()
            }
        } finally {
            composeRule.runOnUiThread {
                vm.cancelTerminalNavigation()
                vm.closeAllSessions()
                vm.saveBackgroundKeepAliveToggle(priorKeepAlive)
            }
            val dao = AppDatabase.getDatabase(composeRule.activity).persistentSessionDao()
            createdTmuxNames.forEach { dao.delete(it) }
            TerminalSessionManager.clearAll()
        }
    }

    private suspend fun seed(
        vm: AppViewModel,
        persistent: List<Boolean>,
        split: Boolean,
        createdTmuxNames: MutableSet<String> = linkedSetOf(),
        serverIds: List<Int>? = null,
    ): List<ShellSession> {
        lateinit var result: List<ShellSession>
        composeRule.runOnUiThread {
            vm.cancelTerminalNavigation()
            TerminalSessionManager.clearAll()
            vm.navigateTo(Screen.Shell)
            result = persistent.mapIndexed { index, isPersistent ->
                val id = "e2e-nav-${if (isPersistent) "tmux" else "direct"}-$index-${System.nanoTime()}"
                ShellSession(
                    serverId = serverIds?.get(index) ?: id.hashCode(),
                    serverName = "E2E Navigation ${index + 1}",
                    session = FakeTerminalSession(),
                    emulator = TerminalEmulator(80, 24),
                    id = id,
                ).also { session ->
                    session.persistent = isPersistent
                    if (isPersistent) {
                        session.tmuxName = "omniterm-e2e-navigation-${System.nanoTime()}-$index"
                        createdTmuxNames += session.tmuxName
                    }
                    TerminalSessionManager.addSession(session)
                }
            }
            if (split) {
                vm.activeSshTab = 1
                vm.multiSshSessionId1 = result.firstOrNull()?.id
                vm.multiSshSessionId2 = result.getOrNull(1)?.id
                vm.multiSshFocusedPane = 1
            } else {
                vm.activeSshTab = 0
                vm.currentSessionId = result.firstOrNull()?.id
            }
        }
        composeRule.waitForIdle()
        // A focused terminal can raise the IME immediately. In landscape the app deliberately
        // hides global chrome while the keyboard is visible, so explicitly close it before testing
        // bottom-tab navigation rather than mistaking keyboard state for a missing nav item.
        composeRule.runOnUiThread {
            composeRule.activity.currentFocus?.clearFocus()
            WindowInsetsControllerCompat(
                composeRule.activity.window,
                composeRule.activity.window.decorView,
            ).hide(WindowInsetsCompat.Type.ime())
        }
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("Term", useUnmergedTree = true)
                .fetchSemanticsNodes().isNotEmpty()
        }
        return result
    }

    private suspend fun awaitPrompt(title: String) {
        await("$title prompt", 5_000) { vm.showDisconnectTerminalDialog }
        assertUiText(title)
        assertUiText("Stay")
    }

    private fun clickText(text: String) {
        composeRule.onNodeWithText(text, useUnmergedTree = true).performClick()
        composeRule.waitForIdle()
    }

    private fun assertUiText(text: String) {
        composeRule.onNodeWithText(text, useUnmergedTree = true).assertExists()
    }

    private fun assertSplitAttached(vm: AppViewModel, sessions: List<ShellSession>) {
        assertTrue(vm.isMultiSsh)
        assertEquals(sessions[0].id, vm.multiSshSessionId1)
        assertEquals(sessions[1].id, vm.multiSshSessionId2)
        assertEquals(sessions.map { it.id }, vm.activeSessions.map { it.id })
        assertFalse(sessions.any { it.session.closed.value })
    }

    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(50) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private class FakeTerminalSession : TerminalSession {
        override val output: Flow<ByteArray> = emptyFlow()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)

        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }

    private companion object {
        const val ARGUMENT = "omniterm_e2e_terminal_nav_matrix"
        val DESTINATION_TABS = listOf("Servers", "Fleet", "Monitor", "Files", "Containers", "Tools")
    }
}
