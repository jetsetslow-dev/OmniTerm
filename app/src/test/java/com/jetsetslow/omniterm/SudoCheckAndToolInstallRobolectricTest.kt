package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostTool
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
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
 * Every sudo action waits for the user's say-so, whether or not a sudo password is saved and
 * whether or not App Lock is on, and a missing helper tool installs from the notice that names it:
 * through the sudo check, into the shared action panel, which says how it went and stays up for the
 * user to close while the values are read again behind it. The Flutter app keeps the same rules.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class SudoCheckAndToolInstallRobolectricTest {

    @Test
    fun readWithSudoAsksFirstEvenWithoutAppLockOrASavedPassword() = withModel { model, transport, main, _ ->
        assertFalse(model.sudoAuthUsesAppLock)
        withContext(main) { model.readSystemSpecsWithSudo(model.selectedServer!!) }
        assertEquals("Tool fixture", withContext(main) { model.pendingSudoAction?.hostName })
        delay(200)
        assertFalse("nothing may run as root before the user says so", transport.ranWithSudo())

        withContext(main) { model.cancelPendingSudoAction() }
        delay(200)
        assertNull(withContext(main) { model.pendingSudoAction })
        assertFalse("a cancelled read stays unprivileged", transport.ranWithSudo())

        withContext(main) {
            model.readSystemSpecsWithSudo(model.selectedServer!!)
            model.confirmPendingSudoAction()
        }
        waitWhileOnMain(main) { !transport.ranWithSudo() }
    }

    @Test
    fun aToolInstallsThroughTheSudoCheckThenReadsAgainBehindTheOpenPanel() = withModel { model, transport, main, _ ->
        transport.toolAnswers = true
        var reread = 0
        withContext(main) { model.installHostTool(model.selectedServer!!, HostTool.Smartmontools) { reread++ } }
        delay(200)
        assertTrue("the install waits for the sudo check", transport.streamed.isEmpty())

        withContext(main) { model.confirmPendingSudoAction() }
        waitWhileOnMain(main) { reread == 0 }
        // A saved password goes to `sudo -S` on stdin; `HostToolInstallTest` runs that path, since
        // saving one needs the Android keystore.
        assertEquals(listOf(HostTool.Smartmontools.installCommand(withSudoPassword = false) to null), transport.streamed.toList())
        withContext(main) {
            assertEquals(
                "the panel stays up, for the user to close, with the output and the outcome",
                FakeTransport.INSTALL_OUTPUT.trimEnd() + "\n\nsmartmontools is now installed on Tool fixture.",
                model.actionStreamOutput,
            )
            assertFalse(model.actionStreamRunning)
        }
    }

    @Test
    fun aFailedInstallKeepsItsOutputAndSaysSo() = withModel { model, transport, main, _ ->
        transport.toolAnswers = false
        var reread = 0
        withContext(main) {
            model.installHostTool(model.selectedServer!!, HostTool.Dmidecode) { reread++ }
            model.confirmPendingSudoAction()
        }
        waitWhileOnMain(main) { !model.actionStreamOutput.contains("still not installed") }
        // No saved password: sudo must refuse at once rather than wait on stdin for one.
        assertEquals(listOf(HostTool.Dmidecode.installCommand(withSudoPassword = false) to null), transport.streamed.toList())
        withContext(main) {
            assertTrue(model.actionStreamOutput, model.actionStreamOutput.startsWith(FakeTransport.INSTALL_OUTPUT))
            assertTrue(model.actionStreamOutput, model.actionStreamOutput.endsWith("dmidecode is still not installed on Tool fixture. The output above says why."))
        }
        assertEquals(0, reread)
    }

    @Test
    fun sftpSudoModeAsksBeforeTurningOnButNotBeforeTurningOff() = withModel { model, _, main, _ ->
        withContext(main) { model.toggleSftpSudo() }
        withContext(main) {
            assertFalse(model.sftpSudo)
            assertEquals("Tool fixture", model.pendingSudoAction?.hostName)
            model.cancelPendingSudoAction()
            assertFalse(model.sftpSudo)

            model.toggleSftpSudo()
            model.confirmPendingSudoAction()
            assertTrue(model.sftpSudo)

            model.toggleSftpSudo()
            assertFalse(model.sftpSudo)
            assertNull("turning sudo off never asks", model.pendingSudoAction)
        }
    }

    @Test
    fun theTmuxInstallAsksFirstToo() = withModel { model, transport, main, id ->
        withContext(main) {
            model.tmuxInstallPromptServer = model.servers.value.single { it.id == id }
            model.installTmuxAndConnect()
        }
        delay(200)
        assertTrue(transport.streamed.isEmpty())
        withContext(main) { model.confirmPendingSudoAction() }
        waitWhileOnMain(main) { transport.streamed.isEmpty() }
        assertEquals(RemoteCommands.tmuxInstallCommand(withSudoPassword = false), transport.streamed.first().first)
    }

    @Test
    fun processesNameNvidiaSmiWhereTheDriverRunsWithoutIt() = withModel { model, transport, main, _ ->
        transport.processes = """
            PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND
            101 root 12.0 1.5 2048 01:00 S Xorg
            ${RemoteCommands.PROCESS_NVIDIA_SMI_MISSING_MARKER}
        """.trimIndent()
        withContext(main) { model.loadProcesses() }
        waitWhileOnMain(main) { model.processesLoading || model.processes.isEmpty() }
        withContext(main) {
            assertEquals(HostTool.NvidiaSmi, model.processMissingTool)
            assertFalse(model.processGpuReported)
        }
    }

    private fun withModel(
        body: suspend (AppViewModel, FakeTransport, CoroutineDispatcher, Int) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel does its database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = FakeTransport()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val id = repo.insertServer(
                ServerEntity(name = "Tool fixture", host = "fixture.invalid", username = "fixture"),
            ).toInt()
            serverId = id
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) { model.selectedServerId = id }
            body(model, transport, main, id)
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

    /** Answers the specs, process and tool checks; records each streamed install and its stdin. */
    private class FakeTransport : SshTransport {
        companion object {
            const val INSTALL_OUTPUT = "Reading package lists...\n"
        }

        val execs = CopyOnWriteArrayList<String>()
        val streamed = CopyOnWriteArrayList<Pair<String, String?>>()
        @Volatile var toolAnswers = false
        @Volatile var processes = ""

        fun ranWithSudo() = execs.any { it.contains("sudo -n sh -c") || it.contains("sudo -S -p '' sh -c") }

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            execs.add(command)
            return when {
                HostTool.entries.any { it.checkCommand() == command } -> if (toolAnswers) "yes" else "no"
                command == RemoteCommands.PROCESSES -> processes
                command.contains("@NVIDIA") -> ""
                else -> ""
            }
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            streamed.add(command to stdin)
            onChunk(INSTALL_OUTPUT)
            return INSTALL_OUTPUT
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
}
