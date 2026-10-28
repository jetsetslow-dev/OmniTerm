package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * A manual refresh shows hosts as being checked, but a host that was online stays pickable on the
 * tabs that only offer online hosts. Dropping it moved Monitor and Terminal to another host and
 * cleared Fleet's targets on every pull.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class HostRecheckRobolectricTest {

    @Test
    fun anOnlineHostStaysPickableWhileARefreshRechecksIt() = runBlocking {
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = GatedTransport()
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            val watched = repository.insertServer(ServerEntity(name = "Watched", host = "watched.invalid", username = "fixture")).toInt()
            val down = repository.insertServer(ServerEntity(name = "Down", host = "down.invalid", username = "fixture")).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            // The startup probes hold each host's probe lock until the gate opens, so the
            // refreshes below stay in their checking phase for as long as the test needs.
            awaitTrue { transport.waiting >= 2 }
            repository.updateReachability(watched, "online", 5)
            repository.updateReachability(down, "offline", 0)

            withContext(main) {
                model.refreshServer(watched)
                model.refreshServer(down)
            }
            awaitTrue { listOf(watched, down).all { repository.getServerById(it)?.status == "connecting" } }
            assertTrue("A host that was online stays pickable", model.isPickableHost(checkNotNull(repository.getServerById(watched))))
            assertFalse("An offline host being retried is not", model.isPickableHost(checkNotNull(repository.getServerById(down))))

            transport.gate.complete(Unit)
            awaitTrue { repository.getServerById(watched)?.status == "offline" }
            // Once its answer is in, a later check is not mistaken for a re-check of an online host.
            awaitTrue { !model.isPickableHost(checkNotNull(repository.getServerById(watched)).copy(status = "connecting")) }
        } finally {
            transport.gate.complete(Unit)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private suspend fun awaitTrue(condition: suspend () -> Boolean) = withTimeout(10_000) {
        while (!condition()) delay(10)
    }

    /** Every command waits for [gate], then fails as an unreachable server does. */
    private class GatedTransport : SshTransport {
        val gate = CompletableDeferred<Unit>()
        @Volatile var waiting = 0

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            synchronized(this) { waiting++ }
            gate.await()
            return "SSH Error: connect timed out"
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = exec(creds, command, stdin)

        override suspend fun testConnection(creds: SshCredentials): String? = "connect timed out"

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = error("No shell is opened in these tests")
    }
}
