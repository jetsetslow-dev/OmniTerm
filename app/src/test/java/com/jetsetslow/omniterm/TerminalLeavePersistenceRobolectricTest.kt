package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TerminalLeavePersistenceRobolectricTest {
    @Test
    fun navigationAndLiveChannelWaitForDurableRecovery() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val release = CompletableDeferred<Unit>()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repository = AppRepository(AppDatabase.getDatabase(application))
        try {
            TerminalSessionManager.clearAll()
            val model = withContext(main) { AppViewModel(application) }
            store.put("test", model)
            val shell = ShellSession(1, "Fixture", FakeShell(), TerminalEmulator(80, 24)).apply {
                persistent = true
                tmuxName = "leave-fixture"
            }
            val entered = CompletableDeferred<Unit>()
            val transaction = launch(Dispatchers.IO) {
                repository.inTransaction { entered.complete(Unit); release.await() }
            }
            try {
                withTimeout(5_000) { entered.await() }
                withContext(main) {
                    TerminalSessionManager.addSession(shell)
                    model.currentSessionId = shell.id
                    model.navigateTo(Screen.Shell)
                    model.navigateTo(Screen.Monitor)
                    model.completeTerminalNavigation(disconnect = false)
                    assertEquals("Navigation must wait for recovery storage", Screen.Shell, model.currentScreen)
                    assertTrue(model.showDisconnectTerminalDialog)
                    assertTrue(model.isLeavingTerminalSessions)
                    assertFalse("A pending save must not suppress SSH recovery", shell.userClosed)
                    assertFalse(shell.session.closed.value)
                }
            } finally {
                release.complete(Unit)
                transaction.join()
            }
            withTimeout(5_000) {
                while (model.currentScreen != Screen.Monitor || model.activeSessions.contains(shell)) {
                    check(model.terminalLeaveError == null) { model.terminalLeaveError.orEmpty() }
                    delay(10)
                }
            }
            assertTrue(model.restorablePersistentSessions.any { it.tmuxName == shell.tmuxName })
        } finally {
            release.complete(Unit)
            withContext(main) { store.clear(); TerminalSessionManager.clearAll() }
            Dispatchers.resetMain()
            main.close()
        }
    }

    @Test
    fun failingSecondRecoveryWriteKeepsBothPanesAndCanBeRetried() = withModel { model, repository, db, main ->
        val first = persistentShell("leave-one")
        val second = persistentShell("leave-two")
        val reconnect = Job()
        second.reconnectJob = reconnect
        repository.upsertPersistentSession(PersistentSessionEntity(first.tmuxName, 1, "Fixture", 1234, 5678))
        withContext(Dispatchers.IO) {
            db.openHelper.writableDatabase.execSQL(
                "CREATE TRIGGER reject_leave BEFORE INSERT ON persistent_sessions " +
                    "WHEN NEW.tmuxName = 'leave-two' BEGIN SELECT RAISE(ABORT, 'fixture storage unavailable'); END",
            )
        }
        try {
            withContext(main) {
                TerminalSessionManager.addSession(first)
                TerminalSessionManager.addSession(second)
                model.activeSshTab = 1
                model.multiSshSessionId1 = first.id
                model.multiSshSessionId2 = second.id
                model.navigateTo(Screen.Shell)
                model.navigateTo(Screen.Monitor)
                model.completeTerminalNavigation(disconnect = false)
            }
            withTimeout(5_000) { while (model.isLeavingTerminalSessions) delay(10) }
            assertEquals(Screen.Shell, model.currentScreen)
            assertTrue(model.showDisconnectTerminalDialog)
            assertTrue(model.terminalLeaveError.orEmpty().contains("fixture storage unavailable"))
            assertFalse(first.userClosed)
            assertFalse(second.userClosed)
            assertTrue(reconnect.isActive)
            assertTrue(model.activeSessions.containsAll(listOf(first, second)))
            assertEquals(first.id, model.multiSshSessionId1)
            assertEquals(second.id, model.multiSshSessionId2)
            assertFalse(first.session.closed.value)
            assertFalse(second.session.closed.value)
            val rows = repository.getPersistentSessions()
            assertEquals(5678L, rows.single { it.tmuxName == first.tmuxName }.backgroundedAt)
            assertFalse(rows.any { it.tmuxName == second.tmuxName })
        } finally {
            withContext(Dispatchers.IO) { db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_leave") }
        }
        withContext(main) { model.completeTerminalNavigation(disconnect = false) }
        withTimeout(5_000) { while (model.isLeavingTerminalSessions || model.currentScreen != Screen.Monitor) delay(10) }
        assertTrue(model.activeSessions.isEmpty())
        assertNull(model.terminalLeaveError)
        assertEquals(1234L, repository.getPersistentSessions().single { it.tmuxName == first.tmuxName }.createdAt)
        assertTrue(repository.getPersistentSessions().any { it.tmuxName == second.tmuxName })
        assertTrue(reconnect.isCancelled)
    }

    @Test
    fun notificationResumeCancelsPendingToolbarLeave() = withModel { model, repository, _, main ->
        coroutineScope {
            val shell = persistentShell("leave-cancel")
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val transaction = launch(Dispatchers.IO) {
                repository.inTransaction { entered.complete(Unit); release.await() }
            }
            try {
                withTimeout(5_000) { entered.await() }
                val leave = withContext(main) {
                    TerminalSessionManager.addSession(shell)
                    model.currentSessionId = shell.id
                    model.navigateTo(Screen.Shell)
                    checkNotNull(model.leaveSessionResumable(shell.id))
                }
                withContext(main) {
                    assertTrue(model.isLeavingTerminalSessions)
                    model.attachSession(shell.id)
                }
                release.complete(Unit)
                transaction.join()
                withTimeout(5_000) { leave.join() }
                assertTrue(leave.isCancelled)
                assertFalse(model.isLeavingTerminalSessions)
                assertNull(model.terminalLeaveError)
                assertEquals(Screen.Shell, model.currentScreen)
                assertEquals(shell.id, model.currentSessionId)
                assertTrue(model.activeSessions.contains(shell))
                assertFalse(shell.userClosed)
                assertFalse(shell.session.closed.value)
            } finally {
                release.complete(Unit)
                transaction.join()
            }
        }
    }

    private fun persistentShell(name: String) =
        ShellSession(1, "Fixture", FakeShell(), TerminalEmulator(80, 24)).apply {
            persistent = true
            tmuxName = name
        }

    private fun withModel(block: suspend (AppViewModel, AppRepository, AppDatabase, CoroutineDispatcher) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            val model = withContext(main) { AppViewModel(application) }
            store.put("test", model)
            block(model, AppRepository(db), db, main)
        } finally {
            withContext(main) { store.clear(); TerminalSessionManager.clearAll() }
            Dispatchers.resetMain()
            main.close()
        }
    }

    private class FakeShell : TerminalSession {
        override val output = emptyFlow<ByteArray>()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
