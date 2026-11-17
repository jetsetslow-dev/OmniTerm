package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.SnmpDeviceEntity
import com.jetsetslow.omniterm.data.SnmpDevices
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.tunnel.HostRoute
import com.jetsetslow.omniterm.data.tunnel.TunnelNetworks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupContents
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.MISSING_TUNNEL_ID
import com.jetsetslow.omniterm.ui.backupServerExtras
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.ExecutorCoroutineDispatcher
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
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.concurrent.Executors

/**
 * SNMP devices as saved and polled by the app: secrets encrypted at rest, a device behind a tunnel
 * never polled directly (SNMP is UDP, tunnels carry TCP), and devices carried by an encrypted
 * backup with their tunnels.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class SnmpDevicesRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aDeviceBehindItsTunnelIsNeverPolledDirectlyButIsOnTheTunnelsOwnWifi() = withModel { repo, model, _ ->
        val home = repo.insertTunnel(TunnelEntity(name = "Home", config = WG, directWifi = TunnelNetworks.stored(listOf("Home WiFi"))))
        DatagramSocket(0, InetAddress.getByName("127.0.0.1")).use { listener ->
            listener.soTimeout = 1_000
            val device = SnmpDeviceEntity(name = "switch", host = "127.0.0.1", port = listener.localPort, community = COMMUNITY, tunnelId = home)
            val previous = HostRoute.wifiName
            try {
                HostRoute.wifiName = { "Café" }
                assertEquals(SnmpDevices.Outcome.Failed(SnmpDevices.NOT_THROUGH_TUNNEL), model.snmpOutcome(device))
                assertNull("nothing was sent", receive(listener))
                assertEquals("a tunnel that is gone stays the answer", SnmpDevices.Outcome.Failed(SnmpDevices.NOT_THROUGH_TUNNEL), model.snmpOutcome(device.copy(tunnelId = MISSING_TUNNEL_ID)))
                assertNull(receive(listener))

                // On the Wi-Fi the tunnel goes direct on, it is polled like a device with no tunnel.
                HostRoute.wifiName = { "Home WiFi" }
                listener.soTimeout = 8_000
                val outcome = model.snmpOutcome(device)
                assertTrue(outcome.toString(), (outcome as SnmpDevices.Outcome.Failed).reason.startsWith("no answer"))
                assertTrue("polled directly there", receive(listener) != null)
            } finally {
                HostRoute.wifiName = previous
            }
        }
    }

    @Test
    fun devicesAreStoredEncryptedAndTravelInAnEncryptedBackupWithTheirTunnels() = withModel { repo, model, main ->
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val home = repo.insertTunnel(TunnelEntity(name = "Home", config = WG))
        repo.insertSnmpDevice(SnmpDeviceEntity(name = "core switch", host = "192.0.2.10", community = COMMUNITY, tunnelId = home))
        repo.insertSnmpDevice(
            SnmpDeviceEntity(name = "ups", host = "192.0.2.11", port = 1161, version = 3, user = "monitor",
                authProtocol = "SHA-256", authPassword = AUTH, privProtocol = "AES", privPassword = PRIV),
        )
        repo.insertSnmpDevice(SnmpDeviceEntity(name = "stranded", host = "192.0.2.12", community = COMMUNITY, tunnelId = 999))
        val raw = withContext(Dispatchers.IO) { db.snmpDeviceDao().getAllSnmpDevices() }
        val stored = raw.associateBy { it.name }
        val secrets = listOf(stored.getValue("core switch").community, stored.getValue("ups").authPassword, stored.getValue("ups").privPassword)
        assertTrue("stored encrypted", secrets.all { it.startsWith("enc:") })
        assertTrue(raw.none { d -> COMMUNITY in d.community || AUTH in d.authPassword || PRIV in d.privPassword })
        assertEquals(AUTH, repo.getAllSnmpDevices().single { it.name == "ups" }.authPassword)
        assertEquals("a tunnel a device uses is not deleted", listOf("core switch"), repo.deleteTunnel(home))

        val uri = Uri.parse("content://backup-fixture/snmp.json")
        val bytes = ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val exported = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.exportBackup(uri, PASSPHRASE, application, SELECTION) { ok, message -> exported.complete(ok to message) } }
        val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
        assertTrue(exportMessage, exportOk)
        waitWhileOnMain(main) { model.backupExportRunning }
        val backup = bytes.toString(Charsets.UTF_8)
        assertTrue("encrypted", JSONObject(backup).has("data"))
        assertTrue("no secret in the clear", listOf(COMMUNITY, AUTH, PRIV).none { it in backup })
        val inspected = CompletableDeferred<BackupContents?>()
        withContext(main) { model.inspectBackupContents(backup, PASSPHRASE) { _, contents, _ -> inspected.complete(contents) } }
        val contents = requireNotNull(withTimeout(10_000) { inspected.await() })
        assertEquals(3, contents.snmpDevices)
        assertTrue(backupServerExtras(contents).toString(), "3 SNMP devices" in backupServerExtras(contents).orEmpty())

        withContext(Dispatchers.IO) { db.clearAllTables() }
        val restored = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> restored.complete(ok to message) } }
        val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
        assertTrue(restoreMessage, restoreOk)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        assertTrue(restoreMessage, "3 SNMP device(s)" in restoreMessage)
        val devices = repo.getAllSnmpDevices().associateBy { it.name }
        val restoredHome = repo.getAllTunnels().single { it.name == "Home" }
        assertEquals("back through its own tunnel", restoredHome.id, devices.getValue("core switch").tunnelId)
        assertEquals(COMMUNITY, devices.getValue("core switch").community)
        val ups = devices.getValue("ups")
        assertEquals(listOf(3, 1161, "monitor", "SHA-256", AUTH, "AES", PRIV), listOf(ups.version, ups.port, ups.user, ups.authProtocol, ups.authPassword, ups.privProtocol, ups.privPassword))
        assertNull(ups.tunnelId)
        assertEquals("a missing tunnel stays missing, never direct", MISSING_TUNNEL_ID, devices.getValue("stranded").tunnelId)

        // Restoring again adds nothing.
        val again = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> again.complete(ok to message) } }
        assertTrue(withTimeout(10_000) { again.await() }.first)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        assertEquals(3, repo.getAllSnmpDevices().size)
    }

    private fun receive(socket: DatagramSocket): ByteArray? = try {
        val packet = DatagramPacket(ByteArray(2048), 2048)
        socket.receive(packet)
        packet.data.copyOf(packet.length)
    } catch (_: SocketTimeoutException) {
        null
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
            store.put("snmp", model)
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
        const val COMMUNITY = "fixture-community-7"
        const val AUTH = "fixture-auth-pass"
        const val PRIV = "fixture-priv-pass"
        const val PASSPHRASE = "snmp-backup-passphrase"
        const val WG = "[Interface]\nPrivateKey = snmp-tunnel-key-for-the-test\n"
        val SELECTION = BackupSelection.NONE.copy(servers = true)
    }
}
