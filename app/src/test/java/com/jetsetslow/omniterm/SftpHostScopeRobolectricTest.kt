package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.FullScreenEditorHost
import com.jetsetslow.omniterm.ui.LocalFullScreenEditorHost
import com.jetsetslow.omniterm.ui.SftpScreen
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
 * With an offline host still selected, the SFTP tab's host bar, which lists online hosts only,
 * showed the first online host while the browser listed (and reloaded) the offline one, under that
 * host's raw Java exception. The tab now moves to the host its bar shows, and says why a listing
 * failed in words.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class SftpHostScopeRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun theBrowserListsTheHostItsBarShows() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        var repository: AppRepository? = null
        val ids = mutableListOf<Int>()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val (model, offline, online) = runBlocking {
                val offline = repo.insertServer(
                    ServerEntity(name = "Down box", host = DOWN_HOST, username = "fixture", status = "offline"),
                ).toInt().also(ids::add)
                // Nothing listens on port 1, so the browser's own SFTP sign-in is refused at once.
                val online = repo.insertServer(
                    ServerEntity(name = "Up box", host = "127.0.0.1", port = 1, username = "fixture", status = "online"),
                ).toInt().also(ids::add)
                val model = withContext(main) { AppViewModel(application, ReachableHosts()) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.count { it.id in ids } < 2 }
                // The model marks every host offline as it starts, and its first probe brings
                // "Up box" back through "connecting", when no host is online. Shown in between,
                // the screen would leave the SFTP tab for Bookmarks, so start once that is over.
                waitWhileOnMain(main, 10_000) {
                    model.probedServerIds[online] != true ||
                        model.servers.value.none { it.id == online && it.status == "online" }
                }
                withContext(main) {
                    model.selectedServerId = offline
                    model.activeSftpTab = 1
                }
                Triple(model, offline, online)
            }

            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(
                        LocalFullScreenEditorHost provides remember { FullScreenEditorHost() },
                        LocalLifecycleOwner provides AnyThreadLifecycle,
                    ) {
                        SftpScreen(model)
                    }
                }
            }
            composeTestRule.waitUntil(10_000) { model.selectedServerId == online }
            composeTestRule.waitUntil(10_000) { model.sftpError != null }
            composeTestRule.waitForIdle()

            assertThat(composeTestRule.onAllNodesWithText("Up box").fetchSemanticsNodes()).isNotEmpty()
            assertThat(composeTestRule.onAllNodesWithText("Down box").fetchSemanticsNodes()).isEmpty()
            assertThat(model.sftpError).startsWith("Connection refused — ")
            assertThat(composeTestRule.onAllNodesWithText("java.", substring = true).fetchSemanticsNodes()).isEmpty()
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    repository?.let { repo -> ids.forEach { id -> repo.getServerById(id)?.let { repo.deleteServer(it) } } }
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

    /** A resumed lifecycle that may be observed from any thread, as the view model's main is a test thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** Every host but [DOWN_HOST] answers the app's checks; commands answer nothing. SFTP does not go through here. */
    private class ReachableHosts : SshTransport {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
            if (creds.host == DOWN_HOST) "SSH Error: connect timed out" else ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? = if (creds.host == DOWN_HOST) "unreachable" else null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = IdleShell()
    }

    private companion object {
        const val DOWN_HOST = "down.invalid"
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
