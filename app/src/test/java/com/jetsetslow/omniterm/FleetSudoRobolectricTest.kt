package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.shares.RemoteFsClient
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Fleet with sudo: nothing runs until the user says so, each host then runs the whole command as
 * root with its own saved sudo password on the command's input and never in the command, sudo's
 * refusal is what the card says, and a push to a folder the login may not write to arrives in the
 * login's home and is put in place by root.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class FleetSudoRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aSudoRunWaitsForTheAnswerThenRunsAsRootWithEachHostsOwnPassword() = withFleet { model, main, hosts, ids ->
        withContext(main) {
            // Run in tmux is on, and is not used: a password cannot be handed to tmux safely.
            model.updateBroadcastInTmux(true)
            model.runFleetBroadcast(COMMAND, ids, sudo = true)
        }
        delay(300)
        assertTrue("nothing runs before the answer", hosts.ran.isEmpty())
        assertFalse(withContext(main) { model.isBroadcastExecuting })
        assertEquals("2 hosts (nas, pi)", withContext(main) { model.pendingSudoAction }!!.hostName)

        withContext(main) { model.confirmPendingSudoAction() }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || model.broadcastResults.size < 2 }

        val ran = hosts.ran.associateBy { it.host }
        assertEquals("the whole command, as root, in sh", "sudo -S -p '' sh -c 'systemctl restart nginx && echo done' 2>&1", ran.getValue(NAS).command)
        assertEquals("its password goes in on the command's input", "nas-secret\n", ran.getValue(NAS).stdin)
        assertEquals("a host with no saved password asks sudo for none", "sudo -n sh -c 'systemctl restart nginx && echo done' 2>&1", ran.getValue(PI).command)
        assertNull(ran.getValue(PI).stdin)
        assertTrue("no password in any command", hosts.ran.none { "nas-secret" in it.command })
        assertTrue("and no tmux", hosts.ran.none { "tmux" in it.command })
        assertTrue(model.broadcastResults.all { it.status == BroadcastStatus.Success })

        val run = withTimeout(10_000) { repository.fleetRunsFlow.first { it.isNotEmpty() } }.single().run
        assertTrue("the history says it ran with sudo", run.sudo)
        assertEquals(COMMAND, run.command)
        assertTrue(model.broadcastReport(), withContext(main) { model.broadcastReport() }.startsWith("# $COMMAND\n"))
        assertTrue(model.fleetRunReport(run, model.fleetRunResults(run.id)).startsWith("# $COMMAND\n"))

        // Used again from the history, it is a sudo run again, and still asks.
        withContext(main) {
            model.updateBroadcastSudo(false)
            model.loadFleetRunIntoBroadcast(run, ids)
        }
        waitWhileOnMain(main, 5_000) { !model.broadcastSudo }
    }

    @Test
    fun sayingNoRunsNothing() = withFleet { model, main, hosts, ids ->
        withContext(main) { model.runFleetBroadcast(COMMAND, ids, sudo = true) }
        assertNotNull(withContext(main) { model.pendingSudoAction })
        withContext(main) { model.cancelPendingSudoAction() }
        delay(300)
        assertTrue(hosts.ran.isEmpty())
        assertTrue(withContext(main) { model.broadcastResults.isEmpty() })
        assertTrue(repository.fleetRunsFlow.first().isEmpty())
    }

    @Test
    fun sudosRefusalIsWhatTheCardSaysAndARetryAsksAgain() = withFleet { model, main, hosts, ids ->
        hosts.says[PI] = "sudo: a password is required\n" to 1
        // A command that fails on its own is not sudo refusing.
        hosts.says[NAS] = "cat: /root/secret: Permission denied\n" to 1
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast(COMMAND, ids, sudo = true)
            model.confirmPendingSudoAction()
        }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || model.broadcastResults.size < 2 }
        val cards = withContext(main) { model.broadcastResults.associateBy { it.serverName } }
        assertEquals(
            "sudo did not run it (sudo: a password is required). Check the sudo password in this host's settings.",
            cards.getValue("pi").note,
        )
        assertEquals("Exited with status 1.", cards.getValue("nas").note)

        hosts.ran.clear()
        hosts.says.clear()
        withContext(main) { model.retryFailedBroadcastHosts() }
        delay(300)
        assertTrue("a retry of a sudo run asks again", hosts.ran.isEmpty())
        assertEquals("2 hosts (nas, pi)", withContext(main) { model.pendingSudoAction }!!.hostName)
        withContext(main) { model.confirmPendingSudoAction() }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || hosts.ran.size < 2 }
        assertTrue(hosts.ran.all { it.command.startsWith("sudo ") })
        assertTrue(withContext(main) { model.broadcastResults.all { it.status == BroadcastStatus.Success } })
    }

    @Test
    fun aWindowsHostHasNoSudoAndSaysSo() = withFleet(
        // Before the app first asks the host what it is, which it does as soon as it starts.
        setUp = { os[PI] = "'uname' is not recognized as an internal or external command" },
    ) { model, main, hosts, ids ->
        withContext(main) {
            model.updateBroadcastInTmux(false)
            model.runFleetBroadcast(COMMAND, ids, sudo = true)
            model.confirmPendingSudoAction()
        }
        waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || model.broadcastResults.size < 2 }
        val cards = withContext(main) { model.broadcastResults.associateBy { it.serverName } }
        assertEquals(BroadcastStatus.Failure, cards.getValue("pi").status)
        assertEquals("Windows hosts have no sudo.", cards.getValue("pi").note)
        assertEquals(BroadcastStatus.Success, cards.getValue("nas").status)
        assertTrue("nothing was sent to the Windows host", hosts.ran.none { it.host == PI })
    }

    @Test
    fun aSudoPushArrivesInTheLoginsHomeAndRootPutsItInPlace() {
        val nas = MemoryHost("/home/u", listOf("/", "/home", "/home/u"))
        val pi = MemoryHost("/home/u", listOf("/", "/home", "/home/u"))
        withFleet(files = { srv -> if (srv.name == "nas") nas else pi }) { model, main, hosts, ids ->
            hosts.execSays[NAS] = "${RemoteCommands.SUDO_PUSHED_MARKER} /etc/app/app.conf\n"
            hosts.execSays[PI] = "sudo: a password is required\n"
            val application = ApplicationProvider.getApplicationContext<Application>()
            val source = File(application.filesDir, "app.conf").apply { writeText(CONTENT) }
            withContext(main) { model.pickFleetPushFile(Uri.fromFile(source)) }
            waitWhileOnMain(main, 10_000) { model.fleetPushReading || model.fleetPushPick == null && model.fleetPushError == null }
            withContext(main) {
                model.fleetPushDestination = "/etc/app/"
                model.updateBroadcastSudo(true)
                model.runFleetPush(ids)
            }
            delay(300)
            assertTrue("nothing is uploaded before the answer", nas.files.isEmpty() && hosts.ran.isEmpty())
            withContext(main) { model.confirmPendingSudoAction() }
            waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting || model.broadcastResults.size < 2 }

            // The whole file arrived in the login's own home, under a hidden name...
            val staged = nas.files.keys.single()
            assertTrue(staged, staged.startsWith("/home/u/.omniterm-push-") && staged.endsWith(".part"))
            assertEquals(CONTENT, String(nas.files.getValue(staged)))
            // ...and root was asked to put it in place, with the password on the input.
            val asked = hosts.ran.single { it.host == NAS }
            assertTrue(asked.command, asked.command.startsWith("sudo -S -p '' sh -c "))
            assertTrue(asked.command, staged in asked.command && "/etc/app/" in asked.command && "app.conf" in asked.command)
            assertEquals("nas-secret\n", asked.stdin)
            val cards = withContext(main) { model.broadcastResults.associateBy { it.serverName } }
            assertEquals(cards.getValue("nas").note, BroadcastStatus.Success, cards.getValue("nas").status)
            assertTrue(cards.getValue("nas").output, cards.getValue("nas").output.endsWith("to /etc/app/app.conf"))

            // sudo refused on pi: the card says so, and what was uploaded is taken away again.
            assertEquals(BroadcastStatus.Failure, cards.getValue("pi").status)
            assertEquals(
                "sudo did not run it (sudo: a password is required). Check the sudo password in this host's settings.",
                cards.getValue("pi").note,
            )
            assertTrue("nothing is left in the login's home: ${pi.files.keys}", pi.files.isEmpty())
            val run = withTimeout(10_000) { repository.fleetRunsFlow.first { it.isNotEmpty() } }.single().run
            assertTrue(run.sudo)
            assertEquals("app.conf", run.pushedFile)
        }
    }

    @Test
    fun rootsScriptNamesItsPathsSafelyAndSaysWhereTheFileWent() {
        val script = RemoteCommands.sudoInstallFile("/home/u/.omniterm-push-1.part", "/etc/it's here/", "a b.conf")
        assertTrue(script, script.startsWith("s='/home/u/.omniterm-push-1.part'; d='/etc/it'\\''s here/'; "))
        assertTrue("the file is finished beside its destination, then moved over it", "mv -f -- \"\$t\" \"\$d\"" in script)
        assertTrue("what was uploaded goes either way", "trap 'rm -f -- \"\$s\"' EXIT" in script)
        assertEquals("/etc/app/app.conf", RemoteCommands.sudoPushedPath("We trust you have received the usual lecture.\nomniterm_pushed /etc/app/app.conf\n"))
        assertNull(RemoteCommands.sudoPushedPath("sudo: a password is required\n"))
        assertEquals("/etc/app", RemoteCommands.sudoPushMissingFolder("omniterm_push_no_folder /etc/app\n"))
        assertEquals("Sorry, try again.", RemoteCommands.sudoRefusal("Sorry, try again.\nsudo: 1 incorrect password attempt\n"))
        assertEquals("admin is not in the sudoers file.", RemoteCommands.sudoRefusal("\nadmin is not in the sudoers file.\n"))
        assertNull("a command's own complaint is not sudo's", RemoteCommands.sudoRefusal("cat: /root/x: Permission denied\n"))
        assertNull(RemoteCommands.sudoRefusal("line 1\nline 2\nline 3\nline 4\nsudo: said late, by the command itself\n"))
        assertTrue(RemoteCommands.hasSudo("Linux") && RemoteCommands.hasSudo("Darwin") && RemoteCommands.hasSudo(""))
        assertFalse(RemoteCommands.hasSudo("Windows"))
    }

    private lateinit var repository: AppRepository

    private fun withFleet(
        files: ((ServerEntity) -> RemoteFsClient)? = null,
        setUp: SudoHosts.() -> Unit = {},
        block: suspend (AppViewModel, CoroutineDispatcher, SudoHosts, List<Int>) -> Unit,
    ) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val hosts = SudoHosts().apply(setUp)
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            repository = AppRepository(db)
            val ids = listOf(
                repository.insertServer(ServerEntity(name = "nas", host = NAS, username = "u", status = "online", sudoPassword = "nas-secret")).toInt(),
                repository.insertServer(ServerEntity(name = "pi", host = PI, username = "u", status = "online")).toInt(),
            )
            val model = withContext(main) { if (files != null) AppViewModel(application, hosts, files) else AppViewModel(application, hosts) }
            store.put("sudo", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.size < 2 }
            block(model, main, hosts, ids)
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

    /** Hosts that record what they were asked to run, and on which input; each answers as told. */
    private class SudoHosts : SshTransport {
        data class Ran(val host: String, val command: String, val stdin: String?)

        val ran = CopyOnWriteArrayList<Ran>()
        /** What a host's OS probe says; Linux unless told otherwise. */
        val os = ConcurrentHashMap<String, String>()
        /** A host's output and exit status for a followed command. */
        val says = ConcurrentHashMap<String, Pair<String, Int>>()
        /** A host's answer to a sudo command that is not followed (a push being put in place). */
        val execSays = ConcurrentHashMap<String, String>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            if (command == RemoteCommands.OS_PROBE) return os[creds.host] ?: "Linux\n/bin/bash"
            // Metrics and other background reads get nothing; only what Fleet sends is recorded.
            if (!command.startsWith("sudo ")) return ""
            ran.add(Ran(creds.host, command, stdin))
            return execSays[creds.host].orEmpty()
        }

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String {
            ran.add(Ran(creds.host, command, stdin))
            val (output, exit) = says[creds.host] ?: ("done\n" to 0)
            onChunk(output)
            // As the real transport words a command's own failure.
            return if (exit == 0) output else "SSH Error: command failed ($exit): ${output.trim()}"
        }

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("No shell is opened in these tests")
    }

    private companion object {
        const val NAS = "nas.invalid"
        const val PI = "pi.invalid"
        const val COMMAND = "systemctl restart nginx && echo done"
        const val CONTENT = "listen 8080\nworkers 4\n"
    }
}
