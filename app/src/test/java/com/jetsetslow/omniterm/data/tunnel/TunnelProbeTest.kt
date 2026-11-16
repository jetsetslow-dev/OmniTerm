package com.jetsetslow.omniterm.data.tunnel

import com.jetsetslow.omniterm.data.TunnelKinds
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelProbeTest {
    private class ProbeEngine(val kind: String = TunnelKinds.NEBULA, val host: String = "10.88.0.3") : TunnelEngine {
        var stopped = false
        var linkClosed = false
        var refused = false
        var checked = false
        override fun check(kind: String, config: String): String? {
            assertEquals(this.kind, kind)
            checked = true
            return if (config == "bad") "Import matching certificates." else null
        }
        override fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode): RunningTunnel {
            assertEquals(this.kind, kind)
            assertTrue(checked)
            // The phone's own DNS, for a Nebula static endpoint given by name; a numeric one needs none.
            assertEquals(listOf("127.0.0.1"), resolve("127.0.0.1"))
            return object : RunningTunnel {
                override val connections = 0
                override val lastHandshake = 0L
                override val bytesIn = 0L
                override val bytesOut = 0L
                override fun close() { stopped = true }
                override fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink {
                    assertEquals(this@ProbeEngine.host, host)
                    assertEquals(22, port)
                    if (refused) throw IOException("Refused through Nebula")
                    return object : TunnelLink {
                        override val input = ByteArrayInputStream(byteArrayOf())
                        override val output = ByteArrayOutputStream()
                        override fun setReadTimeout(ms: Int) = Unit
                        override fun shutdownInput() = Unit
                        override fun shutdownOutput() = Unit
                        override fun close() { linkClosed = true }
                    }
                }
            }
        }
    }

    @Test fun accessTestUsesOnlyTheSelectedHostnameAndClosesEverything() {
        val engine = ProbeEngine(TunnelKinds.CLOUDFLARE_ACCESS, "ssh.example.com")
        TunnelProbe.access("service token", "ssh.example.com", engine)
        assertTrue(engine.stopped && engine.linkClosed)
    }

    @Test fun aTestUsesNebulaAndClosesBothTheConnectionAndTunnel() {
        val engine = ProbeEngine()
        TunnelProbe.nebula("inline identity", "10.88.0.3", 22, engine)
        assertTrue(engine.stopped && engine.linkClosed)
    }

    @Test fun aRefusedConnectionStillStopsTheTestTunnel() {
        val engine = ProbeEngine().apply { refused = true }
        assertThrows(IOException::class.java) { TunnelProbe.nebula("inline identity", "10.88.0.3", 22, engine) }
        assertTrue(engine.stopped)
    }

    @Test fun anInvalidIdentityOrTargetNeverStarts() {
        val engine = ProbeEngine()
        assertThrows(IOException::class.java) { TunnelProbe.nebula("bad", "10.88.0.3", 22, engine) }
        assertThrows(IOException::class.java) { TunnelProbe.nebula("ok", "", 22, engine) }
        assertThrows(IOException::class.java) { TunnelProbe.nebula("ok", "10.88.0.3", 0, engine) }
        assertTrue(!engine.stopped)
    }
}
