package com.jetsetslow.omniterm.mcp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.jetsetslow.omniterm.BuildConfig
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.McpCallOutcome
import com.jetsetslow.omniterm.data.mcp.McpHandler
import com.jetsetslow.omniterm.data.mcp.McpHttpServer
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.data.mcp.McpTools
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.SshTunnelManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** What the server is doing, for the AI assistants screen and the notification. */
data class McpServerState(
    val running: Boolean = false,
    val port: Int? = null,
    /** The host a computer reaches it through, by name, when one is set. */
    val tunnelHost: String? = null,
    val tunnelPort: Int? = null,
    val tunnelUp: Boolean = false,
    /** Why the server or the tunnel is not up, in the user's words. */
    val problem: String? = null,
)

/** The settings the server reads, from the settings table. */
data class McpConfig(
    val enabled: Boolean = false,
    val tokenHash: String? = null,
    val hostIds: Set<Int> = emptySet(),
    val anyCommand: Boolean = false,
    val port: Int = McpSettings.DEFAULT_PORT,
    val tunnelHostId: Int? = null,
    val tunnelPort: Int = McpSettings.DEFAULT_PORT,
) {
    companion object {
        fun from(settings: Map<String, String>) = McpConfig(
            enabled = settings[McpSettings.ENABLED] == "true",
            tokenHash = settings[McpSettings.TOKEN_HASH]?.takeIf { it.length == 64 },
            hostIds = Automation.parseServerIds(settings[McpSettings.HOSTS].orEmpty()).toSet(),
            anyCommand = settings[McpSettings.ANY_COMMAND] == "true",
            port = McpSettings.port(settings[McpSettings.PORT]) ?: McpSettings.DEFAULT_PORT,
            tunnelHostId = settings[McpSettings.TUNNEL_HOST]?.toIntOrNull()?.takeIf { it > 0 },
            tunnelPort = McpSettings.port(settings[McpSettings.TUNNEL_PORT]) ?: McpSettings.DEFAULT_PORT,
        )
    }
}

/**
 * The MCP server, while the user has it on: listening on this phone's loopback address, and, when
 * the user picked a host, reachable from that host's own loopback address through a reverse SSH
 * tunnel OmniTerm keeps open. The ongoing notification says it is on and turns it off.
 */
