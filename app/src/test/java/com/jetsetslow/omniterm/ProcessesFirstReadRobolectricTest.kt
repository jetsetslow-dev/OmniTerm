package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ProcessesTab
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.CompletableDeferred
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
 * Processes shows its sort chips only once the first read lands. Before then nobody knows whether
 * the host reports disk and GPU use, and showing the chips anyway showed CPU and MEM alone, then
 * added DISK and GPU a moment later. The Flutter app keeps the same rule.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class ProcessesFirstReadRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun theSortChipsAppearOnceAndAllTogether() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = GatedProcesses()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val (model, server) = runBlocking {
                val id = repo.insertServer(ServerEntity(name = "Processes fixture", host = "fixture.invalid", username = "fixture")).toInt()
                serverId = id
                val model = withContext(main) { AppViewModel(application, transport) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
                withContext(main) { model.selectedServerId = id }
                model to withContext(main) { model.servers.value.single { it.id == id } }
            }

            composeTestRule.setContent { MyApplicationTheme { ProcessesTab(model, server) } }
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText("Reading the process list…").fetchSemanticsNodes().isNotEmpty()
            }
            composeTestRule.onNodeWithText("↓ CPU").assertDoesNotExist()
            composeTestRule.onNodeWithText("↓ MEM").assertDoesNotExist()

            transport.answer.complete(PROCESSES_WITH_DISK_USE)
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText("↓ DISK").fetchSemanticsNodes().isNotEmpty()
            }
            composeTestRule.onNodeWithText("↓ CPU").assertExists()
            composeTestRule.onNodeWithText("↓ MEM").assertExists()
            composeTestRule.onNodeWithText("Reading the process list…").assertDoesNotExist()
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

    private companion object {
        val PROCESSES_WITH_DISK_USE = """
            PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND
            101 root 12.0 1.5 2048 01:00 S rsync
            ${RemoteCommands.PROCESS_SAMPLE_MARKER} 1000000000
            /proc/101/io:read_bytes: 1000
            /proc/101/io:write_bytes: 500
            ${RemoteCommands.PROCESS_SAMPLE_MARKER} 2000000000
            /proc/101/io:read_bytes: 2000
            /proc/101/io:write_bytes: 500
        """.trimIndent()
    }

    /** Holds the process read until the test lets it land; every other command answers nothing. */
    private class GatedProcesses : SshTransport {
        val answer = CompletableDeferred<String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
            if (command == RemoteCommands.PROCESSES) answer.await() else ""

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
