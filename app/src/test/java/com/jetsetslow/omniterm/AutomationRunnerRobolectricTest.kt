package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.automation.AutomationGate
import com.jetsetslow.omniterm.automation.AutomationRunner
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * An automation run, as the job runs it: only with the switch on and the grant still there, only a
 * script Script Check would accept, on each host as Fleet runs a saved script, and kept in Fleet's
 * history.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AutomationRunnerRobolectricTest {

    @Test
    fun itRunsTheScriptOnEachHostAndKeepsTheRun() = withLab { transport ->
        transport.os[PI] = "Linux\n/bin/bash"
        transport.replies[NAS] = "up 3 days\n"
        transport.replies[PI] = "SSH Error: command failed (3): disk full\n"
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))

        val result = runner(transport).run(grant, hash)

        assertFalse(result.succeeded)
        assertEquals(3, result.exit)
        val hosts = result.hosts.associateBy { it.name }
        assertEquals(0, hosts.getValue("nas").exit)
        assertEquals("up 3 days\n", hosts.getValue("nas").output)
        assertEquals(3, hosts.getValue("pi").exit)
        assertEquals("disk full\n", hosts.getValue("pi").output)
        assertEquals("Exited with status 3.", hosts.getValue("pi").note)
        assertEquals("pi: Exited with status 3.", result.errorMessage)

        val run = repository.fleetRunsFlow.first().single()
        assertEquals(FleetRunHistory.SOURCE_AUTOMATION, run.run.source)
        assertEquals("uptime", run.run.command)
        assertEquals(SCRIPT_NAME, run.run.scriptName)
        assertEquals(2, run.hosts)
        assertEquals(1, run.succeeded)
        val kept = repository.fleetRunHosts(run.run.id).associateBy { it.serverName }
        assertEquals(BroadcastStatus.Success.name, kept.getValue("nas").status)
        assertEquals(BroadcastStatus.Failure.name, kept.getValue("pi").status)
        assertNotNull("the grant says when it was last used", repository.automationGrantById(grant)?.lastUsedAt)
    }

    @Test
    fun nothingRunsWhileAutomationIsOff() = withLab { transport ->
        val (grant, hash) = grant(script("uptime"), listOf(nasId))
        repository.insertSetting(Automation.SETTING_ENABLED, "false")

        val result = runner(transport).run(grant, hash)

        assertEquals("Automation is off in OmniTerm. Turn it on in Tools → Automation.", result.error)
        assertTrue("no host was contacted", transport.commands.isEmpty())
        assertTrue(repository.fleetRunsFlow.first().isEmpty())
    }

    @Test
    fun aRevokedOrWrongTokenRunsNothing() = withLab { transport ->
        val (grant, hash) = grant(script("uptime"), listOf(nasId))
        assertEquals(
            "OmniTerm does not know this token. It may have been revoked.",
            runner(transport).run(grant, Automation.hash("omt_" + "b".repeat(22))).error,
        )
        repository.deleteAutomationGrant(grant)
        assertNotNull(runner(transport).run(grant, hash).error)
        assertTrue(transport.commands.isEmpty())
    }

    @Test
    fun onlyAScriptThatCouldBeACheckRuns() = withLab { transport ->
        val (destructive, hash) = grant(script("rm -rf /srv/data"), listOf(nasId))
        assertTrue(runner(transport).run(destructive, hash).error!!.startsWith("Automation runs it without asking, so it must only read"))
        val (asks, hash2) = grant(script("echo {{name}}"), listOf(nasId))
        assertEquals(
            "Give every {{value}} in the script a default ({{name=value}}): an automation has nobody to ask.",
            runner(transport).run(asks, hash2).error,
        )
        assertTrue(transport.commands.isEmpty())
    }

    @Test
    fun defaultsAreFilledForTheHostsShellAndUserScriptsGoToTheLoginShell() = withLab { transport ->
        transport.os[PI] = "Windows"
        val (grant, hash) = grant(script("echo {{name=a b}}"), listOf(nasId, piId))
        runner(transport).run(grant, hash)
        val byHost = transport.commands.filter { it.second != RemoteCommands.OS_PROBE }.associateBy { it.first.host }
        assertEquals("echo 'a b'", byHost.getValue(NAS).second)
        assertEquals("echo \"a b\"", byHost.getValue(PI).second)
        assertFalse("a user's script runs in the login shell", byHost.getValue(NAS).first.posixShell)
    }

    @Test
    fun aBuiltInPresetRunsInTheAppsOwnFormForTheHost() = withLab { transport ->
        transport.os[PI] = "Windows"
        val kernel = "uname -sr 2>/dev/null || powershell -NoProfile -Command \"[Environment]::OSVersion.VersionString\""
        val (grant, hash) = grant(script(kernel), listOf(nasId, piId))
        runner(transport).run(grant, hash)
        val byHost = transport.commands.filter { it.second != RemoteCommands.OS_PROBE }.associateBy { it.first.host }
        assertEquals(kernel, byHost.getValue(NAS).second)
        assertTrue("sh on a Unix host", byHost.getValue(NAS).first.posixShell)
        assertTrue("encoded PowerShell on Windows", byHost.getValue(PI).second.startsWith("powershell"))
        assertFalse(byHost.getValue(PI).second.contains("uname"))
    }

    @Test
    fun aHostTheScriptIsNotForIsSkippedNotFailed() = withLab { transport ->
        transport.os[PI] = "Windows"
        val (grant, hash) = grant(script("uptime", targetOs = "Linux"), listOf(nasId, piId))
        val result = runner(transport).run(grant, hash)
        assertTrue(result.succeeded)
        val pi = result.hosts.single { it.name == "pi" }
        assertNull(pi.exit)
        assertEquals("Skipped, not Linux: pi", pi.note)
        assertEquals("only the probe ran there", listOf(RemoteCommands.OS_PROBE), transport.commands.filter { it.first.host == PI }.map { it.second })
        val kept = repository.fleetRunHosts(repository.fleetRunsFlow.first().single().run.id).single { it.serverName == "pi" }
        assertEquals(BroadcastStatus.NotRun.name, kept.status)
    }

    @Test
    fun anUnreachableHostFailsWithSshsOwnStatus() = withLab { transport ->
        transport.unreachable += PI
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))
        val result = runner(transport).run(grant, hash)
        val pi = result.hosts.single { it.name == "pi" }
        assertEquals(Automation.UNREACHABLE, pi.exit)
        assertEquals("Connection refused", pi.note)
        assertEquals(Automation.UNREACHABLE, result.exit)
    }

    @Test
    fun aHostThatHasNotFinishedInTimeFailsAsTimedOut() = withLab { transport ->
        transport.hangs += PI
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))
        // Without the run's own limit this would never end; the test's limit makes that a failure.
        val result = withTimeout(30_000) { runner(transport, timeoutMs = 1_500).run(grant, hash) }
        assertEquals(0, result.hosts.single { it.name == "nas" }.exit)
        assertEquals(Automation.TIMED_OUT, result.hosts.single { it.name == "pi" }.exit)
    }

    @Test
    fun theGateKnowsOnlyTokensItMade() = withLab { _ ->
        val (grant, _) = grant(script("uptime"), listOf(nasId))
        val gate = AutomationGate(application, repository)
        assertEquals(grant, gate.grantFor(lastToken)?.id)
        assertNull(gate.grantFor("omt_" + "c".repeat(22)))
        assertNull(gate.grantFor("not a token"))
        assertNull(gate.grantFor(null))
        assertNull(gate.refusal())
        repository.insertSetting(Automation.SETTING_ENABLED, "false")
        assertNotNull(gate.refusal())
    }

    private val application: Application get() = ApplicationProvider.getApplicationContext()
    private lateinit var repository: AppRepository
    private var nasId = 0
    private var piId = 0
    private var lastToken = ""

    private fun runner(transport: SshTransport, timeoutMs: Long = Automation.RUN_TIMEOUT_MS) =
        AutomationRunner(application, repository, transport, runTimeoutMs = timeoutMs)

    private suspend fun script(command: String, targetOs: String = "Any"): Int {
        repository.insertScript(QuickScriptEntity(emoji = "", name = SCRIPT_NAME, command = command, color = "cyan", targetOs = targetOs))
        return repository.getAllScripts().last { it.name == SCRIPT_NAME && it.command == command }.id
    }

    /** A grant for [scriptId] on [hosts], and its token's hash. */
    private suspend fun grant(scriptId: Int, hosts: List<Int>): Pair<Int, String> {
        lastToken = Automation.newToken()
        val hash = Automation.hash(lastToken)
        val id = repository.insertAutomationGrant(
            AutomationGrantEntity(scriptId = scriptId, serverIds = Automation.joinServerIds(hosts), tokenHash = hash, label = "Tasker", createdAt = 1L),
        )
        return id to hash
    }

    private fun withLab(block: suspend (FakeHosts) -> Unit) = runBlocking {
        repository = AppRepository(AppDatabase.getDatabase(application))
        repository.clearFleetRuns()
        repository.getAllScripts().filter { it.name == SCRIPT_NAME }.forEach { repository.deleteScript(it) }
        repository.insertSetting(Automation.SETTING_ENABLED, "true")
        nasId = repository.insertServer(ServerEntity(name = "nas", host = NAS, username = "fixture")).toInt()
        piId = repository.insertServer(ServerEntity(name = "pi", host = PI, username = "fixture")).toInt()
        try {
            block(FakeHosts())
        } finally {
            repository.deleteServer(repository.getServerById(nasId)!!)
            repository.deleteServer(repository.getServerById(piId)!!)
            repository.insertSetting(Automation.SETTING_ENABLED, "false")
        }
    }

    /** Hosts that answer the OS probe with [os] (Linux unless set) and each command with [replies]. */
    private class FakeHosts : SshTransport {
        val os = ConcurrentHashMap<String, String>()
        val replies = ConcurrentHashMap<String, String>()
        val unreachable = CopyOnWriteArrayList<String>()
        val hangs = CopyOnWriteArrayList<String>()
        val commands = CopyOnWriteArrayList<Pair<SshCredentials, String>>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(creds to command)
            if (creds.host in unreachable) return "SSH Error: Connection refused"
            if (command == RemoteCommands.OS_PROBE) return os[creds.host] ?: "Linux\n/bin/bash"
            if (creds.host in hangs) awaitCancellation()
            return replies[creds.host] ?: ""
        }

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String =
            error("automation reads whole results")

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("automation opens no shell")
    }

    private companion object {
        const val NAS = "10.0.0.10"
        const val PI = "10.0.0.11"
        const val SCRIPT_NAME = "automation fixture"
    }
}
