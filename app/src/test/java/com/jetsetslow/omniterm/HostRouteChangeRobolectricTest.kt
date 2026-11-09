package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * Picking a VPN tunnel for a host that has a terminal open does not leave that terminal on the
 * direct connection: it is closed and reconnects through the tunnel, and the user is told.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class HostRouteChangeRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aTerminalOpenWhenTheTunnelIsPickedReconnectsThroughIt() = runBlocking<Unit> {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = RecordingTransport()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        try {
            TerminalSessionManager.clearAll()
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repo = AppRepository(db)
            val tunnel = repo.insertTunnel(TunnelEntity(name = "Home", config = "[Interface]\n"))
            val id = repo.insertServer(ServerEntity(name = "nas", host = "nas.invalid", username = "fixture")).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) {
                model.selectedServerId = id
                model.connectTerminal()
            }
            val (directCreds, direct) = transport.shells.receive()
            withTimeout(10_000) { direct.reading.await() }
            assertNull("opened directly", directCreds.tunnelId)

            val row = repo.getServerById(id)!!
            val saved = CompletableDeferred<String?>()
            withContext(main) { model.updateServer(row.copy(tunnelId = tunnel, tunnelHost = "10.9.0.7")) { saved.complete(it) } }
            assertNull(withTimeout(10_000) { saved.await() })

            val (tunnelCreds, _) = withTimeout(20_000) { transport.shells.receive() }
            assertTrue("the direct terminal is closed", direct.closed.value)
            assertEquals(tunnel, tunnelCreds.tunnelId)
            assertEquals("10.9.0.7", tunnelCreds.tunnelHost)
            val notice = withContext(main) { model.consumeHostEditNotice() }
            assertTrue("$notice", notice?.contains("1 terminal(s) reconnect through the new route") == true)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** Opens a shell for every request and says which credentials, and so which route, it was for. */
    private class RecordingTransport : SshTransport {
        val shells = Channel<Pair<SshCredentials, OpenShell>>(Channel.UNLIMITED)

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

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
        ): TerminalSession = openShell(creds, cols, rows, null, onPhaseChange)

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            interactiveAuth: InteractiveAuth?,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = OpenShell().also { shells.send(creds to it) }
    }

    private class OpenShell : TerminalSession {
        private val bytes = Channel<ByteArray>()
        val reading = CompletableDeferred<Unit>()
        override val output: Flow<ByteArray> = flow {
            reading.complete(Unit)
            for (chunk in bytes) emit(chunk)
        }
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() {
            closed.value = true
            bytes.close()
        }
    }
}
