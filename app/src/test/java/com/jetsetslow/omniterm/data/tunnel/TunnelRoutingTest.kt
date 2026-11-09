package com.jetsetslow.omniterm.data.tunnel

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jcraft.jsch.JSchException
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.EndpointChecks
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.socketFactoryFor
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** Which way a host is dialled, and the tunnels' lifecycle, with a stand-in for the Go library. */
class TunnelRoutingTest {
    /** A TCP echo on loopback: "inside the tunnel" for the fake engine, or the host's direct address. */
    private class Echo : AutoCloseable {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val accepted = AtomicInteger()
        init {
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val s = runCatching { server.accept() }.getOrNull() ?: break
                    accepted.incrementAndGet()
                    thread(isDaemon = true) { s.use { runCatching { it.getInputStream().copyTo(it.getOutputStream()) } } }
                }
            }
        }
        val port get() = server.localPort

        /**
         * How many connections were accepted, once [count] were or [waitMs] passed. A connect returns
         * as soon as the system queues it, before this server's thread takes it, so reading [accepted]
         * at once raced that thread (and lost on a slow CI runner, PR #147).
         */
        fun acceptedOnce(count: Int, waitMs: Long = 5_000): Int {
            val deadline = System.nanoTime() + waitMs * 1_000_000
            while (accepted.get() < count && System.nanoTime() < deadline) Thread.sleep(10)
            return accepted.get()
        }

        /** Connections accepted after a short wait, so a stray one that is still queued is counted. */
        fun acceptedSoFar(): Int = acceptedOnce(1, waitMs = 300)

        override fun close() = server.close()
    }

    private class SocketLink(val socket: Socket) : TunnelLink {
        override val input: InputStream get() = socket.getInputStream()
        override val output: OutputStream get() = socket.getOutputStream()
        override fun setReadTimeout(ms: Int) { socket.soTimeout = ms }
        override fun shutdownInput() = socket.shutdownInput()
        override fun shutdownOutput() = socket.shutdownOutput()
        override fun close() = socket.close()
    }

    /** Dials everything at the echo, and records what it was asked for. */
    private inner class FakeEngine : TunnelEngine {
        val starts = mutableListOf<String>()
        val dials = mutableListOf<String>()
        var failStart: String? = null
        val open = mutableListOf<SocketLink>()
        var closed = 0
        override fun check(kind: String, config: String): String? = if (config == "bad") "Line 1: nope." else null
        override fun start(kind: String, config: String, resolve: (String) -> List<String>): RunningTunnel {
            failStart?.let { throw IOException(it) }
            starts += config
            return object : RunningTunnel {
                override fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink {
                    dials += "$host:$port/$timeoutMs"
                    if (host == "refused.inside") throw IOException("Connection refused through the tunnel")
                    return SocketLink(Socket("127.0.0.1", inside.port)).also { synchronized(open) { open += it } }
                }
                override val connections: Int get() = synchronized(open) { open.count { !it.socket.isClosed } }
                override val lastHandshake = 1L
                override val bytesIn = 2L
                override val bytesOut = 3L
                override fun close() { closed++ }
            }
        }
    }

    private val inside = Echo()
    private val engine = FakeEngine()
    private val tunnels = mutableMapOf<Int, TunnelEntity>()
    private var now = 1_000_000L

    @Before
    fun setUp() {
        TunnelManager.stopAll()
        TunnelManager.engine = engine
        TunnelManager.clock = { now }
        TunnelManager.attachSource { tunnels[it] }
        tunnels[1] = TunnelEntity(id = 1, name = "Home", kind = TunnelKinds.WIREGUARD, config = "conf-1")
    }

    @After
    fun tearDown() {
        TunnelManager.stopAll()
        TunnelManager.engine = GoTunnelEngine
        TunnelManager.clock = System::currentTimeMillis
        inside.close()
    }

    private fun roundTrip(socket: Socket): String {
        socket.getOutputStream().write("ping\n".toByteArray())
        return socket.getInputStream().bufferedReader().readLine()
    }

    @Test
    fun aHostWithATunnelIsDialledOnlyThroughIt() {
        Echo().use { direct ->
            val creds = SshCredentials("127.0.0.1", direct.port, "u", tunnelId = 1)
            val socket = socketFactoryFor(creds).createSocket(creds.host, creds.port)
            assertThat(roundTrip(socket)).isEqualTo("ping")
            socket.close()
            assertThat(engine.dials).containsExactly("127.0.0.1:${direct.port}/${TunnelSocket.DEFAULT_TIMEOUT_MS}")
            assertWithMessage("nothing reached the direct address").that(direct.acceptedSoFar()).isEqualTo(0)
        }
    }

    @Test
    fun aTunnelThatIsDownNeverFallsBackToTheDirectAddress() {
        Echo().use { direct ->
            engine.failStart = "The peer's Endpoint vpn.example could not be found."
            val creds = SshCredentials("127.0.0.1", direct.port, "u", tunnelId = 1)
            val e = assertThrows(JSchException::class.java) { socketFactoryFor(creds).createSocket(creds.host, creds.port) }
            assertThat(e.message).isEqualTo("Tunnel \"Home\" could not start: The peer's Endpoint vpn.example could not be found.")
            engine.failStart = null
            val refused = SshCredentials("refused.inside", direct.port, "u", tunnelId = 1)
            assertThrows(JSchException::class.java) { socketFactoryFor(refused).createSocket(refused.host, refused.port) }
            tunnels.remove(1)
            val gone = assertThrows(JSchException::class.java) { socketFactoryFor(creds).createSocket(creds.host, creds.port) }
            assertThat(gone.message).contains("no longer exists")
            assertWithMessage("a selected tunnel never goes direct").that(direct.acceptedSoFar()).isEqualTo(0)
        }
    }

    @Test
    fun aHostWithoutATunnelDialsDirectlyAsBefore() {
        Echo().use { direct ->
            val creds = SshCredentials("127.0.0.1", direct.port, "u")
            val socket = socketFactoryFor(creds).createSocket(creds.host, creds.port)
            assertThat(roundTrip(socket)).isEqualTo("ping")
            socket.close()
            assertThat(engine.starts).isEmpty()
            assertThat(direct.acceptedOnce(1)).isEqualTo(1)
        }
    }

    @Test
    fun theTunnelAddressReplacesOnlyTheHostsOwnName() {
        val creds = SshCredentials("nas.lan", 22, "u", tunnelId = 1, tunnelHost = " 100.64.0.7 ")
        socketFactoryFor(creds).createSocket("NAS.lan", 22).close()
        socketFactoryFor(creds).createSocket("bastion.example", 2222).close()
        assertThat(engine.dials.map { it.substringBefore('/') }).containsExactly("100.64.0.7:22", "bastion.example:2222").inOrder()
        assertThat(HostRoute.socketFactory("h", null, "x")).isNull()
    }

    @Test
    fun aTunnelStartsOnceRestartsOnANewConfigurationAndStopsWhenIdle() {
        val link = TunnelManager.dial(1, "10.0.0.5", 22, 1_000)
        TunnelManager.dial(1, "10.0.0.5", 22, 1_000).close()
        assertThat(engine.starts).containsExactly("conf-1")
        TunnelManager.refresh()
        assertThat(TunnelManager.statuses.value[1]?.connections).isEqualTo(1)

        now += TunnelManager.IDLE_STOP_MS * 2
        TunnelManager.stopIdle()
        assertWithMessage("an open connection keeps it up").that(TunnelManager.statuses.value).containsKey(1)

        link.close()
        TunnelManager.stopIdle()
        assertWithMessage("idle for long enough").that(TunnelManager.statuses.value).doesNotContainKey(1)
        assertThat(engine.closed).isEqualTo(1)

        TunnelManager.dial(1, "10.0.0.5", 22, 1_000).close()
        tunnels[1] = tunnels[1]!!.copy(config = "conf-2")
        TunnelManager.dial(1, "10.0.0.5", 22, 1_000).close()
        assertThat(engine.starts).containsExactly("conf-1", "conf-1", "conf-2").inOrder()
        assertThat(engine.closed).isEqualTo(2)
        now += TunnelManager.IDLE_STOP_MS - 1
        TunnelManager.stopIdle()
        assertWithMessage("not idle yet").that(TunnelManager.statuses.value).containsKey(1)
        TunnelManager.stop(1)
        assertThat(TunnelManager.statuses.value).isEmpty()
        assertThat(TunnelManager.check(TunnelKinds.WIREGUARD, "bad")).isEqualTo("Line 1: nope.")
    }

    @Test
    fun endpointChecksOfATunnelledHostGoThroughItOrDoNotRunAtAll() {
        Echo().use { direct ->
            val asked = mutableListOf<String>()
            val tunnel = { TunnelSocket { h, p, _ -> asked += "$h:$p"; SocketLink(Socket("127.0.0.1", inside.port)) } }
            fun rule(metric: String, target: String) =
                AlertRuleEntity(serverId = 1, metricName = metric, thresholdValue = 1f, severity = "WARNING", target = target)

            // The host's own port: through the tunnel, at the host's address inside it.
            val own = EndpointChecks.run(rule(EndpointChecks.TCP_PORT, "22"), "nas.lan", tunnel = tunnel, tunnelHost = "10.9.0.7")
            assertWithMessage(own.summary).that(own.value!!).isAtLeast(0f)
            assertThat(asked).containsExactly("10.9.0.7:22")

            // Ping cannot go through it yet, so the host is not pinged directly instead.
            val ping = EndpointChecks.run(rule(EndpointChecks.PING, ""), "nas.lan", tunnel = tunnel, tunnelHost = "10.9.0.7")
            assertThat(ping.value).isNull()
            assertThat(ping.summary).isEqualTo(EndpointChecks.NOT_THROUGH_TUNNEL)

            // Another address the rule names is checked as before, directly.
            val other = EndpointChecks.run(rule(EndpointChecks.TCP_PORT, "127.0.0.1:${direct.port}"), "nas.lan", tunnel = tunnel, tunnelHost = "10.9.0.7")
            assertWithMessage(other.summary).that(other.value!!).isAtLeast(0f)
            assertThat(asked).hasSize(1)
            assertThat(direct.acceptedOnce(1)).isEqualTo(1)
        }
    }

    @Test
    fun aPooledSessionIsNeverSharedAcrossRoutes() {
        val pool = com.jetsetslow.omniterm.data.ssh.SshSessionPool(connectTimeoutMs = 1_000)
        val direct = SshCredentials("nas.lan", 22, "u")
        val viaHome = direct.copy(tunnelId = 1)
        val keys = listOf(direct, viaHome, direct.copy(tunnelId = 2), viaHome.copy(tunnelHost = "10.9.0.7")).map(pool::key)
        assertWithMessage("a direct session, and each tunnel and address inside it, are separate").that(keys.toSet()).hasSize(4)
        assertThat(pool.key(viaHome.copy())).isEqualTo(pool.key(viaHome))
    }

    @Test
    fun aTunnelSocketBehavesAsASocketForTheClientsThatUseIt() {
        var asked: Triple<String, Int, Int>? = null
        var link: SocketLink? = null
        val socket = TunnelSocket { h, p, t -> asked = Triple(h, p, t); SocketLink(Socket("127.0.0.1", inside.port)).also { link = it } }
        assertThrows(SocketException::class.java) { socket.getInputStream() }
        socket.soTimeout = 700
        socket.tcpNoDelay = true
        socket.keepAlive = true
        socket.connect(InetSocketAddress.createUnresolved("box.lab", 2222), 4_000)
        assertThat(asked).isEqualTo(Triple("box.lab", 2222, 4_000))
        assertThat(link!!.socket.soTimeout).isEqualTo(700)
        assertThat(socket.isConnected).isTrue()
        assertThat(socket.port).isEqualTo(2222)
        assertThat(roundTrip(socket)).isEqualTo("ping")
        assertThrows(SocketException::class.java) { socket.connect(InetSocketAddress.createUnresolved("x", 1)) }
        socket.close()
        assertThat(socket.isClosed).isTrue()
        assertThat(link!!.socket.isClosed).isTrue()
        assertThrows(SocketException::class.java) { socket.getOutputStream() }
        val unset = TunnelSocket { h, p, t -> asked = Triple(h, p, t); SocketLink(Socket("127.0.0.1", inside.port)) }
        unset.connect(InetSocketAddress.createUnresolved("y", 1))
        assertWithMessage("no timeout given uses the dial default").that(asked!!.third).isEqualTo(TunnelSocket.DEFAULT_TIMEOUT_MS)
        unset.close()
    }
}
