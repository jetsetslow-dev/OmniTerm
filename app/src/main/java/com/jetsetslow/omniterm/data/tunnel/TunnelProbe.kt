package com.jetsetslow.omniterm.data.tunnel

import com.jetsetslow.omniterm.data.TunnelKinds
import java.io.File
import java.io.IOException

/** An unsaved Nebula configuration can be tested without storing its identity or keeping it up. */
internal object TunnelProbe {
    /**
     * Connects to [host]:[port] through [config]. Returns true when it went through a tunnel that
     * already runs [config], which keeps running: a second node with its Nebula address would take
     * its place at its peers and drop its connections. Otherwise a test tunnel starts and stops again.
     */
    fun nebula(config: String, host: String, port: Int, engine: TunnelEngine = GoTunnelEngine): Boolean {
        if (port !in 1..65535) throw IOException("The port must be from 1 to 65535.")
        if (host.isBlank()) throw IOException("Enter the host's Nebula address to test.")
        engine.check(TunnelKinds.NEBULA, config)?.let { throw IOException(it) }
        TunnelManager.runningAs(TunnelKinds.NEBULA, config, engine.node(TunnelKinds.NEBULA, config))?.let { id ->
            TunnelManager.dial(id, host.trim(), port, TIMEOUT_MS, TunnelUse.OTHER).close()
            return true
        }
        tcp(TunnelKinds.NEBULA, config, host, port, engine)
        return false
    }

    fun access(config: String, host: String, engine: TunnelEngine = GoTunnelEngine) {
        engine.check(TunnelKinds.CLOUDFLARE_ACCESS, config)?.let { throw IOException(it) }
        tcp(TunnelKinds.CLOUDFLARE_ACCESS, config, host, 22, engine)
    }

    private fun tcp(kind: String, config: String, host: String, port: Int, engine: TunnelEngine) {
        val node = object : TunnelNode {
            override val scratch: File get() = error("This probe does not write node state")
            override fun load(): String = error("This probe does not read node state")
            override fun save(state: String) = error("This probe does not write node state")
        }
        // The phone's own DNS, as a saved tunnel's start uses, for static endpoints given by name.
        val tunnel = engine.start(kind, config, ::systemResolve, node)
        try {
            tunnel.dial(host.trim(), port, TIMEOUT_MS).close()
        } finally {
            tunnel.close()
        }
    }

    private const val TIMEOUT_MS = 10_000
}
