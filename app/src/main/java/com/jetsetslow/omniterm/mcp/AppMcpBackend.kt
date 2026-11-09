package com.jetsetslow.omniterm.mcp

import android.content.Context
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.automation.AutomationRunner
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SimContainer
import com.jetsetslow.omniterm.data.mcp.McpAlert
import com.jetsetslow.omniterm.data.mcp.McpApprovalRequest
import com.jetsetslow.omniterm.data.mcp.McpBackend
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.sshCommandExit
import com.jetsetslow.omniterm.ui.commandDangerHits
import kotlinx.coroutines.CancellationException

/**
 * The MCP tools' view of the app: only the hosts in [config]'s list, from the database; runs go
 * through automation's runner into Fleet's history; approvals go to the phone.
 */
class AppMcpBackend(
    context: Context,
    private val repository: AppRepository,
    private val transport: SshTransport,
    private val config: () -> McpConfig,
) : McpBackend {
    private val context = context.applicationContext

    override suspend fun exposedHosts(): List<ServerEntity> {
        val ids = config().hostIds
        return repository.getAllServers().filter { it.id in ids }
    }

    override suspend fun latestMetric(serverId: Int): MetricHistoryEntity? = repository.latestMetric(serverId)

    override suspend fun activeAlerts(serverId: Int): List<McpAlert> {
        val rules = repository.getAllRules().associateBy { it.id }
        return repository.getActiveAlerts().filter { it.serverId == serverId }.map { a ->
            val rule = rules[a.ruleId]
            McpAlert(
                metric = a.metricName,
                mount = rule?.mountPoint?.takeIf { a.metricName == "Disk Usage" },
                value = a.currentValue,
                threshold = a.thresholdValue,
                severity = a.severity,
                since = a.triggeredTime,
                acknowledged = a.acknowledged,
            )
        }
    }

    override suspend fun scripts(): List<QuickScriptEntity> = repository.getAllScripts()

    override suspend fun anyCommandAllowed(): Boolean = config().anyCommand

    override suspend fun containers(server: ServerEntity): Result<List<SimContainer>> {
        val raw = try {
            transport.exec(HostCredentials.build(repository, server, posixShell = true), RemoteCommands.DOCKER_PS)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            "SSH Error: ${e.message.orEmpty()}"
        }
        if (sshCommandExit(raw) == null) {
            return Result.failure(IllegalStateException(context.getString(R.string.mcp_host_unreachable, server.name)))
        }
        if (RemoteCommands.NO_CONTAINER_RUNTIME in raw) return Result.failure(IllegalStateException(RemoteCommands.NO_CONTAINER_RUNTIME))
        return Result.success(RemoteParsers.parseDockerPs(raw).map { it.copy(serverId = server.id) })
    }

    override suspend fun approve(request: McpApprovalRequest): Boolean =
        McpApprovals.ask(context, request, McpSettings.APPROVAL_TIMEOUT_MS)

    override fun dangerHits(command: String): List<String> = commandDangerHits(command)

    override suspend fun run(script: QuickScriptEntity, servers: List<ServerEntity>, values: Map<String, String>?): Automation.RunResult =
        AutomationRunner(context, repository, transport, runTimeoutMs = McpSettings.RUN_TIMEOUT_MS)
            .runScript(script, servers, values, FleetRunHistory.SOURCE_MCP)
}
