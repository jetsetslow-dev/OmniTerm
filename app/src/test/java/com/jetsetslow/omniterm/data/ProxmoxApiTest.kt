package com.jetsetslow.omniterm.data

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jetsetslow.omniterm.data.tunnel.GoTunnelEngine
import com.jetsetslow.omniterm.data.tunnel.RunningTunnel
import com.jetsetslow.omniterm.data.tunnel.TunnelEngine
import com.jetsetslow.omniterm.data.tunnel.TunnelLink
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelNode
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import kotlin.concurrent.thread

/**
 * The Proxmox client against an in-process HTTPS server with its own self-signed certificate, as a
 * Proxmox node has: the certificate is trusted only once its fingerprint is, the token goes only in
 * its header, actions wait for their task, and a server behind a tunnel is dialled only through it.
 */
class ProxmoxApiTest {
    private data class Seen(val method: String, val path: String, val query: String?, val auth: String?, val body: String)

    private val seen = Collections.synchronizedList(mutableListOf<Seen>())
    private var taskPolls = AtomicInteger()
    private var taskExit = "OK"
    private lateinit var https: HttpsServer

    @Before
    fun startServer() {
        https = HttpsServer.create(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0)
        https.httpsConfigurator = HttpsConfigurator(serverContext)
        https.createContext("/") { exchange -> exchange.use { answer(it) } }
        https.start()
    }

    @After
    fun stopServer() {
        https.stop(0)
        TunnelManager.stopAll()
        TunnelManager.engine = GoTunnelEngine
    }

    private fun answer(exchange: HttpExchange) {
        val body = exchange.requestBody.readBytes().decodeToString()
        val path = exchange.requestURI.rawPath
        seen += Seen(exchange.requestMethod, path, exchange.requestURI.rawQuery, exchange.requestHeaders.getFirst("Authorization"), body)
        val auth = exchange.requestHeaders.getFirst("Authorization")
        if (auth != "PVEAPIToken=$TOKEN_ID=$SECRET") return reply(exchange, 401, "{\"data\":null}")
        val data = when {
            path == "/api2/json/version" -> """{"version":"8.4.1"}"""
            path == "/api2/json/behind-a-login-page" -> return reply(exchange, 200, "<html>Sign in</html>")
            path == "/api2/json/nodes" -> """[{"node":"pve1","status":"online","cpu":0.25,"maxcpu":8,"mem":2147483648,"maxmem":8589934592,"uptime":7200},{"node":"pve2","status":"offline"}]"""
            path == "/api2/json/cluster/resources" -> """[{"id":"qemu/100","vmid":100,"type":"qemu","name":"web","node":"pve1","status":"running","cpu":0.5,"maxcpu":2,"mem":1073741824,"maxmem":4294967296,"uptime":60,"template":0},
                {"id":"lxc/200","vmid":200,"type":"lxc","name":"dns","node":"pve1","status":"stopped","template":0},
                {"id":"storage/pve1/local","type":"storage","node":"pve1"}]"""
            path == "/api2/json/nodes/pve1/tasks" -> """[{"upid":"UPID:pve1:1:2:3:vzdump:100:root@pam:","node":"pve1","type":"vzdump","id":"100","user":"root@pam","starttime":1762905600,"endtime":1762905900,"status":"OK"},
                {"upid":"UPID:pve1:1:2:4:vzdump:200:root@pam:","node":"pve1","type":"vzdump","id":"200","user":"root@pam","starttime":1762909200,"endtime":1762909230,"status":"ERROR: storage is not online"}]"""
            path.startsWith("/api2/json/nodes/pve1/tasks/UPID:") && path.endsWith("/status") ->
                if (taskPolls.incrementAndGet() < 2) """{"status":"running"}""" else """{"status":"stopped","exitstatus":"$taskExit"}"""
            path == "/api2/json/nodes/pve1/qemu/100/snapshot" && exchange.requestMethod == "GET" ->
                """[{"name":"older","snaptime":1000,"description":"first\n"},{"name":"newer","snaptime":2000,"description":""},{"name":"current","description":"You are here!"}]"""
            exchange.requestMethod != "GET" -> "\"UPID:pve1:00000001:00000002:00000003:qmstop:100:$TOKEN_ID:\""
            else -> return reply(exchange, 501, "{\"data\":null}")
        }
        reply(exchange, 200, "{\"data\":$data}")
    }

