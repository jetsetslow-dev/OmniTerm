package com.jetsetslow.omniterm.data.tunnel

import android.content.Context
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.TunnelEntity
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/** What the Tunnels screen shows for a tunnel that is up. */
data class TunnelStatus(
    val connections: Int,
    val lastHandshake: Long,
    val bytesIn: Long,
    val bytesOut: Long,
    /** One of [TunnelStates]; a tunnel that is up but not running (signing in) carries nothing. */
    val state: String = TunnelStates.RUNNING,
    /** The page to sign the tunnel in at, while it needs that. */
    val authUrl: String = "",
    /** The phone's own addresses inside the tunnel. */
    val addresses: String = "",
    /** What the user should know about the tunnel now, or "". */
    val problem: String = "",
)

/**
 * Runs the tunnels hosts go through. A tunnel starts when a connection first needs it and stops
 * once nothing has used it for [IDLE_STOP_MS]; while a terminal or a transfer is open through it,
 * it stays up. A tunnel whose configuration changed is restarted with the new one on its next use.
 */
object TunnelManager {
    @Volatile internal var engine: TunnelEngine = GoTunnelEngine
    @Volatile internal var clock: () -> Long = System::currentTimeMillis
    @Volatile private var source: (suspend (Int) -> TunnelEntity?) = { null }
    @Volatile private var nodes: NodeStates = NodeStates.NONE
    private var watcher: Job? = null

    private class Running(val tunnel: RunningTunnel, val fingerprint: String, val name: String = "") {
        @Volatile var lastUsed: Long = 0
    }

    private val running = ConcurrentHashMap<Int, Running>()
    private val locks = ConcurrentHashMap<Int, Any>()
    private val _statuses = MutableStateFlow<Map<Int, TunnelStatus>>(emptyMap())
    private val _problems = MutableStateFlow<Map<Int, String>>(emptyMap())

    /** The tunnels that are up, by id. */
    val statuses: StateFlow<Map<Int, TunnelStatus>> = _statuses.asStateFlow()

    /** Why each tunnel that last failed to start did, by id, until it starts or is stopped. */
    val problems: StateFlow<Map<Int, String>> = _problems.asStateFlow()

    /** Where a tunnel's node state is read and kept: the database, or a test's own. */
    internal class NodeStates(
        val load: suspend (Int) -> String,
        val save: suspend (Int, String) -> Unit,
        val scratch: (Int) -> File = TailscaleNetwork::scratch,
    ) {
        companion object {
            val NONE = NodeStates({ "" }, { _, _ -> })
        }
    }

