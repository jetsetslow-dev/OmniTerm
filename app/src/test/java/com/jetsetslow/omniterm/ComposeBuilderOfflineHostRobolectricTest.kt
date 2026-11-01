package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
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
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ComposeBuilder
import com.jetsetslow.omniterm.ui.FullScreenEditorHost
import com.jetsetslow.omniterm.ui.LocalFullScreenEditorHost
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
 * The Compose Builder kept Deploy enabled, with no word about the host, after its host went
 * offline: it looked the host up once, so a status change never reached it. It follows the host
 * both ways, and the draft stays put.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class ComposeBuilderOfflineHostRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    private val offlineNote = "Builder fixture is offline. Your changes stay here until it is back, even if you switch hosts."

    @Test
    fun deployFollowsTheHostGoingOfflineAndComingBack() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = SwitchableHost()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val model = runBlocking {
                val id = repo.insertServer(
                    ServerEntity(name = "Builder fixture", host = "fixture.invalid", username = "fixture", status = "online"),
                ).toInt()
                serverId = id
                val model = withContext(main) { AppViewModel(application, transport) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
                withContext(main) { model.selectedServerId = id }
                model
            }
            val id = checkNotNull(serverId)
            val deploy = hasText("Deploy Stack") and hasClickAction()

            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(
                        LocalFullScreenEditorHost provides remember { FullScreenEditorHost() },
                        LocalLifecycleOwner provides AnyThreadLifecycle,
                    ) {
                        ComposeBuilder(model)
                    }
                }
            }
            composeTestRule.waitUntil(10_000) { composeTestRule.onAllNodes(deploy).fetchSemanticsNodes().isNotEmpty() }
            composeTestRule.onNode(deploy).assertIsEnabled()
            composeTestRule.onNodeWithText(offlineNote).assertDoesNotExist()

            transport.reachable = false
            runBlocking { repo.updateReachability(id, "offline", 0) }
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText(offlineNote).fetchSemanticsNodes().isNotEmpty()
            }
            composeTestRule.onNode(deploy).assertIsNotEnabled()

            transport.reachable = true
            runBlocking { repo.updateReachability(id, "online", 5) }
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText(offlineNote).fetchSemanticsNodes().isEmpty()
            }
            composeTestRule.onNode(deploy).assertIsEnabled()
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    repository?.let { repo -> serverId?.let { repo.getServerById(it)?.let { row -> repo.deleteServer(row) } } }
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

    /**
     * A resumed lifecycle that may be observed from any thread: the view model's main dispatcher
     * here is a test thread, and the Builder collects host status for the lifecycle on it.
     */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** A host the test takes down and brings back; every command answers nothing. */
    private class SwitchableHost : SshTransport {
        @Volatile var reachable = true

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? = if (reachable) null else "unreachable"

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
