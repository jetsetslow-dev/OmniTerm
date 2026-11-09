package com.jetsetslow.omniterm

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.automation.AutomationGate
import com.jetsetslow.omniterm.automation.AutomationRunner
import com.jetsetslow.omniterm.automation.RunNotifications
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.AutomationUseEntity
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetRunSummary
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * An automation run, as the job runs it: only with the switch on and the grant still there, only a
 * script Script Check would accept, on each host as Fleet runs a saved script, and kept in Fleet's
 * history from the moment it starts. Each use goes in its token's history, and its notification
 * follows the token's choice.
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
    fun aRunIsInTheHistoryWhileItRunsAndItsNotificationShowsHowFarItIs() = withLab { transport ->
        transport.held[PI] = CompletableDeferred()
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))

        val running = async { runner(transport).run(grant, hash) }
        val midway = waitFor { it.hosts == 2 && it.running == 1 && it.succeeded == 1 }
        val kept = repository.fleetRunHosts(midway.run.id).associateBy { it.serverName }
        assertEquals(BroadcastStatus.Success.name, kept.getValue("nas").status)
        assertEquals("the host still going shows as running", BroadcastStatus.Running.name, kept.getValue("pi").status)
        val progress = notification(midway.run.runKey)!!
        assertEquals("Tasker is running $SCRIPT_NAME", progress.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("1 of 2 hosts done", progress.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertTrue("progress stays while it runs", progress.flags and Notification.FLAG_ONGOING_EVENT != 0)

        transport.held.getValue(PI).complete(Unit)
        val result = running.await()
        assertTrue(result.succeeded)
        assertEquals(midway.run.runKey, result.runKey)
        val done = repository.fleetRunsFlow.first().single()
        assertEquals("one run, updated as it went", midway.run.id, done.run.id)
        assertEquals(0, done.running)
        assertEquals(2, done.succeeded)
        assertTrue(done.run.finishedAt >= done.run.startedAt)
        assertNull("a run that succeeded everywhere leaves no notification by default", notification(done.run.runKey))
    }

    @Test
    fun aStoppedRunSaysHowFarItGotInTheHistoryAndTheTokensUses() = withLab { transport ->
        transport.hangs += PI
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))

        val running = async { runner(transport).run(grant, hash) }
        val midway = waitFor { it.running == 1 && it.succeeded == 1 }
        running.cancel()
        runCatching { running.await() }

        val kept = repository.fleetRunHosts(midway.run.id).associateBy { it.serverName }
        assertEquals(BroadcastStatus.Success.name, kept.getValue("nas").status)
        assertEquals("a host cut off counts as failed", BroadcastStatus.Failure.name, kept.getValue("pi").status)
        assertEquals("Android stopped the run before it finished.", kept.getValue("pi").note)
        val use = repository.automationUsesFlow(grant).first().single()
        assertEquals(UseOutcome.FAILED, use.outcome)
        assertEquals("Android stopped the run before it finished.", use.detail)
        assertEquals("the use opens the run it got as far as", midway.run.runKey, use.runKey)
        val result = notification(midway.run.runKey)!!
        assertEquals("Tasker ran $SCRIPT_NAME", result.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("Android stopped the run before it finished.", result.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
    }

    @Test
    fun everyUseIsKeptWithWhatCameOfIt() = withLab { transport ->
        val (grant, hash) = grant(script("uptime"), listOf(nasId, piId))
        val run = runner(transport)
        run.run(grant, hash)
        transport.replies[PI] = "SSH Error: command failed (3): disk full\n"
        run.run(grant, hash)
        repository.insertSetting(Automation.SETTING_ENABLED, "false")
        run.run(grant, hash)
        val (destructive, hash2) = grant(script("rm -rf /srv/data"), listOf(nasId))
        repository.insertSetting(Automation.SETTING_ENABLED, "true")
        run.run(destructive, hash2)

        val uses = repository.automationUsesFlow(grant).first()
        assertEquals(listOf(UseOutcome.REFUSED, UseOutcome.FAILED, UseOutcome.OK), uses.map { it.outcome })
        assertEquals("Automation is off in OmniTerm. Turn it on in Tools → Automation.", uses[0].detail)
        assertNull("nothing ran, so there is no run to open", uses[0].runKey)
        assertEquals("pi: Exited with status 3.", uses[1].detail)
        assertEquals("nas, pi", uses[2].detail)
        val runs = repository.fleetRunsFlow.first().map { it.run.runKey }.toSet()
        assertTrue("each use that ran opens its own run", uses[1].runKey in runs && uses[2].runKey in runs && uses[1].runKey != uses[2].runKey)
        val refused = repository.automationUsesFlow(destructive).first().single()
        assertEquals(UseOutcome.REFUSED, refused.outcome)
        assertTrue(refused.detail.startsWith("Automation runs it without asking"))
        assertEquals("another token's uses stay its own", 3, uses.size)
    }

    @Test
    fun aTokensUsesKeepTheNewestAndGoWithIt() = withLab { _ ->
        val (grant, _) = grant(script("uptime"), listOf(nasId))
        (1..5).forEach {
            repository.recordAutomationUse(AutomationUseEntity(grantId = grant, at = it.toLong(), outcome = UseOutcome.OK, detail = "use $it"), keep = 3)
        }
        assertEquals(listOf("use 5", "use 4", "use 3"), repository.automationUsesFlow(grant).first().map { it.detail })
        repository.deleteAutomationGrant(grant)
        assertTrue("revoking a token deletes its history", repository.automationUsesFlow(grant).first().isEmpty())
    }

    @Test
    fun theNotificationFollowsTheTokensChoice() = withLab { transport ->
        transport.replies[PI] = "SSH Error: command failed (3): disk full\n"
        val (failing, hash) = grant(script("uptime"), listOf(nasId, piId))
        val failed = runner(transport).run(failing, hash)
        val kept = notification(failed.runKey!!)!!
        assertEquals("a failure stays, naming the host", "Failed on pi.", kept.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals("a tap opens the run", "omniterm://notification/fleet-run/${failed.runKey}", shadowOf(kept.contentIntent).savedIntent.dataString)

        transport.replies.remove(PI)
        val (always, hash2) = grant(script("uptime"), listOf(nasId, piId), notify = RunNotify.ALWAYS)
        val succeeded = runner(transport).run(always, hash2)
        assertEquals("Succeeded on all 2 hosts.", notification(succeeded.runKey!!)!!.extras.getCharSequence(Notification.EXTRA_TEXT).toString())

        transport.replies[PI] = "SSH Error: command failed (3): disk full\n"
        val (quiet, hash3) = grant(script("uptime"), listOf(nasId, piId), notify = RunNotify.OFF)
        val silent = runner(transport).run(quiet, hash3)
        assertFalse(silent.succeeded)
        assertNull("off means no notification, even for a failure", notification(silent.runKey!!))
    }

    @Test
    fun aRunCutOffWithItsProcessIsEndedLater() = withLab { _ ->
        val now = 10 * FleetRunHistory.STALE_RUNNING_MS
        suspend fun saved(key: String, source: String, startedAt: Long) = repository.recordFleetRun(
            FleetRunEntity(runKey = key, startedAt = startedAt, finishedAt = startedAt, command = "uptime", source = source),
            listOf(FleetRunHistory.host(nasId, "nas", BroadcastStatus.Running.name, null, "", truncated = false)),
        )
        saved("automation-old", FleetRunHistory.SOURCE_AUTOMATION, now - FleetRunHistory.STALE_RUNNING_MS - 1)
        saved("automation-new", FleetRunHistory.SOURCE_AUTOMATION, now - 60_000)
        saved("fleet-old", FleetRunHistory.SOURCE_FLEET, now - FleetRunHistory.STALE_RUNNING_MS - 1)

        assertEquals(1, repository.endStaleLiveRuns(now, "cut off"))
        val byKey = repository.fleetRunsFlow.first().associateBy { it.run.runKey }
        val old = repository.fleetRunHosts(byKey.getValue("automation-old").run.id).single()
        assertEquals(BroadcastStatus.Failure.name, old.status)
        assertEquals("cut off", old.note)
        assertEquals("a run still within its limit keeps running", 1, byKey.getValue("automation-new").running)
        assertEquals("Broadcast's own runs are never touched", 1, byKey.getValue("fleet-old").running)
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
    private suspend fun grant(scriptId: Int, hosts: List<Int>, notify: String = RunNotify.FAILURES): Pair<Int, String> {
        lastToken = Automation.newToken()
        val hash = Automation.hash(lastToken)
        val id = repository.insertAutomationGrant(
            AutomationGrantEntity(
                scriptId = scriptId, serverIds = Automation.joinServerIds(hosts), tokenHash = hash, label = "Tasker", createdAt = 1L,
                notify = notify,
            ),
        )
        return id to hash
    }

    /** The one run in the history, once [ready] says it has got that far. */
    private suspend fun waitFor(ready: (FleetRunSummary) -> Boolean): FleetRunSummary = withTimeout(20_000) {
        var found: FleetRunSummary? = null
        while (found == null) {
            found = repository.fleetRunsFlow.first().singleOrNull()?.takeIf(ready)
            if (found == null) delay(20)
        }
        checkNotNull(found)
    }

    private fun notification(runKey: String): Notification? =
        shadowOf(application.getSystemService(NotificationManager::class.java)).getNotification(RunNotifications.idFor(runKey))

    private fun withLab(block: suspend CoroutineScope.(FakeHosts) -> Unit) = runBlocking {
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
        /** Hosts whose command waits until the test completes theirs. */
        val held = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        val commands = CopyOnWriteArrayList<Pair<SshCredentials, String>>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands.add(creds to command)
            if (creds.host in unreachable) return "SSH Error: Connection refused"
            if (command == RemoteCommands.OS_PROBE) return os[creds.host] ?: "Linux\n/bin/bash"
            if (creds.host in hangs) awaitCancellation()
            held[creds.host]?.await()
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
