package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
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
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors

/**
 * A Broadcast target that went offline, even for a moment, was dropped from the picks and not
 * picked again when it came back, so the next run reached fewer hosts than the user chose. It
 * stays picked, marked offline, and runs again once it is back.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class BroadcastTargetsOfflineRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun aPickedHostThatDropsStaysPickedAndCountsAgainOnceBack() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val repo = AppRepository(AppDatabase.getDatabase(ApplicationProvider.getApplicationContext<Application>()))
        val ids = mutableListOf<Int>()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val model = runBlocking {
                listOf("Pick one", "Pick two").forEach { name ->
                    ids += repo.insertServer(
                        ServerEntity(name = name, host = "fixture.invalid", username = "fixture", status = "online"),
                    ).toInt()
                }
                val model = withContext(main) { AppViewModel(application, QuietHosts()) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.count { it.id in ids } < 2 }
                withContext(main) {
                    model.fleetTabIndex = 1
                    model.broadcastCommandText = "uptime"
                    model.broadcastTargetServerIds.addAll(ids)
                }
                model
            }
            val (one, two) = ids

            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides AnyThreadLifecycle) { FleetScreen(model) }
                }
            }
            awaitText("2 target(s) · uptime")

            runBlocking { repo.updateReachability(two, "offline", 0) }
            awaitText("1 target(s) · uptime")
            awaitText("2 selected: Pick one, Pick two (offline)")
            runBlocking { withContext(main) { assertEquals(listOf(one, two), model.broadcastTargetServerIds.toList()) } }
            // The button sits below the test's small window, where a tap would miss it.
            composeTestRule.onNodeWithText("RUN ON 1 HOSTS").performSemanticsAction(SemanticsActions.OnClick)
            awaitText("Skipped while offline: Pick two", substring = true)
            composeTestRule.onNodeWithText("Cancel").performClick()

            runBlocking { repo.updateReachability(two, "online", 5) }
            awaitText("2 target(s) · uptime")
            awaitText("2 selected: Pick one, Pick two")
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    ids.forEach { id -> repo.getServerById(id)?.let { repo.deleteServer(it) } }
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    private fun awaitText(text: String, substring: Boolean = false) {
        composeTestRule.waitUntil(10_000) {
            composeTestRule.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)

    /** A resumed lifecycle that may be observed from the test's own main thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** Hosts that answer nothing; the test sets their status itself. */
    private class QuietHosts : SshTransport {
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
