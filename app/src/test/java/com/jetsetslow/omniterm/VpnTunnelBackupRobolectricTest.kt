package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.MISSING_TUNNEL_ID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
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
import java.util.concurrent.Executors

/**
 * VPN tunnels travel with the hosts that go through them. Restored on another phone, a host points
 * at its own tunnel again (under a free name when the phone has another tunnel of that name, or the
 * phone's own when it is the same), and a host whose tunnel is missing never turns into a direct one.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class VpnTunnelBackupRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun hostsKeepTheirTunnelsAcrossABackupAndNeverBecomeDirect() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val repo = AppRepository(db)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            val home = repo.insertTunnel(TunnelEntity(name = "Home", config = HOME))
            repo.insertTunnel(TunnelEntity(name = "Lab", config = LAB))
            repo.insertServer(host("nas", tunnelId = home, tunnelHost = "10.9.0.7"))
            repo.insertServer(host("router", tunnelId = null))
            // Already pointing at a tunnel that is gone (one restored without its tunnel, say).
            repo.insertServer(host("stranded", tunnelId = 999))

            val uri = Uri.parse("content://backup-fixture/tunnels.json")
            val bytes = ByteArrayOutputStream()
            shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
            val exported = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.exportBackup(uri, PASSPHRASE, application, SELECTION) { ok, message -> exported.complete(ok to message) } }
            val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
            assertTrue(exportMessage, exportOk)
            waitWhileOnMain(main) { model.backupExportRunning }
            val backup = bytes.toString(Charsets.UTF_8)
            assertTrue("tunnels hold private keys, so the backup is encrypted", JSONObject(backup).has("data"))
            assertTrue("no configuration in the clear", HOME !in backup && LAB !in backup)

            // Another phone: its own "Home" is a different tunnel; its "Lab" is the same one.
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val otherHome = repo.insertTunnel(TunnelEntity(name = "home", config = "[Interface]\n# another phone's\n"))
            val sameLab = repo.insertTunnel(TunnelEntity(name = "Lab", config = LAB))
            // The same machine and login, saved here directly: not the backup's copy through a tunnel.
            repo.insertServer(host("nas", tunnelId = null).copy(name = "nas here"))
            val restored = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> restored.complete(ok to message) } }
            val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
            assertTrue(restoreMessage, restoreOk)
            waitWhileOnMain(main) { model.backupRestoreRunning }

            val tunnels = repo.getAllTunnels()
            assertEquals(setOf("home", "Home (2)", "Lab"), tunnels.map { it.name }.toSet())
            val restoredHome = tunnels.single { it.name == "Home (2)" }
            assertEquals(HOME, restoredHome.config)
            assertEquals("the same Lab tunnel is not added twice", sameLab, tunnels.single { it.name == "Lab" }.id)
            val servers = repo.getAllServers().associateBy { it.name }
            assertEquals(restoredHome.id, servers.getValue("nas").tunnelId)
            assertNull("the direct copy stays as it was", servers.getValue("nas here").tunnelId)
            assertTrue(restoredHome.id != otherHome)
            assertEquals("10.9.0.7", servers.getValue("nas").tunnelHost)
            assertNull("a direct host stays direct", servers.getValue("router").tunnelId)
            assertEquals("a missing tunnel stays missing, never direct", MISSING_TUNNEL_ID, servers.getValue("stranded").tunnelId)

            // A tunnel a host goes through cannot be deleted; one no host uses can.
            assertEquals(listOf("nas"), repo.deleteTunnel(restoredHome.id))
            assertTrue(repo.getTunnel(restoredHome.id) != null)
            assertEquals(emptyList<String>(), repo.deleteTunnel(otherHome))
            assertNull(repo.getTunnel(otherHome))
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

    private fun host(name: String, tunnelId: Int?, tunnelHost: String = "") = ServerEntity(
        name = name, host = "$name.lan", port = 22, username = "admin", authType = "password",
        authPassword = "pw-$name", tunnelId = tunnelId, tunnelHost = tunnelHost,
    )

    private companion object {
        const val PASSPHRASE = "vpn-tunnel-passphrase"
        const val HOME = "[Interface]\nPrivateKey = home-private-key-for-the-test\n"
        const val LAB = "[Interface]\nPrivateKey = lab-private-key-for-the-test\n"
        val SELECTION = BackupSelection.NONE.copy(servers = true)
    }
}