class McpService : Service() {
    companion object {
        private const val TAG = "OmniTermMcp"
        private const val CHANNEL = "mcp_server"
        private const val NOTIFICATION_ID = 7_101
        const val ACTION_STOP = "com.jetsetslow.omniterm.action.MCP_STOP"
        /** The tunnel's id in [SshTunnelManager]: negative, so no saved port forward can share it. */
        const val TUNNEL_ID = -47_821
        private const val TUNNEL_RETRY_MS = 30_000L
        /** At most one refused request is recorded per this, so a flood cannot churn the record. */
        private const val REFUSED_RECORD_GAP_MS = 5_000L

        private val _state = MutableStateFlow(McpServerState())
        val state: StateFlow<McpServerState> = _state

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, McpService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, McpService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var repository: AppRepository
    private val transport: SshTransport = JschSshTransport()
    @Volatile private var config = McpConfig()
    private var server: McpHttpServer? = null
    private var watching: Job? = null
    private var tunnelJob: Job? = null
    @Volatile private var lastRefusedRecord = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        repository = AppRepository(AppDatabase.getDatabase(applicationContext))
        SshHostKeyTrust.init(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground(McpServerState())
        if (intent?.action == ACTION_STOP) {
            scope.launch {
                repository.insertSetting(McpSettings.ENABLED, "false")
                stopSelf()
            }
            return START_NOT_STICKY
        }
        if (watching == null) watching = watchSettings()
        return START_NOT_STICKY
    }

    /** Follows the settings: a new token or host list applies at once, a new port or tunnel restarts. */
    private fun watchSettings(): Job = scope.launch {
        var applied: McpConfig? = null
        repository.settingsFlow
            .map { rows -> McpConfig.from(rows.associate { it.key to it.value }) }
            .distinctUntilChanged()
            .collect { next ->
                config = next
                if (!next.enabled) {
                    stopSelf()
                    return@collect
                }
                val previous = applied
                applied = next
                if (previous == null || next.port != previous.port) listen(next)
                if (previous == null || next.port != previous.port ||
                    next.tunnelHostId != previous.tunnelHostId || next.tunnelPort != previous.tunnelPort
                ) {
                    keepTunnel(next)
                }
            }
    }

    private fun listen(next: McpConfig) {
        server?.stop()
        val fresh = McpHttpServer(
            tokenHash = { config.tokenHash },
            handler = { body, headers -> handler.handle(body, headers) },
            onRefused = ::recordRefused,
            onError = { Log.w(TAG, "An MCP request failed inside OmniTerm", it) },
        )
        server = fresh
        try {
            val port = fresh.start(next.port)
            publish(_state.value.copy(running = true, port = port, problem = null))
        } catch (e: Exception) {
            publish(_state.value.copy(running = false, port = null, problem = getString(R.string.mcp_port_busy, next.port)))
        }
    }

    /** Keeps the reverse tunnel up while a host is picked, retrying when it drops. */
    private fun keepTunnel(next: McpConfig) {
        tunnelJob?.cancel()
        SshTunnelManager.stop(TUNNEL_ID)
        val hostId = next.tunnelHostId
        if (hostId == null) {
            tunnelJob = null
            publish(_state.value.copy(tunnelHost = null, tunnelPort = null, tunnelUp = false))
            return
        }
        tunnelJob = scope.launch {
            while (true) {
                val srv = repository.getServerById(hostId)
                if (srv == null) {
                    publish(_state.value.copy(tunnelHost = null, tunnelUp = false, problem = getString(R.string.mcp_tunnel_host_gone)))
                    return@launch
                }
                if (!SshTunnelManager.isActive(TUNNEL_ID)) {
                    publish(_state.value.copy(tunnelHost = srv.name, tunnelPort = next.tunnelPort, tunnelUp = false))
                    try {
                        val creds = HostCredentials.build(repository, srv, posixShell = false)
                        SshTunnelManager.start(TUNNEL_ID, creds, "remote", "127.0.0.1", next.tunnelPort, "127.0.0.1", next.port)
                        publish(_state.value.copy(tunnelHost = srv.name, tunnelPort = next.tunnelPort, tunnelUp = true, problem = null))
                    } catch (e: Exception) {
                        if (e is CancellationException) throw e
                        publish(
                            _state.value.copy(
                                tunnelHost = srv.name, tunnelUp = false,
                                problem = getString(R.string.mcp_tunnel_failed, srv.name, e.message.orEmpty().take(160)),
                            ),
                        )
                    }
                }
                delay(TUNNEL_RETRY_MS)
            }
        }
    }

    private val handler by lazy {
        McpHandler(
            serverName = "omniterm",
            serverTitle = "OmniTerm",
            serverVersion = BuildConfig.VERSION_NAME,
            instructions = getString(R.string.mcp_server_instructions),
            tools = { McpTools(backend).all() },
            onCall = { caller, tool, result ->
                repository.recordMcpCall(
                    McpCallEntity(
                        at = System.currentTimeMillis(),
                        client = caller.clientName,
                        tool = tool,
                        outcome = if (result.isError) McpCallOutcome.FAILED else McpCallOutcome.OK,
                        detail = result.text.lineSequence().firstOrNull().orEmpty().take(160),
                    ),
                )
            },
        )
    }

    private fun recordRefused(status: Int) {
        val now = System.currentTimeMillis()
        if (now - lastRefusedRecord < REFUSED_RECORD_GAP_MS) return
        lastRefusedRecord = now
        scope.launch {
            repository.recordMcpCall(
                McpCallEntity(
                    at = now, client = "", tool = "", outcome = McpCallOutcome.REFUSED,
                    detail = getString(if (status == 401) R.string.mcp_refused_token else R.string.mcp_refused_origin),
                ),
            )
        }
    }

    private val backend by lazy { AppMcpBackend(applicationContext, repository, transport) { config } }

    private fun publish(next: McpServerState) {
        _state.value = next
        if (next.running || next.problem != null) {
            runCatching { getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(next)) }
        }
    }

    private fun startInForeground(state: McpServerState) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.mcp_server_channel), NotificationManager.IMPORTANCE_LOW),
            )
        }
        val n = notification(state)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun notification(state: McpServerState): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, McpService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = when {
            state.problem != null -> state.problem
            state.tunnelHost != null && state.tunnelUp -> getString(R.string.mcp_notification_via, state.tunnelHost, state.tunnelPort ?: 0)
            state.port != null -> getString(R.string.mcp_notification_local, state.port)
            else -> getString(R.string.mcp_notification_starting)
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentTitle(getString(R.string.mcp_notification_title))
            .setContentText(text)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .addAction(0, getString(R.string.mcp_turn_off), stop)
            .build()
    }

    override fun onDestroy() {
        McpApprovals.denyAll()
        server?.stop()
        server = null
        SshTunnelManager.stop(TUNNEL_ID)
        scope.cancel()
        _state.value = McpServerState()
        super.onDestroy()
    }
}