    private fun reply(exchange: HttpExchange, code: Int, body: String) {
        val bytes = body.toByteArray()
        exchange.sendResponseHeaders(code, bytes.size.toLong())
        exchange.responseBody.write(bytes)
    }

    private fun server(fingerprint: String = FINGERPRINT, host: String = "127.0.0.1", port: Int = https.address.port, tunnelHost: String = "") =
        ProxmoxServerEntity(name = "lab", host = host, port = port, tokenId = TOKEN_ID, tokenSecret = SECRET, fingerprint = fingerprint, tunnelHost = tunnelHost)

    private fun api(server: ProxmoxServerEntity, tunnelId: Int? = null) = ProxmoxApi(OkHttpProxmoxTransport(server, tunnelId))

    private val guest = Proxmox.Guest("pve1", 100, "qemu", "web", "running", null, null, null, null, null, false)

    @Test
    fun aCertificateNotTrustedYetIsRefusedWithItsFingerprintBeforeAnyRequest() = runBlocking {
        val refused = runCatching { api(server(fingerprint = "")).overview() }.exceptionOrNull()
        assertThat(refused).isInstanceOf(ProxmoxUntrusted::class.java)
        val untrusted = refused as ProxmoxUntrusted
        assertThat(untrusted.fingerprint).isEqualTo(FINGERPRINT)
        assertThat(untrusted.changed).isFalse()
        assertWithMessage("no request reached the server, so the token went nowhere").that(seen).isEmpty()

        val changed = runCatching { api(server(fingerprint = "AB:".repeat(31) + "AB")).overview() }.exceptionOrNull()
        assertThat((changed as ProxmoxUntrusted).changed).isTrue()
        assertThat(seen).isEmpty()
    }

    @Test
    fun theTrustedCertificateReadsTheServerWithTheTokenInItsHeaderOnly() = runBlocking {
        val overview = api(server(fingerprint = FINGERPRINT.lowercase().replace(":", ""))).overview()
        assertThat(overview.version).isEqualTo("8.4.1")
        assertThat(overview.nodes.map { it.name to it.online }).containsExactly("pve1" to true, "pve2" to false).inOrder()
        assertThat(overview.nodes[0].memTotal).isEqualTo(8589934592L)
        assertThat(overview.guests.map { it.label }).containsExactly("VM 100 (web)", "CT 200 (dns)").inOrder()
        assertThat(overview.guests[0].cpu).isWithin(0.001f).of(0.5f)
        assertThat(overview.backups.map { it.id to it.ok }).containsExactly("200" to false, "100" to true).inOrder()
        assertWithMessage("backup tasks are read from online nodes only").that(seen.map { it.path }).doesNotContain("/api2/json/nodes/pve2/tasks")
        assertThat(seen.single { it.path == "/api2/json/nodes/pve1/tasks" }.query).isEqualTo("typefilter=vzdump&limit=10")
        assertThat(seen.map { it.auth }.toSet()).containsExactly("PVEAPIToken=$TOKEN_ID=$SECRET")
        assertThat(seen.none { SECRET in it.path || SECRET in it.query.orEmpty() || SECRET in it.body }).isTrue()

        val snapshots = api(server()).snapshots(guest)
        assertThat(snapshots.map { it.name }).containsExactly("newer", "older").inOrder()
        assertThat(snapshots[1].description).isEqualTo("first")
    }

