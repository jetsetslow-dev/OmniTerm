package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.tunnel.CurrentWifi
import com.jetsetslow.omniterm.data.tunnel.HostRoute
import com.jetsetslow.omniterm.data.tunnel.TunnelNetworks
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * A tunnel that is not needed on some Wi-Fi: on a network the user named, its hosts are dialled
 * directly at their own address; anywhere else, and whenever the phone cannot tell where it is,
 * they go through the tunnel, as a host with a tunnel always did.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TunnelNetworkRouteRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    private val application: Application get() = ApplicationProvider.getApplicationContext()

    @Test
    fun onANamedWifiTheHostIsDialledDirectlyAndAnywhereElseThroughItsTunnel() = assertWifiRoute(TunnelKinds.WIREGUARD)

    @Test
    fun nebulaUsesTheSameWifiRuleAndFailsClosedWhenTheNameIsUnknown() = assertWifiRoute(TunnelKinds.NEBULA)

    @Test fun accessUsesTheSameWifiRuleAndFailsClosedWhenTheNameIsUnknown() = assertWifiRoute(TunnelKinds.CLOUDFLARE_ACCESS)

    private fun assertWifiRoute(kind: String) = withTunnels { repository ->
        val home = repository.insertTunnel(TunnelEntity(name = "Home", kind = kind, config = CONF, directWifi = TunnelNetworks.stored(listOf("Home", "Office"))))
        val nas = host("nas", tunnelId = home, tunnelHost = "10.9.0.7")

        at("Home")
        val direct = HostCredentials.build(repository, nas, posixShell = true)
        assertNull("on the home Wi-Fi the tunnel is not used", direct.tunnelId)
        assertEquals("nor the address inside it", "", direct.tunnelHost)
        assertEquals("the host's own address is dialled", "nas.lan", direct.host)
        assertNull(HostRoute.tunnelNow(repository, home))

        for (elsewhere in listOf("Cafe", "home", null)) {
            at(elsewhere)
            val tunnelled = HostCredentials.build(repository, nas, posixShell = true)
            assertEquals("on $elsewhere the host goes through its tunnel", home, tunnelled.tunnelId)
            assertEquals("10.9.0.7", tunnelled.tunnelHost)
            assertEquals(home, HostRoute.tunnelNow(repository, home))
        }
    }

    @Test
    fun aTunnelThatNamesNoWifiIsAlwaysUsedAndOneThatIsGoneNeverTurnsDirect() = withTunnels { repository ->
        val always = repository.insertTunnel(TunnelEntity(name = "Always", config = CONF))
        at("Home")
        assertEquals(always, HostCredentials.build(repository, host("pi", tunnelId = always), posixShell = true).tunnelId)
        assertEquals("a host whose tunnel was deleted fails, it does not go direct", 999, HostRoute.tunnelNow(repository, 999))
        assertEquals(999, HostCredentials.build(repository, host("stranded", tunnelId = 999), posixShell = true).tunnelId)
        assertNull("a host without a tunnel is direct, as before", HostCredentials.build(repository, host("router", tunnelId = null), posixShell = true).tunnelId)
    }

    @Test
    fun changingTheListMovesTheHostsFromTheNextConnection() = withTunnels { repository ->
        val home = repository.insertTunnel(TunnelEntity(name = "Home", config = CONF))
        at("Home")
        assertEquals(home, HostRoute.tunnelNow(repository, home))
        repository.updateTunnel(home, "Home", config = null, directWifi = TunnelNetworks.stored(listOf("Home")))
        assertNull(HostRoute.tunnelNow(repository, home))
        assertEquals("its configuration, with its key, is untouched", CONF, repository.getTunnel(home)!!.config)
        repository.updateTunnel(home, "Home", config = null, directWifi = "")
        assertEquals(home, HostRoute.tunnelNow(repository, home))
    }

    @Test
    fun joiningOrLeavingANamedWifiDropsWhatWasKeptOverTheOtherRoute() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val db = AppDatabase.getDatabase(application)
        val repository = AppRepository(db)
        val transport = ForgetfulTransport()
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            CurrentWifi.set(CurrentWifi.State())
            val home = repository.insertTunnel(TunnelEntity(name = "Home", config = CONF, directWifi = "Home"))
            val always = repository.insertTunnel(TunnelEntity(name = "Always", config = CONF))
            val nas = repository.insertServer(host("nas", tunnelId = home, tunnelHost = "10.9.0.7")).toInt()
            repository.insertServer(host("pi", tunnelId = always))
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("route", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == nas } }

            // Home: the tunnel is not needed, so what nas kept through it goes. pi's tunnel names no Wi-Fi.
            CurrentWifi.set(CurrentWifi.State(onWifi = true, name = "Home"))
            withTimeout(10_000) { while (transport.forgotten.isEmpty()) delay(20) }
            assertEquals(listOf(Triple("nas.lan", home, "10.9.0.7")), transport.forgotten.map { Triple(it.host, it.tunnelId, it.tunnelHost) })

            // Out again: what it kept directly goes, and it is back on its tunnel.
            transport.forgotten.clear()
            CurrentWifi.set(CurrentWifi.State(onWifi = true, name = "Cafe"))
            withTimeout(10_000) { while (transport.forgotten.isEmpty()) delay(20) }
            assertEquals(listOf(Triple("nas.lan", null, "")), transport.forgotten.map { Triple(it.host, it.tunnelId, it.tunnelHost) })

            // From one network no tunnel names to another: nothing moves.
            transport.forgotten.clear()
            CurrentWifi.set(CurrentWifi.State(onWifi = false))
            delay(500)
            assertTrue(transport.forgotten.toString(), transport.forgotten.isEmpty())
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                CurrentWifi.set(CurrentWifi.State())
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** Answers nothing, and records which kept connections the app let go of. */
    private class ForgetfulTransport : SshTransport {
        val forgotten = CopyOnWriteArrayList<SshCredentials>()

        override fun forgetCredentials(creds: SshCredentials) {
            forgotten.add(creds)
        }

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(creds: SshCredentials, command: String, stdin: String?, onChunk: suspend (String) -> Unit): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)?): TerminalSession =
            error("no terminal is opened here")
    }

    private fun at(wifi: String?) {
        HostRoute.wifiName = { wifi }
    }

    private fun host(name: String, tunnelId: Int?, tunnelHost: String = "") = ServerEntity(
        name = name, host = "$name.lan", port = 22, username = "admin", authType = "password",
        authPassword = "pw-$name", tunnelId = tunnelId, tunnelHost = tunnelHost,
    )

    private fun withTunnels(block: suspend (AppRepository) -> Unit) = runBlocking {
        val db = AppDatabase.getDatabase(application)
        val phones = HostRoute.wifiName
        withContext(Dispatchers.IO) { db.clearAllTables() }
        try {
            block(AppRepository(db))
        } finally {
            HostRoute.wifiName = phones
            withContext(Dispatchers.IO) { db.clearAllTables() }
        }
    }

    private companion object {
        const val CONF = "[Interface]\nPrivateKey = a-private-key-for-the-test\n"
    }
}
