package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ShellScreen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors

/**
 * The terminal's session list says how old each session is, as the Open menu does: when it started
 * and, once left running in the background, since when.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class SessionListAgesRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun aSavedSessionShowsWhenItStartedAndSinceWhenItWasBackgrounded() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repo = AppRepository(AppDatabase.getDatabase(application))
        var id = 0
        try {
            TerminalSessionManager.clearAll()
            val model = runBlocking {
                id = repo.insertServer(
                    ServerEntity(name = "Ages fixture", host = "fixture.invalid", username = "fixture", persistentSession = true),
                ).toInt()
                // Seconds past the minute, so the ages still read 5m and 2m however slow the run.
                val now = System.currentTimeMillis()
                repo.upsertPersistentSession(
                    PersistentSessionEntity(
                        tmuxName = "omniterm-ages-fixture",
                        serverId = id,
                        serverName = "Ages fixture",
                        createdAt = now - 5 * 60_000L - 5_000L,
                        backgroundedAt = now - 2 * 60_000L - 5_000L,
                    ),
                )
                val model = withContext(main) { AppViewModel(application, NoShellHost()) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) {
                    model.servers.value.none { it.id == id } || model.resumableSavedSessions.none { it.serverId == id }
                }
                withContext(main) { model.selectedServerId = id }
                model
            }

            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides AnyThreadLifecycle) { ShellScreen(model) }
                }
            }
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText("Ages fixture").fetchSemanticsNodes().isNotEmpty()
            }
            composeTestRule.onNodeWithText("Started 5m ago · backgrounded 2m ago").assertExists()
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    repo.deletePersistentSession(id, "omniterm-ages-fixture")
                    repo.getServerById(id)?.let { repo.deleteServer(it) }
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)

    /** A resumed lifecycle that may be observed from the test's own main thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** A host that answers nothing; the list is all this test looks at. */
    private class NoShellHost : SshTransport {
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
        ): TerminalSession = IdleShell()
    }

    private class IdleShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
