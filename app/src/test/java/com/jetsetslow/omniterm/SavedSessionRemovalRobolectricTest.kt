package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import org.junit.Assert.assertFalse
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.CompletableDeferred
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * A saved tmux session can be removed even when its server is gone, and deleting a host only
 * touches the server when the user asks it to.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SavedSessionRemovalRobolectricTest {

    @Test
    fun forgetDropsTheEntryWithoutTouchingTheServer() = withSavedSession { model, repository, transport, id ->
        onMain { model.requestRemoveSavedSession(id, NAME) }
        assertEquals(NAME, model.savedSessionPendingRemoval?.tmuxName)
        onMain { model.forgetSavedSession(id, NAME) }
        awaitTrue { repository.getPersistentSessions().isEmpty() && model.restorablePersistentSessions.isEmpty() }
        assertNull(model.savedSessionPendingRemoval)
        assertTrue("Forget must not end anything on the server", transport.kills.isEmpty())
    }

    @Test
    fun anUnreachableServerKeepsTheEntryAndStillOffersForget() = withSavedSession { model, repository, transport, id ->
        transport.reachable = false
        onMain {
            model.requestRemoveSavedSession(id, NAME)
            model.endSavedSession(id, NAME)
        }
        awaitTrue { !model.isEndingSavedSession && model.savedSessionRemovalError != null }
        assertTrue(checkNotNull(model.savedSessionRemovalError).startsWith("Couldn't reach Saved fixture"))
        assertNotNull("The dialog stays open with Forget", model.savedSessionPendingRemoval)
        assertTrue(repository.getPersistentSessions().any { it.tmuxName == NAME })

        onMain { model.forgetSavedSession(id, NAME) }
        awaitTrue { repository.getPersistentSessions().isEmpty() }
    }

    @Test
    fun endingDropsTheEntryOnceTmuxConfirmsItIsGone() = withSavedSession { model, repository, transport, id ->
        onMain {
            model.requestRemoveSavedSession(id, NAME)
            model.endSavedSession(id, NAME)
        }
        awaitTrue { repository.getPersistentSessions().isEmpty() && model.savedSessionPendingRemoval == null }
        assertEquals(listOf(NAME), transport.kills)
        assertNull(model.savedSessionRemovalError)
    }

    @Test
    fun deletingAHostLeavesItsTmuxRunningUnlessAsked() = withSavedSession { model, repository, transport, id ->
        val server = checkNotNull(repository.getServerById(id))
        onMain { model.deleteServer(server) }
        awaitTrue { repository.getServerById(id) == null }
        assertTrue("The dialog promises the remote machine is untouched", transport.kills.isEmpty())
        assertTrue(repository.getPersistentSessions().isEmpty())
    }

    @Test
    fun deletingAHostWithTheBoxTickedEndsItsSavedSessions() = withSavedSession { model, repository, transport, id ->
        val server = checkNotNull(repository.getServerById(id))
        assertEquals(1, model.tmuxSessionsOnHosts(setOf(id)).size)
        onMain { model.deleteServer(server, endTmuxSessions = true) }
        awaitTrue { repository.getServerById(id) == null }
        assertEquals(listOf(NAME), transport.kills)
    }

    @Test
    fun deletingSelectedHostsEndsTheirSessionsWhenAsked() = withSavedSession(
        before = { repository ->
            val second = repository.insertServer(ServerEntity(
                name = "Second fixture", host = "second.invalid", username = "fixture", persistentSession = true,
            )).toInt()
            repository.upsertPersistentSession(PersistentSessionEntity(SECOND, second, "Second fixture"))
        },
    ) { model, repository, transport, id ->
        val second = repository.getAllServers().single { it.name == "Second fixture" }.id
        awaitTrue { model.tmuxSessionsOnHosts(setOf(id, second)).size == 2 }
        onMain {
            model.isMultiSelectMode = true
            model.selectedServerIdsForBulk.addAll(listOf(id, second))
            model.deleteSelectedServers(endTmuxSessions = true)
        }
        awaitTrue { repository.getServerById(id) == null && repository.getServerById(second) == null }
        awaitTrue { transport.kills.size == 2 }
        assertEquals(setOf(NAME, SECOND), transport.kills.toSet())
        assertTrue(repository.getPersistentSessions().isEmpty())
        assertFalse(model.isMultiSelectMode)
        assertTrue(model.selectedServerIdsForBulk.isEmpty())
    }

    @Test
    fun renamingAHostRenamesItsSessionsInTheLists() = withSavedSession { model, repository, _, id ->
        val shell = ShellSession(id, "Saved fixture", IdleShell(), TerminalEmulator(80, 24))
        onMain { TerminalSessionManager.addSession(shell) }
        val server = checkNotNull(repository.getServerById(id))
        val saved = CompletableDeferred<String?>()
        onMain { model.updateServer(server.copy(name = "Renamed fixture")) { saved.complete(it) } }
        assertNull(withTimeout(5_000) { saved.await() })
        assertEquals("Renamed fixture", shell.serverName)
        assertEquals("Renamed fixture", repository.getPersistentSessions().single().serverName)
        assertEquals("Renamed fixture", model.restorablePersistentSessions.single().serverName)
        // The tmux session on the server keeps its name; other devices reattach by it.
        assertEquals(NAME, model.restorablePersistentSessions.single().tmuxName)
    }

    @Test
    fun aReconnectAfterAnEditUsesTheHostsCurrentAddress() = withSavedSession { model, repository, transport, id ->
        val shell = ShellSession(id, "Saved fixture", IdleShell(), TerminalEmulator(80, 24)).apply {
            creds = SshCredentials("saved.invalid", 22, "fixture")
            isConnected = false
        }
        onMain { TerminalSessionManager.addSession(shell) }
        val server = checkNotNull(repository.getServerById(id))
        val saved = CompletableDeferred<String?>()
        onMain { model.updateServer(server.copy(host = "moved.invalid")) { saved.complete(it) } }
        assertNull(withTimeout(5_000) { saved.await() })
        // The live channel's side requests stay with the machine it is connected to.
        assertEquals("saved.invalid", shell.creds?.host)
        try {
            onMain { model.retrySession(shell.id) }
            awaitTrue { transport.shellHosts.isNotEmpty() }
            assertEquals("moved.invalid", transport.shellHosts.first())
        } finally {
            shell.userClosed = true
            shell.reconnectJob?.cancel()
        }
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private suspend fun onMain(block: () -> Unit) = withContext(main) { block() }

    private suspend fun awaitTrue(condition: suspend () -> Boolean) = withTimeout(5_000) {
        while (!condition()) delay(10)
    }

    private fun withSavedSession(
        before: suspend (AppRepository) -> Unit = {},
        block: suspend (AppViewModel, AppRepository, RecordingTransport, Int) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = RecordingTransport()
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            // The database outlives a test, and an earlier test's host would make a rename look
            // like a duplicate of it.
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            val id = repository.insertServer(ServerEntity(
                name = "Saved fixture", host = "saved.invalid", username = "fixture", persistentSession = true,
            )).toInt()
            repository.upsertPersistentSession(PersistentSessionEntity(NAME, id, "Saved fixture"))
            before(repository)
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            awaitTrue { model.servers.value.any { it.id == id } && model.restorablePersistentSessions.isNotEmpty() }
            block(model, repository, transport, id)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** Answers like a server running tmux sessions, or like one that cannot be reached. */
    private class RecordingTransport : SshTransport {
        val kills = CopyOnWriteArrayList<String>()
        /** Hosts a shell was asked for, in order. No shell ever opens. */
        val shellHosts = CopyOnWriteArrayList<String>()
        @Volatile var reachable = true

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            if (!reachable) return "SSH Error: connect timed out"
            if (command.contains("kill-session")) {
                kills.add(command.substringAfter("-t ").substringBefore(' '))
                return ""
            }
            listOf(NAME, SECOND).firstOrNull { command == RemoteCommands.tmuxHasSessionCommand(it) }?.let { name ->
                return if (name in kills) "no" else "yes"
            }
            return ""
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? =
            if (reachable) null else "connect timed out"

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession {
            shellHosts.add(creds.host)
            error("No shell is opened in these tests")
        }
    }

    private class IdleShell : TerminalSession {
        override val output = emptyFlow<ByteArray>()
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }

    private companion object {
        const val NAME = "omniterm-saved-fixture"
        const val SECOND = "omniterm-second-fixture"
    }
}