    /**
     * Follows what tunnels depend on as the phone moves between networks: the Wi-Fi it is on
     * ([CurrentWifi]) and the interface its connections go over ([TailscaleNetwork]). Called from
     * every way into the app.
     */
    fun follow(context: Context) {
        CurrentWifi.start(context)
        TailscaleNetwork.start(context)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Reads tunnels from [repository], and from then on refreshes their status and stops idle ones.
     * Every connection to a host is built from the repository (HostCredentials.build), which calls
     * this, so terminals, background checks, automation and the MCP server all find their tunnel.
     */
    @Synchronized
    fun attach(repository: AppRepository) {
        source = { repository.getTunnel(it) }
        nodes = NodeStates(repository::tunnelNodeState, repository::saveTunnelNodeState)
        if (watcher?.isActive == true) return
        watcher = scope.launch {
            while (isActive) {
                delay(STATUS_EVERY_MS)
                stopIdle()
                refresh()
            }
        }
    }

    internal fun attachSource(lookup: suspend (Int) -> TunnelEntity?, states: NodeStates = NodeStates.NONE) {
        source = lookup
        nodes = states
    }

    /** What is wrong with [config], or null when it can be used. */
    fun check(kind: String, config: String): String? = engine.check(kind, config)

    /**
     * Connects to [host]:[port] through tunnel [tunnelId], starting it first if it is not up.
     * Blocks; call it from the thread that dials.
     */
    fun dial(tunnelId: Int, host: String, port: Int, timeoutMs: Int): TunnelLink {
        val run = runningFor(tunnelId)
        run.lastUsed = clock()
        try {
            // A tunnel that is up but not signed in fails closed here, whatever its kind.
            notRunning(run)?.let { throw IOException(it) }
            return run.tunnel.dial(host, port, timeoutMs)
        } finally {
            run.lastUsed = clock()
            refresh()
        }
    }

    /**
     * Brings tunnel [id] up without a connection, so a Tailscale tunnel can be signed in before a
     * host needs it. Blocks; throws what a dial would. Returns its status.
     */
    fun start(id: Int): TunnelStatus {
        val run = runningFor(id)
        run.lastUsed = clock()
        refresh()
        return status(run)
    }

    /** Why [run] carries no connection now, or null when it does. */
    private fun notRunning(run: Running): String? = when (run.tunnel.state) {
        TunnelStates.RUNNING -> null
        TunnelStates.NEEDS_LOGIN -> "Tunnel \"${run.name}\" is not signed in. Sign it in under Tools, VPN tunnels."
        TunnelStates.NEEDS_APPROVAL -> "Tunnel \"${run.name}\" is waiting for its tailnet's admin to approve this device."
        else -> "Tunnel \"${run.name}\" is not connected yet."
    }

    private fun runningFor(id: Int): Running = synchronized(locks.getOrPut(id) { Any() }) {
        val entity = runBlocking(Dispatchers.IO) { source(id) }
            ?: throw IOException("This host's tunnel no longer exists. Pick another in the host's settings.")
        val fingerprint = fingerprint(entity)
        running[id]?.let { current ->
            if (current.fingerprint == fingerprint) return current
            running.remove(id)
            current.tunnel.close()
        }
        val states = nodes
        val node = object : TunnelNode {
            override val scratch: File get() = states.scratch(id)
            override fun load(): String = runBlocking(Dispatchers.IO) { states.load(id) }
            override fun save(state: String) = runBlocking(Dispatchers.IO) { states.save(id, state) }
        }
        val tunnel = try {
            engine.start(entity.kind, entity.config, ::systemResolve, node)
        } catch (e: IOException) {
            val message = "Tunnel \"${entity.name}\" could not start: ${e.message}"
            _problems.value = _problems.value + (id to message)
            throw IOException(message, e)
        }
        _problems.value = _problems.value - id
        Running(tunnel, fingerprint, entity.name).also {
            it.lastUsed = clock()
            running[id] = it
            refresh()
        }
    }

    /** Takes tunnel [id] down, ending every connection through it. */
    fun stop(id: Int) {
        synchronized(locks.getOrPut(id) { Any() }) {
            running.remove(id)?.tunnel?.close()
        }
        _problems.value = _problems.value - id
        refresh()
    }

    fun stopAll() {
        running.keys.toList().forEach(::stop)
    }

    internal fun stopIdle() {
        val now = clock()
        running.entries.toList().forEach { (id, run) ->
            if (run.tunnel.connections == 0 && now - run.lastUsed >= IDLE_STOP_MS) {
                synchronized(locks.getOrPut(id) { Any() }) {
                    if (running[id] === run && run.tunnel.connections == 0) {
                        running.remove(id)
                        run.tunnel.close()
                    }
                }
            }
        }
        refresh()
    }

    internal fun refresh() {
        _statuses.value = running.mapValues { (_, run) -> status(run) }
    }

    private fun status(run: Running): TunnelStatus {
        val t = run.tunnel
        return TunnelStatus(t.connections, t.lastHandshake, t.bytesIn, t.bytesOut, t.state, t.authUrl, t.addresses, t.problem)
    }

    private fun fingerprint(entity: TunnelEntity): String =
        MessageDigest.getInstance("SHA-256").digest("${entity.kind}\n${entity.config}".toByteArray())
            .joinToString("") { "%02x".format(it) }

    /** A tunnel nothing has used for this long is taken down. */
    const val IDLE_STOP_MS = 5 * 60_000L
    private const val STATUS_EVERY_MS = 5_000L
}
