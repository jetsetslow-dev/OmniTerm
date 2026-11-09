package com.jetsetslow.omniterm.automation

import android.content.Context
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ScriptParams
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UnattendedScripts
import com.jetsetslow.omniterm.data.ssh.SSH_CONNECTION_LOST
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.sshCommandExit
import com.jetsetslow.omniterm.data.ssh.sshCommandOutput
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.builtInPresetCommandFor
import com.jetsetslow.omniterm.ui.commandDangerHits
import com.jetsetslow.omniterm.ui.scriptTargetLabel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/**
 * Whether a request may run: its token names a grant, and automation is on. A token OmniTerm does
 * not know gets no reply at all, so an app without one learns nothing, not even whether
 * automation is on.
 */
class AutomationGate(context: Context, private val repository: AppRepository) {
    private val context = context.applicationContext

    /** Whether the user has turned automation on. */
    suspend fun enabled(): Boolean = repository.getSetting(Automation.SETTING_ENABLED) == "true"

    /** The grant [token] opens, or null when OmniTerm does not know the token. */
    suspend fun grantFor(token: String?): AutomationGrantEntity? =
        token?.takeIf(Automation::looksLikeToken)?.let { repository.automationGrantByTokenHash(Automation.hash(it)) }

    /** Why the holder of a known token may not run it now, or null when it may. */
    suspend fun refusal(): String? = if (enabled()) null else context.getString(R.string.automation_is_off)
}

/**
 * Runs an automation grant's script on its hosts with nobody watching, as Fleet runs a saved script:
 * each host's OS is probed, a host the script is not for is skipped, `{{value}}` defaults are filled
 * for its shell, a built-in preset runs in the app's own form, and anything else in the login shell.
 * A host whose key is not yet trusted is refused, since there is nobody to approve it. The run is
 * kept in Fleet's history.
 */
class AutomationRunner(
    context: Context,
    private val repository: AppRepository,
    private val transport: SshTransport,
    private val clock: () -> Long = System::currentTimeMillis,
    private val runTimeoutMs: Long = Automation.RUN_TIMEOUT_MS,
) {
    private val context = context.applicationContext
    private val gate = AutomationGate(context, repository)

    init {
        // Started by another app, the process may have no screen that has done this yet.
        SshHostKeyTrust.init(this.context)
    }

    /**
     * Runs grant [grantId], if it is still the grant whose token hashes to [tokenHash] and
     * automation is still on: a token revoked, or the switch turned off, after the request arrived
     * runs nothing.
     */
    suspend fun run(grantId: Int, tokenHash: String): Automation.RunResult {
        gate.refusal()?.let { return refused(it) }
        val grant = repository.automationGrantById(grantId)?.takeIf { it.tokenHash == tokenHash }
            ?: return refused(context.getString(R.string.automation_unknown_token))
        val started = clock()
        repository.markAutomationGrantUsed(grant.id, started)
        val script = repository.getAllScripts().find { it.id == grant.scriptId }
        UnattendedScripts.problem(script, script?.let { commandDangerHits(it.command) }.orEmpty(), UnattendedScripts.Runner.AUTOMATION)
            ?.let { return refused(it) }
        script!!
        val servers = Automation.parseServerIds(grant.serverIds).mapNotNull { repository.getServerById(it) }
        if (servers.isEmpty()) return refused(context.getString(R.string.automation_no_hosts))
        return runScript(script, servers, emptyMap(), FleetRunHistory.SOURCE_AUTOMATION)
    }

    /**
     * Runs [script] on [servers] and keeps the run in Fleet's history under [source]. [values] fill
     * its `{{values}}` (a value left out takes its default); null runs the command exactly as written,
     * for a command that was typed rather than saved. The caller has already decided it may run.
     */
    suspend fun runScript(
        script: QuickScriptEntity,
        servers: List<ServerEntity>,
        values: Map<String, String>?,
        source: String,
    ): Automation.RunResult {
        val started = clock()
        val deadline = started + runTimeoutMs
        val gate = Semaphore(Automation.PARALLEL_HOSTS)
        val hosts = coroutineScope {
            servers.map { srv -> async { gate.withPermit { runOn(script, srv, values, deadline) } } }.awaitAll()
        }
        record(script, started, hosts, source)
        return Automation.RunResult(hosts)
    }

    private fun refused(reason: String) = Automation.RunResult(emptyList(), reason)

    private suspend fun runOn(script: QuickScriptEntity, srv: ServerEntity, values: Map<String, String>?, deadline: Long): Automation.HostResult =
        withTimeoutOrNull((deadline - clock()).coerceAtLeast(1)) { attempt(script, srv, values) }
            ?: Automation.HostResult(
                srv.id, srv.name, Automation.TIMED_OUT, "",
                context.getString(R.string.broadcast_timed_out, (runTimeoutMs / 60_000).toInt().coerceAtLeast(1)),
            )

    private suspend fun attempt(script: QuickScriptEntity, srv: ServerEntity, values: Map<String, String>?): Automation.HostResult {
        val probe = exec(HostCredentials.build(repository, srv, posixShell = false), RemoteCommands.OS_PROBE)
        if (sshCommandExit(probe) == null) return unreachable(srv, probe)
        val os = RemoteCommands.normaliseOs(probe)
        if (Automation.skipsOs(script, os)) {
            return Automation.HostResult(
                srv.id, srv.name, null, "",
                context.getString(R.string.broadcast_skipped_target, scriptTargetLabel(script), srv.name),
            )
        }
        val filled = if (values == null) script.command else try {
            ScriptParams.fill(script.command, values, ScriptParams.shellFor(os))
        } catch (e: ScriptParams.UnsafeValueException) {
            return Automation.HostResult(srv.id, srv.name, Automation.UNSAFE_VALUE, "", e.message ?: "unsafe value")
        }
        val preset = builtInPresetCommandFor(filled, os)
        val creds: SshCredentials = HostCredentials.build(repository, srv, posixShell = preset != null && RemoteCommands.hasUnixShell(os))
        val raw = exec(creds, preset ?: filled)
        val exit = sshCommandExit(raw) ?: return unreachable(srv, raw)
        return Automation.HostResult(
            srv.id, srv.name, exit, sshCommandOutput(raw),
            if (exit == 0) null else context.getString(R.string.broadcast_exited_with, exit),
        )
    }

    private suspend fun exec(creds: SshCredentials, command: String): String =
        try {
            transport.exec(creds, command)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            "SSH Error: ${e.message ?: "unknown error"}"
        }

    private fun unreachable(srv: ServerEntity, result: String) = Automation.HostResult(
        srv.id, srv.name, Automation.UNREACHABLE, "",
        if (result == "SSH Error: $SSH_CONNECTION_LOST") context.getString(R.string.broadcast_connection_lost)
        else result.removePrefix("SSH Error:").trim(),
    )

    private suspend fun record(script: QuickScriptEntity, started: Long, hosts: List<Automation.HostResult>, source: String) {
        val run = FleetRunEntity(
            runKey = "automation-" + UUID.randomUUID(),
            startedAt = started,
            finishedAt = clock(),
            command = script.command,
            scriptName = script.name,
            source = source,
        )
        repository.recordFleetRun(
            run,
            hosts.map { h ->
                val status = when (h.exit) {
                    null -> BroadcastStatus.NotRun
                    0 -> BroadcastStatus.Success
                    else -> BroadcastStatus.Failure
                }
                FleetRunHistory.host(h.serverId, h.name, status.name, h.note, h.output, truncated = false)
            },
        )
    }
}
