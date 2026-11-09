package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.mcp.AppMcpBackend
import com.jetsetslow.omniterm.mcp.McpConfig
import com.jetsetslow.omniterm.ui.DEVICE_LOCAL_SETTINGS
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** What the MCP tools get from the app's own data: only the hosts the user shared. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AppMcpBackendRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()
    private val app: Application = ApplicationProvider.getApplicationContext()

    private class NoSsh : SshTransport {
        val commands = mutableListOf<String>()
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String {
            commands += command
            return "SSH Error: connection refused"
        }
        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit) = ""
        override suspend fun testConnection(creds: SshCredentials): String? = "refused"
        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("no shells here")
    }

    @Test
    fun onlyTheSharedHostsAreSeenAndAlertsNameTheirMount() = runBlocking {
        val repository = AppRepository(AppDatabase.getDatabase(app))
        val a = repository.insertServer(ServerEntity(name = "a", host = "10.0.0.1", username = "u")).toInt()
        val b = repository.insertServer(ServerEntity(name = "b", host = "10.0.0.2", username = "u")).toInt()
        repository.insertServer(ServerEntity(name = "c", host = "10.0.0.3", username = "u"))
        repository.insertRule(AlertRuleEntity(id = 77, serverId = a, metricName = "Disk Usage", mountPoint = "/srv", thresholdValue = 80f, severity = "WARNING"))
        val rule = 77
        repository.insertAlert(ActiveAlertEntity(ruleId = rule, serverId = a, metricName = "Disk Usage", currentValue = 91f, thresholdValue = 80f, severity = "WARNING", triggeredTime = 1))
        var config = McpConfig(enabled = true, hostIds = setOf(a, b))
        val ssh = NoSsh()
        val backend = AppMcpBackend(app, repository, ssh) { config }

        assertThat(backend.exposedHosts().map { it.name }).containsExactly("a", "b")
        config = config.copy(hostIds = setOf(b))
        assertWithMessage("a change applies to the next call").that(backend.exposedHosts().map { it.name }).containsExactly("b")
        config = config.copy(hostIds = emptySet())
        assertThat(backend.exposedHosts()).isEmpty()

        val alert = backend.activeAlerts(a).single()
        assertThat(alert.mount).isEqualTo("/srv")
        assertThat(alert.value).isEqualTo(91f)
        assertThat(backend.activeAlerts(b)).isEmpty()

        assertThat(backend.anyCommandAllowed()).isFalse()
        config = config.copy(anyCommand = true)
        assertThat(backend.anyCommandAllowed()).isTrue()

        val srv = repository.getServerById(a)!!
        val containers = backend.containers(srv)
        assertThat(containers.isFailure).isTrue()
        assertWithMessage("the reason names the host, not its address or the SSH error")
            .that(containers.exceptionOrNull()!!.message).isEqualTo("Could not reach a.")
        assertThat(ssh.commands).hasSize(1)
        assertThat(backend.dangerHits("rm -rf /")).isNotEmpty()
    }

    @Test
    fun theSettingsAreReadStrictlyAndNeverBackedUp() {
        val config = McpConfig.from(
            mapOf(
                McpSettings.ENABLED to "true",
                McpSettings.TOKEN_HASH to "a".repeat(64),
                McpSettings.HOSTS to "3,1,x,-2,3",
                McpSettings.ANY_COMMAND to "true",
                McpSettings.PORT to "80",
                McpSettings.TUNNEL_HOST to "4",
                McpSettings.TUNNEL_PORT to "50000",
            ),
        )
        assertThat(config.enabled).isTrue()
        assertThat(config.hostIds).containsExactly(1, 3)
        assertWithMessage("a port a phone app cannot use falls back").that(config.port).isEqualTo(McpSettings.DEFAULT_PORT)
        assertThat(config.tunnelHostId).isEqualTo(4)
        assertThat(config.tunnelPort).isEqualTo(50_000)
        assertThat(config.anyCommand).isTrue()

        val off = McpConfig.from(mapOf(McpSettings.TOKEN_HASH to "short", McpSettings.TUNNEL_HOST to ""))
        assertThat(off.enabled).isFalse()
        assertWithMessage("a malformed hash lets nothing in").that(off.tokenHash).isNull()
        assertThat(off.tunnelHostId).isNull()
        assertThat(off.hostIds).isEmpty()
        assertThat(off.anyCommand).isFalse()

        assertWithMessage("restoring a backup never turns AI access on").that(DEVICE_LOCAL_SETTINGS).containsAtLeastElementsIn(McpSettings.ALL)
    }

    @Test
    fun theRecordOfCallsKeepsTheNewest() = runBlocking {
        val repository = AppRepository(AppDatabase.getDatabase(app))
        repository.clearMcpCalls()
        (1..5).forEach { repository.recordMcpCall(McpCallEntity(at = it.toLong(), client = "c", tool = "t$it", outcome = "ok", detail = ""), keep = 3) }
        assertThat(repository.mcpCallsFlow.first().map { it.tool }).containsExactly("t5", "t4", "t3").inOrder()
        repository.clearMcpCalls()
        assertThat(repository.mcpCallsFlow.first()).isEmpty()
    }
}
