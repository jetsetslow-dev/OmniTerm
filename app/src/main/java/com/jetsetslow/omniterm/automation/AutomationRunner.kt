package com.jetsetslow.omniterm.automation

import android.content.Context
import android.util.Log
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.AutomationUseEntity
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetRunHostEntity
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ScriptParams
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UnattendedScripts
import com.jetsetslow.omniterm.data.UseOutcome
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
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap

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
 * in Fleet's history from the moment it starts, each host's result as it finishes, so it can be
 * watched there; its notification follows its token's [RunNotify] choice.
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
     * runs nothing. Every use of a token the grant still has is kept in its history, refused,
     * stopped and failed ones too.
     */
    suspend fun run(grantId: Int, tokenHash: String): Automation.RunResult {
        val grant = repository.automationGrantById(grantId)?.takeIf { it.tokenHash == tokenHash }
            ?: return refused(context.getString(R.string.automation_unknown_token))
        val at = clock()
        val runKey = Automation.newRunKey()
        var use: Pair<String, Automation.RunResult>? = null
        try {
            val result = runGrant(grant, at, runKey)
            use = when {
                result.error != null && result.hosts.isEmpty() -> UseOutcome.REFUSED
                result.succeeded -> UseOutcome.OK
                else -> UseOutcome.FAILED
            } to result
            return result
        } finally {
            withContext(NonCancellable) {
                // Stopped part-way: the run, if it got as far as starting, says how far it got.
                val (outcome, result) = use ?: (
                    UseOutcome.FAILED to Automation.RunResult(
                        emptyList(), context.getString(R.string.automation_stopped),
                        runKey.takeIf { safely { repository.fleetRunByKey(it) } != null },
                    )
                )
                safely {
                    repository.recordAutomationUse(
                        AutomationUseEntity(grantId = grant.id, at = at, outcome = outcome, detail = result.useDetail(), runKey = result.runKey),
                    )
                }
            }
        }
    }

    private suspend fun runGrant(grant: AutomationGrantEntity, at: Long, runKey: String): Automation.RunResult {
        gate.refusal()?.let { return refused(it) }
        repository.markAutomationGrantUsed(grant.id, at)
        val script = repository.getAllScripts().find { it.id == grant.scriptId }
        UnattendedScripts.problem(script, script?.let { commandDangerHits(it.command) }.orEmpty(), UnattendedScripts.Runner.AUTOMATION)
            ?.let { return refused(it) }
        script!!
        val servers = Automation.parseServerIds(grant.serverIds).mapNotNull { repository.getServerById(it) }
        if (servers.isEmpty()) return refused(context.getString(R.string.automation_no_hosts))
        return runScript(script, servers, emptyMap(), FleetRunHistory.SOURCE_AUTOMATION, RunNotify.of(grant.notify), grant.label, runKey)
    }

    /**
     * Runs [script] on [servers] and keeps the run in Fleet's history under [source], saved when
     * it starts and as each host finishes. [values] fill its `{{values}}` (a value left out takes
     * its default); null runs the command exactly as written, for a command that was typed rather
     * than saved. [notify] ([RunNotify]) and [by], who asked for it, are for its notification, on
     * [channel]. The caller has already decided it may run.
     */
    internal suspend fun runScript(
        script: QuickScriptEntity,
        servers: List<ServerEntity>,
        values: Map<String, String>?,
        source: String,
        notify: String = RunNotify.OFF,
        by: String = "",
        runKey: String = Automation.newRunKey(),
        channel: RunNotifications.Channel = RunNotifications.Channel.EXTERNAL,
    ): Automation.RunResult {
        val started = clock()
        val deadline = started + runTimeoutMs
        val run = FleetRunEntity(
            runKey = runKey,
            startedAt = started,
            finishedAt = started,
            command = script.command,
            scriptName = script.name,
            source = source,
        )
        val notice = RunNotifications(context, runKey, script.name, by, notify, channel)
        val done = ConcurrentHashMap<Int, Automation.HostResult>()
        safely {
            repository.endStaleLiveRuns(started, context.getString(R.string.external_run_cut_off))
            repository.recordFleetRun(
                run,
                servers.map { FleetRunHistory.host(it.id, it.name, BroadcastStatus.Running.name, null, "", truncated = false) },
            )
        }
        notice.progress(0, servers.size)
        var hosts: List<Automation.HostResult>? = null
        try {
            val permits = Semaphore(Automation.PARALLEL_HOSTS)
            hosts = coroutineScope {
                servers.map { srv ->
                    async {
                        permits.withPermit { runOn(script, srv, values, deadline) }.also { result ->
                            done[srv.id] = result
                            notice.progress(done.size, servers.size)
                            safely { repository.recordFleetRun(run, listOf(row(result))) }
                        }
                    }
                }.awaitAll()
            }
            return Automation.RunResult(hosts, runKey = runKey)
        } finally {
            withContext(NonCancellable) {
                val stopped = context.getString(R.string.automation_stopped)
                val all = hosts ?: servers.map { srv ->
                    done[srv.id] ?: Automation.HostResult(srv.id, srv.name, Automation.STOPPED, "", stopped)
                }
                safely { repository.recordFleetRun(run.copy(finishedAt = clock()), all.map(::row)) }
                notice.finished(Automation.RunResult(all, error = if (hosts == null) stopped else null, runKey = runKey))
            }
        }
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
        // A command an AI assistant typed (no values) is not a template: its braces are the shell's.
        val filled = if (values == null) script.command else try {
            ScriptParams.fill(script.command, values, ScriptParams.shellFor(os), ScriptParams.HostVars.of(srv, os))
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

    private fun row(h: Automation.HostResult): FleetRunHostEntity {
        val status = when (h.exit) {
            null -> BroadcastStatus.NotRun
            0 -> BroadcastStatus.Success
            else -> BroadcastStatus.Failure
        }
        return FleetRunHistory.host(h.serverId, h.name, status.name, h.note, h.output, truncated = false)
    }

    /** Saving to the history never ends a run: a failed write is logged, and the run goes on. */
    private suspend fun <T> safely(write: suspend () -> T): T? =
        try {
            write()
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.w("OmniTermAutomation", "Saving the run to the history failed", e)
            null
        }
}
