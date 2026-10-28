package com.jetsetslow.omniterm

import android.app.Application
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
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
import java.util.concurrent.Executors

/**
 * A Windows host gets Windows commands, or a plain "needs a Linux, macOS or BSD host", from every
 * screen that would otherwise send it a Unix shell script.
 *
 * The command builders are tested on their own in [HostOsCommandsTest]; this checks that the view
 * model actually asks the host's OS and routes through them, which a builder test cannot see.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class WindowsHostRoutingRobolectricTest {

    @Test
    fun aWindowsHostIsNeverSentAUnixScript() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = WindowsTransport()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            val id = repository.insertServer(
                ServerEntity(name = "Windows fixture", host = "windows.invalid", username = "fixture"),
            ).toInt()
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            withTimeout(10_000) { while (model.servers.value.none { it.id == id }) delay(10) }
            val server = checkNotNull(model.servers.value.first { it.id == id })
            withContext(main) { model.selectedServerId = id }

            withContext(main) { model.loadCron() }
            withTimeout(5_000) { while (!model.cronStatus.contains("Task Scheduler")) delay(10) }
            assertFalse("the Cron tab must not offer Add on Windows", model.cronReadable)

            withContext(main) { model.loadServices() }
            withTimeout(5_000) { while (model.services.isEmpty()) delay(10) }
            assertEquals("Spooler", model.services.single().name)
            assertTrue(model.services.single().enabled)

            withContext(main) { model.killProcess(42, 9) }
            withTimeout(5_000) { while ("taskkill /PID 42 /F 2>&1" !in transport.streamed) delay(10) }

            withContext(main) { model.runQuickCheck(server, RemoteCommands.QuickCheck.Uptime) }
            withTimeout(5_000) { while (transport.streamed.none { it.startsWith("powershell ") }) delay(10) }

            withContext(main) { model.loadDocker() }
            withTimeout(5_000) { while (model.dockerError?.contains("Linux, macOS or BSD") != true) delay(10) }

            withContext(main) { model.toggleSftpSudo() }
            assertFalse("Windows has no sudo to switch on", model.sftpSudo)
            assertTrue(model.sftpError.orEmpty().contains("sudo"))

            val unix = listOf("crontab", "systemctl", "docker", "podman", "kill -", "sudo ")
            val sent = transport.executed + transport.streamed
            sent.forEach { command ->
                if (command.startsWith("powershell ") || command.startsWith("taskkill ")) return@forEach
                unix.forEach { word -> assertFalse("sent \"$word\" to a Windows host: $command", command.contains(word)) }
            }
        } finally {
            store.clear()
            Dispatchers.resetMain()
            main.close()
        }
    }

    /** Answers like a Windows OpenSSH host whose shell is cmd.exe. */
    private class WindowsTransport : SshTransport {
        val executed = java.util.concurrent.CopyOnWriteArrayList<String>()
        val streamed = java.util.concurrent.CopyOnWriteArrayList<String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            executed.add(command)
            return when (command) {
                RemoteCommands.OS_PROBE -> "Windows\r\n"
                RemoteCommands.SERVICES_WINDOWS ->
                    "${RemoteCommands.SERVICE_TABLE_MARKER}\r\nSpooler\tRunning\tAutomatic\tPrint Spooler\r\n"
                else -> ""
            }
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            streamed.add(command)
            return ""
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
