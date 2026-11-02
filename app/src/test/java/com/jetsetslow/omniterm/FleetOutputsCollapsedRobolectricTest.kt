package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
import com.jetsetslow.omniterm.ui.FleetScreen
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
 * Broadcast output cards start collapsed: when a run's output starts, and again after the user
 * opened one and came back to Broadcast from another tab. A run on many hosts then shows every
 * host's status at once, and a card opens only when its output is wanted.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class FleetOutputsCollapsedRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun outputCardsStartCollapsedAndCollapseAgainAfterLeavingBroadcast() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val repo = AppRepository(AppDatabase.getDatabase(ApplicationProvider.getApplicationContext<Application>()))
        var id = 0
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val model = runBlocking {
                id = repo.insertServer(
                    ServerEntity(name = "Collapsed fixture", host = "fixture.invalid", username = "fixture", status = "online"),
                ).toInt()
                val model = withContext(main) { AppViewModel(application, AnsweringHost()) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
                withContext(main) {
                    model.fleetTabIndex = 1
                    model.updateBroadcastInTmux(false)
                }
                model
            }

            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides AnyThreadLifecycle) { FleetScreen(model) }
                }
            }
            runBlocking { withContext(main) { model.runFleetBroadcast("uptime", listOf(id)) } }
            awaitText("complete")
            assertNoText(HOST_OUTPUT)

            composeTestRule.onNodeWithText("Collapsed fixture").performClick()
            awaitText(HOST_OUTPUT)

            runBlocking { withContext(main) { model.fleetTabIndex = 0 } }
            composeTestRule.waitForIdle()
            runBlocking { withContext(main) { model.fleetTabIndex = 1 } }
            awaitText("complete")
            assertNoText(HOST_OUTPUT)
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    repo.getServerById(id)?.let { repo.deleteServer(it) }
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    private fun awaitText(text: String) {
        composeTestRule.waitUntil(10_000) {
            composeTestRule.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun assertNoText(text: String) {
        composeTestRule.waitForIdle()
        check(composeTestRule.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isEmpty()) {
            "\"$text\" is showing, so its card is expanded"
        }
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)

    /** A resumed lifecycle that may be observed from the test's own main thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** A host whose broadcast command prints [HOST_OUTPUT]; everything else gets nothing. */
    private class AnsweringHost : SshTransport {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            if (command != "uptime") return ""
            onChunk("$HOST_OUTPUT\n")
            return "$HOST_OUTPUT\n"
        }

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

    private companion object {
        const val HOST_OUTPUT = "up 3 days, load 0.42"
    }
}
