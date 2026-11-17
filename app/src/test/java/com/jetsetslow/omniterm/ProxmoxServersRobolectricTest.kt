package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ProxmoxException
import com.jetsetslow.omniterm.data.ProxmoxServerEntity
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.tunnel.GoTunnelEngine
import com.jetsetslow.omniterm.data.tunnel.HostRoute
import com.jetsetslow.omniterm.data.tunnel.RunningTunnel
import com.jetsetslow.omniterm.data.tunnel.TunnelEngine
import com.jetsetslow.omniterm.data.tunnel.TunnelLink
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelNetworks
import com.jetsetslow.omniterm.data.tunnel.TunnelNode
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupContents
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.MISSING_TUNNEL_ID
import com.jetsetslow.omniterm.ui.backupServerExtras
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Proxmox servers as saved and reached by the app: the API token encrypted at rest, a server behind
 * a tunnel reached only through it (directly only on the Wi-Fi that tunnel goes direct on), its
 * tunnel kept while it is used, and servers carried by an encrypted backup with their tunnels and
 * trusted certificate.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class ProxmoxServersRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aServerBehindItsTunnelIsReachedOnlyThroughItButDirectlyOnTheTunnelsOwnWifi() = withModel { repo, model, _ ->
        val home = repo.insertTunnel(TunnelEntity(name = "Home", config = WG, directWifi = TunnelNetworks.stored(listOf("Home WiFi"))))
        val dials = Collections.synchronizedList(mutableListOf<String>())
        TunnelManager.stopAll()
        TunnelManager.engine = object : TunnelEngine {
            override fun check(kind: String, config: String): String? = null
            override fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode) = object : RunningTunnel {
                override fun dial(host: String, port: Int, timeoutMs: Int): TunnelLink {
                    dials += "$host:$port"
                    throw IOException("the test's tunnel carries nothing")
                }
                override val connections = 0
                override val lastHandshake = 1L
                override val bytesIn = 0L
                override val bytesOut = 0L
                override fun close() {}
            }
        }
        val previous = HostRoute.wifiName
        ServerSocket(0, 5, InetAddress.getByName("127.0.0.1")).use { direct ->
            val accepted = AtomicInteger()
            thread(isDaemon = true) { while (!direct.isClosed) runCatching { direct.accept().close(); accepted.incrementAndGet() } }
            val server = ProxmoxServerEntity(
                name = "lab", host = "127.0.0.1", port = direct.localPort, tokenId = TOKEN_ID, tokenSecret = SECRET,
                tunnelId = home, tunnelHost = "100.64.0.9",
            )
            try {
                HostRoute.wifiName = { "Café" }
                val away = runCatching { model.proxmoxApi(server).overview() }.exceptionOrNull()
                assertTrue(away.toString(), away is ProxmoxException && "carries nothing" in away.message.orEmpty())
                assertEquals("dialled through the tunnel at its tunnel address", setOf("100.64.0.9:${direct.localPort}"), dials.toSet())
                val gone = runCatching { model.proxmoxApi(server.copy(tunnelId = MISSING_TUNNEL_ID)).overview() }.exceptionOrNull()
                assertTrue(gone.toString(), "no longer exists" in gone?.message.orEmpty())
                Thread.sleep(200)
                assertEquals("nothing went direct, not even when its tunnel is gone", 0, accepted.get())

                // On the Wi-Fi the tunnel goes direct on, it is reached like a server with no tunnel.
                HostRoute.wifiName = { "Home WiFi" }
                val before = dials.size
                runCatching { model.proxmoxApi(server).overview() }
                val until = System.currentTimeMillis() + 5_000
                while (accepted.get() == 0 && System.currentTimeMillis() < until) Thread.sleep(50)
                assertTrue("reached directly there", accepted.get() > 0)
                assertEquals("and not through the tunnel", before, dials.size)
            } finally {
                HostRoute.wifiName = previous
                TunnelManager.stopAll()
                TunnelManager.engine = GoTunnelEngine
            }
        }
    }

    @Test
    fun serversAreStoredEncryptedKeepTheirTunnelAndTravelInAnEncryptedBackup() = withModel { repo, model, main ->
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val home = repo.insertTunnel(TunnelEntity(name = "Home", config = WG))
        repo.insertProxmoxServer(
            ProxmoxServerEntity(name = "lab", host = "pve.home.lan", tokenId = TOKEN_ID, tokenSecret = SECRET, fingerprint = FINGERPRINT,
                tunnelId = home, tunnelHost = "100.64.0.9", notes = "rack 1"),
        )
        repo.insertProxmoxServer(ProxmoxServerEntity(name = "edge", host = "192.0.2.20", port = 8443, tokenId = "audit@pve!phone", tokenSecret = SECRET2))
        repo.insertProxmoxServer(ProxmoxServerEntity(name = "stranded", host = "192.0.2.21", tokenId = TOKEN_ID, tokenSecret = SECRET, tunnelId = 999))
        val raw = withContext(Dispatchers.IO) { db.proxmoxServerDao().getAll() }
        assertTrue("stored encrypted", raw.all { it.tokenSecret.startsWith("enc:") })
        assertTrue(raw.none { SECRET in it.tokenSecret || SECRET2 in it.tokenSecret })
        assertEquals(SECRET2, repo.getAllProxmoxServers().single { it.name == "edge" }.tokenSecret)
        assertEquals("a tunnel a server uses is not deleted", listOf("lab"), repo.deleteTunnel(home))

        val uri = Uri.parse("content://backup-fixture/proxmox.json")
        val bytes = ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val exported = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.exportBackup(uri, PASSPHRASE, application, SELECTION) { ok, message -> exported.complete(ok to message) } }
        val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
        assertTrue(exportMessage, exportOk)
        waitWhileOnMain(main) { model.backupExportRunning }
        val backup = bytes.toString(Charsets.UTF_8)
        assertTrue("encrypted", JSONObject(backup).has("data"))
        assertTrue("no token in the clear", listOf(SECRET, SECRET2, TOKEN_ID).none { it in backup })
        val inspected = CompletableDeferred<BackupContents?>()
        withContext(main) { model.inspectBackupContents(backup, PASSPHRASE) { _, contents, _ -> inspected.complete(contents) } }
        val contents = requireNotNull(withTimeout(10_000) { inspected.await() })
        assertEquals(3, contents.proxmoxServers)
        assertTrue(backupServerExtras(contents).toString(), "3 Proxmox servers" in backupServerExtras(contents).orEmpty())

        withContext(Dispatchers.IO) { db.clearAllTables() }
        val restored = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> restored.complete(ok to message) } }
        val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
        assertTrue(restoreMessage, restoreOk)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        assertTrue(restoreMessage, "3 Proxmox server(s)" in restoreMessage)
        val servers = repo.getAllProxmoxServers().associateBy { it.name }
        val restoredHome = repo.getAllTunnels().single { it.name == "Home" }
        val lab = servers.getValue("lab")
        assertEquals("back through its own tunnel", restoredHome.id, lab.tunnelId)
        assertEquals(listOf("pve.home.lan", 8006, TOKEN_ID, SECRET, FINGERPRINT, "100.64.0.9", "rack 1"),
            listOf(lab.host, lab.port, lab.tokenId, lab.tokenSecret, lab.fingerprint, lab.tunnelHost, lab.notes))
        val edge = servers.getValue("edge")
        assertEquals(listOf(8443, SECRET2, ""), listOf(edge.port, edge.tokenSecret, edge.fingerprint))
        assertNull(edge.tunnelId)
        assertEquals("a missing tunnel stays missing, never direct", MISSING_TUNNEL_ID, servers.getValue("stranded").tunnelId)

        // Restoring again adds nothing.
        val again = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> again.complete(ok to message) } }
        assertTrue(withTimeout(10_000) { again.await() }.first)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        assertEquals(3, repo.getAllProxmoxServers().size)
    }

    private fun withModel(block: suspend (AppRepository, AppViewModel, ExecutorCoroutineDispatcher) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("proxmox", model)
            block(AppRepository(db), model, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private companion object {
        const val TOKEN_ID = "monitor@pve!phone"
        const val SECRET = "pve-fixture-secret"
        const val SECRET2 = "71c4a3b0-fixture-audit"
        const val FINGERPRINT = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        const val PASSPHRASE = "proxmox-backup-passphrase"
        const val WG = "[Interface]\nPrivateKey = proxmox-tunnel-key-for-the-test\n"
        val SELECTION = BackupSelection.NONE.copy(servers = true)
    }
}