    @Test
    fun actionsGoToTheirEndpointsAndWaitForTheirTask() = runBlocking {
        val api = api(server())
        assertThat(api.power(guest, Proxmox.Power.STOP)).isEqualTo("OK")
        assertThat(seen.first().let { it.method to it.path }).isEqualTo("POST" to "/api2/json/nodes/pve1/qemu/100/status/stop")
        assertWithMessage("it waited for the task to end").that(taskPolls.get()).isEqualTo(2)

        seen.clear(); taskPolls.set(0)
        api.createSnapshot(guest, "before-upgrade", "  kernel 6.8 ")
        assertThat(seen.first().let { Triple(it.method, it.path, it.body) })
            .isEqualTo(Triple("POST", "/api2/json/nodes/pve1/qemu/100/snapshot", "snapname=before-upgrade&description=kernel%206.8"))

        seen.clear(); taskPolls.set(0)
        api.rollback(guest, "older")
        assertThat(seen.first().let { it.method to it.path }).isEqualTo("POST" to "/api2/json/nodes/pve1/qemu/100/snapshot/older/rollback")

        seen.clear(); taskPolls.set(0)
        api.deleteSnapshot(guest, "older")
        assertThat(seen.first().let { it.method to it.path }).isEqualTo("DELETE" to "/api2/json/nodes/pve1/qemu/100/snapshot/older")

        seen.clear(); taskPolls.set(0); taskExit = "can't lock file '/var/lock/qemu-server/lock-100.conf' - got timeout"
        val failed = assertThrows(ProxmoxException::class.java) { runBlocking { api.power(guest, Proxmox.Power.START) } }
        assertThat(failed.message).isEqualTo("The task failed: $taskExit")

        seen.clear()
        val badName = assertThrows(ProxmoxException::class.java) { runBlocking { api.createSnapshot(guest, "1st", "") } }
        assertThat(badName.message).contains("starting with a letter")
        assertWithMessage("a name Proxmox would refuse is not sent").that(seen).isEmpty()
    }

    @Test
    fun aWrongTokenAndTheServersRefusalsSayWhy() = runBlocking {
        val wrong = assertThrows(ProxmoxException::class.java) { runBlocking { api(server().copy(tokenSecret = "nope")).overview() } }
        assertThat(wrong.message).startsWith("Proxmox refused the token")
        val transport = OkHttpProxmoxTransport(server(), null)
        val notProxmox = assertThrows(ProxmoxException::class.java) { runBlocking { transport.call(ProxmoxTransport.Method.GET, listOf("behind-a-login-page")) } }
        assertThat(notProxmox.message).endsWith("did not answer as Proxmox VE does")
        val badHost = OkHttpProxmoxTransport(server(host = "a:b:c"), null)
        val unusable = assertThrows(ProxmoxException::class.java) { runBlocking { badHost.call(ProxmoxTransport.Method.GET, listOf("version")) } }
        assertThat(unusable.message).isEqualTo("a:b:c is not an address OmniTerm can connect to")
        assertThat(Proxmox.refusal(403, "Permission check failed (/vms/100, VM.PowerMgmt)", mapOf("data" to null)))
            .startsWith("The token may not do this: Permission check failed (/vms/100, VM.PowerMgmt).")
        assertThat(Proxmox.refusal(400, "Parameter verification failed.", mapOf("data" to null, "errors" to mapOf("snapname" to "invalid format\n"))))
            .isEqualTo("Proxmox answered 400 Parameter verification failed. (snapname: invalid format)")
        assertThat(Proxmox.problem(server().copy(tokenId = "root@pam"))).contains("user@pam!name")
        assertThat(Proxmox.problem(server().copy(tokenSecret = " "))).isNotNull()
        assertThat(Proxmox.problem(server())).isNull()
        for (host in listOf("192.168.1.10", "pve.lan", "pve-1.home.arpa.", "münchen.lan", "fd00::1", "[fd00::1]", "::ffff:192.0.2.1")) {
            assertWithMessage(host).that(Proxmox.problem(server(host = host))).isNull()
        }
        for (host in listOf("pve lan", "https://pve.lan", "pve.lan/api", "pve..lan", "-pve.lan", "pve.lan:8006", "user@pve")) {
            assertWithMessage(host).that(Proxmox.problem(server(host = host))).startsWith("Enter the server's address")
        }
        assertThat(Proxmox.snapshotNameProblem("current")).isNotNull()
        assertThat(Proxmox.snapshotNameProblem("pre_v2-1")).isNull()
    }

