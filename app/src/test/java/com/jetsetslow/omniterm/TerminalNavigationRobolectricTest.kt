package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TerminalNavigationRobolectricTest {

    private lateinit var viewModel: AppViewModel

    @Before
    fun setUp() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
        TerminalSessionManager.clearAll()
        viewModel = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        viewModel.navigateTo(Screen.Shell)
    }

    @After
    fun tearDown() {
        if (::viewModel.isInitialized) viewModel.cancelTerminalNavigation()
        TerminalSessionManager.clearAll()
    }

    @Test
    fun singleSessionKeepCompletesNavigationWithoutReopeningDialog() {
        val session = addSession("single")
        viewModel.currentSessionId = session.id

        viewModel.navigateTo(Screen.Monitor)
        assertTrue(viewModel.showDisconnectTerminalDialog)
        assertEquals(listOf("single"), viewModel.pendingTerminalNavigationSessions.map { it.id })

        viewModel.completeTerminalNavigation(disconnect = false)

        assertEquals(Screen.Monitor, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertNull(viewModel.pendingNavigationScreen)
        assertNull(viewModel.currentSessionId)
        assertTrue(TerminalSessionManager.activeSessions.contains(session))
    }

    @Test
    fun splitExitRacePromptsForOnlyTheRemainingLiveSession() {
        val exited = addSession("exited", remoteExited = true, exitStatus = 0)
        val live = addSession("live")
        enterSplit(exited, live)

        viewModel.navigateTo(Screen.Infra)

        assertEquals(listOf("live"), viewModel.pendingTerminalNavigationSessions.map { it.id })
        viewModel.completeTerminalNavigation(disconnect = false)
        assertEquals(Screen.Infra, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
    }

    @Test
    fun twoLiveSplitPanesUseOneDecisionAndBackgroundBoth() {
        val first = addSession("first")
        val second = addSession("second")
        enterSplit(first, second)

        viewModel.navigateTo(Screen.SFTP)
        assertEquals(listOf("first", "second"), viewModel.pendingTerminalNavigationSessions.map { it.id })

        viewModel.completeTerminalNavigation(disconnect = false)

        assertEquals(Screen.SFTP, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertNull(viewModel.multiSshSessionId1)
        assertNull(viewModel.multiSshSessionId2)
        assertEquals(setOf("first", "second"), TerminalSessionManager.activeSessions.map { it.id }.toSet())
    }

    @Test
    fun disconnectDecisionTearsDownEveryCapturedPane() {
        enterSplit(addSession("first"), addSession("second"))
        viewModel.navigateTo(Screen.Fleet)

        viewModel.completeTerminalNavigation(disconnect = true)

        assertEquals(Screen.Fleet, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertTrue(TerminalSessionManager.activeSessions.isEmpty())
    }

    @Test
    fun reconnectingPaneStillRequiresDecision() {
        val reconnecting = addSession("retry", connected = false, reconnecting = true)
        viewModel.currentSessionId = reconnecting.id

        viewModel.navigateTo(Screen.Tools)

        assertTrue(viewModel.showDisconnectTerminalDialog)
        assertEquals(listOf("retry"), viewModel.pendingTerminalNavigationSessions.map { it.id })
    }

    @Test
    fun inFlightConnectionCanBeCancelledOrAllowedInBackground() {
        viewModel.isTerminalConnecting = true
        viewModel.navigateTo(Screen.Monitor)
        assertTrue(viewModel.pendingTerminalNavigationIncludesConnectAttempt)
        assertTrue(viewModel.pendingTerminalNavigationSessions.isEmpty())

        viewModel.completeTerminalNavigation(disconnect = false)
        assertEquals(Screen.Monitor, viewModel.currentScreen)
        assertTrue(viewModel.isTerminalConnecting)

        viewModel.navigateTo(Screen.Shell)
        viewModel.navigateTo(Screen.Servers)
        viewModel.completeTerminalNavigation(disconnect = true)
        assertFalse(viewModel.isTerminalConnecting)
        assertEquals(Screen.Servers, viewModel.currentScreen)
    }

    @Test
    fun newestDestinationWinsWhileOneDialogRemainsOpen() {
        val session = addSession("session")
        viewModel.currentSessionId = session.id

        viewModel.navigateTo(Screen.Monitor)
        viewModel.navigateTo(Screen.Tools)

        assertTrue(viewModel.showDisconnectTerminalDialog)
        assertEquals(Screen.Tools, viewModel.pendingNavigationScreen)
        viewModel.completeTerminalNavigation(disconnect = false)
        assertEquals(Screen.Tools, viewModel.currentScreen)
    }

    @Test
    fun stayAndDismissClearTheWholeTransaction() {
        val session = addSession("session")
        viewModel.currentSessionId = session.id
        viewModel.navigateTo(Screen.Monitor)

        viewModel.cancelTerminalNavigation()

        assertEquals(Screen.Shell, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertNull(viewModel.pendingNavigationScreen)
        assertTrue(viewModel.pendingTerminalNavigationSessions.isEmpty())
    }

    @Test
    fun backNavigationUsesTheSameOneShotTransaction() {
        val session = addSession("session")
        viewModel.currentSessionId = session.id

        assertTrue(viewModel.navigateBack())
        assertTrue(viewModel.showDisconnectTerminalDialog)
        viewModel.completeTerminalNavigation(disconnect = false)

        assertEquals(Screen.Servers, viewModel.currentScreen)
        assertEquals(listOf(Screen.Servers), viewModel.screenHistory)
        assertFalse(viewModel.showDisconnectTerminalDialog)
    }

    @Test
    fun notificationResumeSupersedesPendingNavigation() {
        val session = addSession("session")
        viewModel.currentSessionId = session.id
        viewModel.navigateTo(Screen.Monitor)
        assertTrue(viewModel.showDisconnectTerminalDialog)

        viewModel.attachSession(session.id)

        assertEquals(Screen.Shell, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertNull(viewModel.pendingNavigationScreen)
    }

    @Test
    fun globalAlertsPopupDoesNotEnterTerminalLeaveTransaction() {
        val session = addSession("alerted")
        viewModel.currentSessionId = session.id

        viewModel.openAlertsPopup()

        assertTrue(viewModel.showAlertsPopup)
        assertEquals(Screen.Shell, viewModel.currentScreen)
        assertFalse(viewModel.showDisconnectTerminalDialog)
        assertNull(viewModel.pendingNavigationScreen)
        assertTrue(session.isConnected)
        assertTrue(TerminalSessionManager.activeSessions.contains(session))

        viewModel.closeAlertsPopup()
        assertFalse(viewModel.showAlertsPopup)
        assertEquals(Screen.Shell, viewModel.currentScreen)
    }

    @Test
    fun resizeBurstConflatesToFinalSigwinchWithoutOutOfOrderIntermediateSizes() = runTest {
        val transport = BlockingResizeTerminalSession()
        val shell = ShellSession(
            serverId = 99,
            serverName = "resize-host",
            session = transport,
            emulator = TerminalEmulator(80, 24),
            id = "resize",
        )
        TerminalSessionManager.addSession(shell)
        viewModel.currentSessionId = shell.id

        viewModel.resizeTerminalFor(shell, 90, 30)
        withTimeout(5_000) { transport.firstResizeStarted.await() }
        viewModel.resizeTerminalFor(shell, 100, 35)
        viewModel.resizeTerminalFor(shell, 110, 40)
        viewModel.resizeTerminalFor(shell, 120, 45)
        transport.releaseFirstResize.complete(Unit)

        withTimeout(5_000) {
            while (transport.callsSnapshot().size < 2) delay(10)
        }

        assertEquals(listOf(90 to 30, 120 to 45), transport.callsSnapshot())
        assertEquals(120, shell.emulator.cols)
        assertEquals(45, shell.emulator.rows)
        assertEquals(120, shell.lastCols)
        assertEquals(45, shell.lastRows)
    }

    private fun enterSplit(first: ShellSession, second: ShellSession) {
        viewModel.activeSshTab = 1
        viewModel.multiSshSessionId1 = first.id
        viewModel.multiSshSessionId2 = second.id
        viewModel.multiSshFocusedPane = 1
    }

    private fun addSession(
        id: String,
        connected: Boolean = true,
        reconnecting: Boolean = false,
        remoteExited: Boolean = false,
        exitStatus: Int? = null,
    ): ShellSession {
        val shell = ShellSession(
            serverId = id.hashCode(),
            serverName = id,
            session = FakeTerminalSession(remoteExited, exitStatus),
            emulator = TerminalEmulator(80, 24),
            id = id,
        )
        shell.isConnected = connected
        shell.reconnecting = reconnecting
        TerminalSessionManager.addSession(shell)
        return shell
    }

    private class FakeTerminalSession(remoteExited: Boolean, exitStatus: Int?) : TerminalSession {
        override val output: Flow<ByteArray> = emptyFlow()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow(exitStatus)
        override val remoteExited = MutableStateFlow(remoteExited)

        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() {
            closed.value = true
        }
    }

    private class BlockingResizeTerminalSession : TerminalSession {
        override val output: Flow<ByteArray> = emptyFlow()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        val firstResizeStarted = CompletableDeferred<Unit>()
        val releaseFirstResize = CompletableDeferred<Unit>()
        private val calls = mutableListOf<Pair<Int, Int>>()

        override suspend fun write(bytes: ByteArray) = Unit

        override suspend fun resize(cols: Int, rows: Int) {
            val first = synchronized(calls) {
                calls += cols to rows
                calls.size == 1
            }
            if (first) {
                firstResizeStarted.complete(Unit)
                releaseFirstResize.await()
            }
        }

        fun callsSnapshot(): List<Pair<Int, Int>> = synchronized(calls) { calls.toList() }

        override fun close() {
            closed.value = true
        }
    }
}
