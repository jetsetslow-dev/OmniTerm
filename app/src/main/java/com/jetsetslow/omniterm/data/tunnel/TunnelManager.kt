package com.jetsetslow.omniterm.data.tunnel

import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.TunnelEntity
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
    private var watcher: Job? = null

    private class Running(val tunnel: RunningTunnel, val fingerprint: String) {
        @Volatile var lastUsed: Long = 0
    }

    private val running = ConcurrentHashMap<Int, Running>()
    private val locks = ConcurrentHashMap<Int, Any>()
    private val _statuses = MutableStateFlow<Map<Int, TunnelStatus>>(emptyMap())

    /** The tunnels that are up, by id. */
    val statuses: StateFlow<Map<Int, TunnelStatus>> = _statuses.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Reads tunnels from [repository], and from then on refreshes their status and stops idle ones.
     * Every connection to a host is built from the repository (HostCredentials.build), which calls
     * this, so terminals, background checks, automation and the MCP server all find their tunnel.
     */
    @Synchronized
    fun attach(repository: AppRepository) {
        source = { repository.getTunnel(it) }
        if (watcher?.isActive == true) return
        watcher = scope.launch {
            while (isActive) {
                delay(STATUS_EVERY_MS)
                stopIdle()
                refresh()
            }
        }
    }

    internal fun attachSource(lookup: suspend (Int) -> TunnelEntity?) {
        source = lookup
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
            return run.tunnel.dial(host, port, timeoutMs)
        } finally {
            run.lastUsed = clock()
            refresh()
        }
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
        val tunnel = try {
            engine.start(entity.kind, entity.config, ::systemResolve)
        } catch (e: IOException) {
            throw IOException("Tunnel \"${entity.name}\" could not start: ${e.message}", e)
        }
        Running(tunnel, fingerprint).also {
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
        _statuses.value = running.mapValues { (_, run) ->
            val t = run.tunnel
            TunnelStatus(t.connections, t.lastHandshake, t.bytesIn, t.bytesOut)
        }
    }

    private fun fingerprint(entity: TunnelEntity): String =
        MessageDigest.getInstance("SHA-256").digest("${entity.kind}\n${entity.config}".toByteArray())
            .joinToString("") { "%02x".format(it) }

    /** A tunnel nothing has used for this long is taken down. */
    const val IDLE_STOP_MS = 5 * 60_000L
    private const val STATUS_EVERY_MS = 5_000L
}