    @Test
    fun aServerBehindATunnelIsDialledOnlyThroughItAtItsTunnelAddress() = runBlocking {
        val dials = Collections.synchronizedList(mutableListOf<String>())
        TunnelManager.stopAll()
        TunnelManager.engine = object : TunnelEngine {
            override fun check(kind: String, config: String): String? = null
            override fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode) = object : RunningTunnel {
                override fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink {
                    dials += "$host:$port"
                    return SocketLink(Socket("127.0.0.1", https.address.port))
                }
                override val connections = 0
                override val lastHandshake = 1L
                override val bytesIn = 0L
                override val bytesOut = 0L
                override fun close() {}
            }
        }
        TunnelManager.attachSource({ TunnelEntity(id = 7, name = "Home", kind = TunnelKinds.WIREGUARD, config = "conf") })
        ServerSocket(0, 5, InetAddress.getByName("127.0.0.1")).use { direct ->
            val accepted = AtomicInteger()
            thread(isDaemon = true) { while (!direct.isClosed) runCatching { direct.accept().close(); accepted.incrementAndGet() } }
            // Its own name never resolves on the phone; through the tunnel it is dialled at 100.64.0.7.
            val behind = server(host = "pve.home.invalid", port = direct.localPort, tunnelHost = "100.64.0.7")
            assertThat(api(behind, 7).overview().version).isEqualTo("8.4.1")
            assertThat(dials.toSet()).containsExactly("100.64.0.7:${direct.localPort}")
            val viaOwnName = api(server(host = "127.0.0.1", port = direct.localPort), 7).overview()
            assertThat(viaOwnName.guests).hasSize(2)
            assertThat(dials.last()).isEqualTo("127.0.0.1:${direct.localPort}")
            Thread.sleep(200)
            assertWithMessage("nothing went to the server's address directly").that(accepted.get()).isEqualTo(0)
        }
    }

    private class SocketLink(val socket: Socket) : TunnelLink {
        override val input: InputStream get() = socket.getInputStream()
        override val output: OutputStream get() = socket.getOutputStream()
        override fun setReadTimeout(ms: Int) { socket.soTimeout = ms }
        override fun shutdownInput() = socket.shutdownInput()
        override fun shutdownOutput() = socket.shutdownOutput()
        override fun close() = socket.close()
    }

    companion object {
        private const val TOKEN_ID = "monitor@pve!phone"
        private const val SECRET = "5f1c0d1e-test-only-secret"
        private const val STORE_PASSWORD = "test-only"
        private lateinit var serverContext: SSLContext
        private lateinit var FINGERPRINT: String
        private lateinit var dir: File

        /** A self-signed certificate made with the JDK's keytool, as a Proxmox node makes its own. */
        @BeforeClass @JvmStatic
        fun makeCertificate() {
            dir = Files.createTempDirectory("pve-cert").toFile()
            val store = File(dir, "pve.p12")
            val keytool = File(System.getProperty("java.home"), "bin/keytool").path
            val made = ProcessBuilder(
                keytool, "-genkeypair", "-alias", "pve", "-keyalg", "RSA", "-keysize", "2048", "-validity", "30",
                "-dname", "CN=pve1.omniterm.invalid", "-storetype", "PKCS12", "-keystore", store.path,
                "-storepass", STORE_PASSWORD, "-keypass", STORE_PASSWORD,
            ).redirectErrorStream(true).start()
            check(made.waitFor() == 0) { made.inputStream.readBytes().decodeToString() }
            val keys = KeyStore.getInstance("PKCS12").apply { store.inputStream().use { load(it, STORE_PASSWORD.toCharArray()) } }
            FINGERPRINT = CertificateTrust.fingerprint(keys.getCertificate("pve") as X509Certificate)
            val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, STORE_PASSWORD.toCharArray()) }
            serverContext = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, null) }
        }

        @AfterClass @JvmStatic
        fun removeCertificate() {
            dir.deleteRecursively()
        }
    }
}
