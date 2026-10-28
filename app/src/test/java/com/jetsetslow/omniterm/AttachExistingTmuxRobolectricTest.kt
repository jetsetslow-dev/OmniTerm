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
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Hosts ⋮ › Attach existing tmux… lists the sessions running on a host and attaches to one by its
 * own name, as `tmux attach -t name` does. Saved sessions are kept per host, because two hosts can
 * each have a session called "main".
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AttachExistingTmuxRobolectricTest {

    @Test
    fun theDialogListsWhatIsRunningOnTheHost() = withHosts { model, _, transport, a, _ ->
        onMain { model.openAttachTmux(model.servers.value.single { it.id == a }) }
        awaitTrue { !model.tmuxAttachListing.loading }
        assertEquals(listOf("my project", "main"), model.tmuxAttachListing.sessions?.map { it.name })
        assertNull(model.tmuxAttachListing.error)

        transport.tmuxInstalled = false
        onMain { model.refreshAttachTmux() }
        awaitTrue { !model.tmuxAttachListing.loading }
        assertNull("no tmux on the host", model.tmuxAttachListing.sessions)
    }

    @Test
    fun attachingJoinsTheSessionByItsOwnNameAndLeavesItsOptionsAlone() = withHosts { model, repository, transport, a, _ ->
        onMain { model.openAttachTmux(model.servers.value.single { it.id == a }) }
        awaitTrue { !model.tmuxAttachListing.loading }
        val main = checkNotNull(model.tmuxAttachListing.sessions).single { it.name == "main" }
        onMain { model.attachHostTmuxSession(main) }
        awaitTrue { model.currentSession?.tmuxName == "main" && !model.isTerminalConnecting }

        assertNull("the dialog closes", model.tmuxAttachServer)
        val saved = repository.getPersistentSessions().single()
        assertEquals(a to "main", saved.serverId to saved.tmuxName)
        assertTrue("attached, not created by OmniTerm", saved.adopted)
        assertEquals(main.createdAtMs, saved.createdAt)
        val attach = transport.shell.writes.single { it.contains("attach-session") }
        assertTrue(attach, attach.contains("grep -qxF -- main && exec tmux attach-session -t main"))
        assertFalse("the user's other clients share its options: $attach", attach.contains("set-option"))
        assertTrue(model.isTmuxSessionOpen(a, "main"))
    }

    @Test
    fun aNameTheShellWouldChangeIsNotAttached() = withHosts { model, repository, transport, a, _ ->
        onMain { model.openAttachTmux(model.servers.value.single { it.id == a }) }
        awaitTrue { !model.tmuxAttachListing.loading }
        val spaced = checkNotNull(model.tmuxAttachListing.sessions).single { it.name == "my project" }
        onMain { model.attachHostTmuxSession(spaced) }
        delay(200)
        assertTrue(repository.getPersistentSessions().isEmpty())
        assertTrue(transport.shell.writes.isEmpty())
    }

    @Test
    fun twoHostsCanEachKeepASessionCalledMain() = withHosts(
        before = { repository, a, b ->
            repository.upsertPersistentSession(PersistentSessionEntity("main", a, "a", adopted = true))
            repository.upsertPersistentSession(PersistentSessionEntity("main", b, "b", adopted = true))
        },
    ) { model, repository, _, a, b ->
        awaitTrue { model.resumableSavedSessions.size == 2 }
        onMain { model.forgetSavedSession(a, "main") }
        awaitTrue { repository.getPersistentSessions().size == 1 }
        assertEquals(b, repository.getPersistentSessions().single().serverId)
        assertEquals(listOf(b), model.restorablePersistentSessions.map { it.serverId })
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private suspend fun onMain(block: () -> Unit) = withContext(main) { block() }

    private suspend fun awaitTrue(condition: suspend () -> Boolean) = withTimeout(5_000) {
        while (!condition()) delay(10)
    }

    private fun withHosts(
        before: suspend (AppRepository, Int, Int) -> Unit = { _, _, _ -> },
        block: suspend (AppViewModel, AppRepository, HostTransport, Int, Int) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel does its database work on Dispatchers.IO.
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = HostTransport()
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            val a = repository.insertServer(ServerEntity(name = "a", host = "a.invalid", username = "fixture")).toInt()
            val b = repository.insertServer(ServerEntity(name = "b", host = "b.invalid", username = "fixture")).toInt()
            before(repository, a, b)
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            awaitTrue { model.servers.value.count { it.id == a || it.id == b } == 2 }
            onMain { model.saveTmuxControlMode(false) }
            block(model, repository, transport, a, b)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** A Linux host running tmux sessions "main" and "my project". */
    private class HostTransport : SshTransport {
        @Volatile var tmuxInstalled = true
        val shell = RecordingShell()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = when (command) {
            RemoteCommands.OS_PROBE -> "Linux"
            RemoteCommands.TMUX_LIST_SESSIONS ->
                if (tmuxInstalled) "1700000100 0 2 main\n1700000000 1 1 my project\n" else RemoteCommands.TMUX_MISSING_MARKER
            RemoteCommands.tmuxHasSessionCommand("main") -> "yes"
            else -> ""
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = shell
    }

    private class RecordingShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        val writes = CopyOnWriteArrayList<String>()
        override suspend fun write(bytes: ByteArray) {
            writes.add(bytes.decodeToString())
        }
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
