package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.AuthPrompt
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.InteractiveAuthRequest
import com.jetsetslow.omniterm.data.ssh.NEEDS_INTERACTIVE_AUTH
import com.jetsetslow.omniterm.data.ssh.SshConnectException
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TERMINAL_NEEDS_INTERACTIVE_AUTH
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.Executors

/**
 * A dropped terminal to a host that asks a one-time code stops reconnecting at the first attempt
 * that needs the code, instead of failing a dozen sign-ins in the host's log (enough to trip
 * fail2ban). Retry then asks the user and reconnects with the answer.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TwoStepSignInReconnectRobolectricTest {

    @Test
    fun aDropStopsAtTheFirstAttemptThatNeedsACodeAndRetryAsksForIt() = runBlocking<Unit> {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = CodeAskingTransport()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val id = repo.insertServer(
                ServerEntity(name = "Code fixture", host = "fixture.invalid", username = "fixture")
            ).toInt()
            serverId = id
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) {
                model.selectedServerId = id
                model.connectTerminal()
            }
            val first = transport.shells.receive()
            withTimeout(10_000) { first.reading.await() }
            val session = checkNotNull(withContext(main) { model.currentSession })

            first.drop()
            waitWhileOnMain(main, 15_000) { session.reconnecting || session.disconnectError == null }
            assertEquals(TERMINAL_NEEDS_INTERACTIVE_AUTH, withContext(main) { session.disconnectError })
            assertEquals("one attempt without the user, then it stops", 1, transport.attemptsWithoutUser)
            // The next attempt would have come two seconds later.
            delay(3_000)
            assertEquals(1, transport.attemptsWithoutUser)

            withContext(main) { model.retrySession(session.id) }
            waitWhileOnMain(main, 10_000) { model.pendingInteractiveAuth == null }
            val asked = checkNotNull(withContext(main) { model.pendingInteractiveAuth })
            assertEquals("Code fixture", asked.hostName)
            assertEquals(listOf(AuthPrompt("Verification code: ", false)), asked.request.prompts)
            withContext(main) { model.answerInteractiveAuth(listOf("123456")) }

            val second = transport.shells.receive()
            withTimeout(10_000) { second.reading.await() }
            waitWhileOnMain(main, 10_000) { !session.isConnected }
            assertEquals(listOf("123456"), transport.answers)
            assertFalse(withContext(main) { session.reconnecting })
            assertTrue(withContext(main) { model.pendingInteractiveAuth == null })
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                repository?.let { repo -> serverId?.let { repo.getServerById(it)?.let { row -> repo.deleteServer(row) } } }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /**
     * The first shell opens as if its sign-in were already answered. Any later one wants a code:
     * without someone to ask it fails as JschSshTransport does, with [NEEDS_INTERACTIVE_AUTH].
     */
    private class CodeAskingTransport : SshTransport {
        val shells = Channel<DroppableShell>(Channel.UNLIMITED)
        @Volatile var attemptsWithoutUser = 0
            private set
        @Volatile var answers: List<String>? = null
            private set
        @Volatile private var opened = 0

        // Background commands have no one to ask, so they fail at once, as the real pool does.
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
            "SSH Error: $NEEDS_INTERACTIVE_AUTH"

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = "SSH Error: $NEEDS_INTERACTIVE_AUTH"

        override suspend fun testConnection(creds: SshCredentials): String? = NEEDS_INTERACTIVE_AUTH

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
        ): TerminalSession {
            if (opened++ > 0) {
                if (interactiveAuth == null) {
                    attemptsWithoutUser++
                    throw SshConnectException(NEEDS_INTERACTIVE_AUTH)
                }
                val request = InteractiveAuthRequest(
                    "${creds.username}@${creds.host}", "", "", listOf(AuthPrompt("Verification code: ", false)),
                )
                answers = interactiveAuth.answer(request) ?: throw SshConnectException("Sign-in cancelled.")
            }
            return DroppableShell().also { shells.send(it) }
        }
    }

    private class DroppableShell : TerminalSession {
        private val bytes = Channel<ByteArray>()
        val reading = CompletableDeferred<Unit>()
        override val output: Flow<ByteArray> = flow {
            reading.complete(Unit)
            for (chunk in bytes) emit(chunk)
        }
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)

        fun drop() {
            bytes.close(IOException("Connection reset"))
        }

        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() {
            closed.value = true
            bytes.close()
        }
    }
}
