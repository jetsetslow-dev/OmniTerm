package com.jetsetslow.omniterm

import android.Manifest
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.tunnel.CurrentWifi
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Per-host VPN tunnels against the repository's WireGuard fixture (scripts/test-hosts, service
 * `wireguard`), the only way to reach internal-a from outside. As a user sets it up:
 * - a broken configuration is refused on the screen, the fixture's is saved;
 * - a host named internal-a.lab.vpn, found only by the tunnel's DNS, is reached through it;
 * - a host that answers directly, once its tunnel is picked, is never dialled directly again: not by
 *   a pooled session from before, and not when its tunnel cannot connect;
 * - on a Wi-Fi a tunnel is listed as not needed on, its host is reached directly, and off that
 *   list it is behind the tunnel again;
 * - a tunnel a host still uses cannot be deleted.
 * Run with `./scripts/test-hosts.sh suite E2eVpnTunnelTest omniterm_e2e_vpn=yes wg_client_key
 * wg_server_pub user pass`. Everything it adds is removed again.
 */
class E2eVpnTunnelTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun hostsBehindATunnelAreReachedThroughItAndNeverDirectly() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_vpn") == "yes")
        val clientKey = E2eArgs.require("wg_client_key")
        val serverPub = E2eArgs.require("wg_server_pub")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        fun has(tag: String) = composeRule.showsNode(hasTestTag(tag))
        val stamp = System.currentTimeMillis().toString().takeLast(6)
        val tunnelName = "E2E WireGuard $stamp"
        val conf = wireGuardConf(clientKey, serverPub, endpoint = "10.0.2.2:51820", dns = "10.77.0.1")
        val added = mutableListOf<Int>()

        fun broadcast(serverId: Int, command: String) = composeRule.tunnelBroadcast(vm, serverId, command)

        fun addHost(name: String, host: String, port: Int, tunnelId: Int?, tunnelHost: String = ""): Int {
            var error: String? = "pending"
            composeRule.runOnUiThread {
                vm.addServer(
                    name = name, host = host, port = port, username = user, group = "E2E", authType = "password",
                    notes = "", keepAlive = 30, compression = false, proxy = "", password = pass,
                    tunnelId = tunnelId, tunnelHost = tunnelHost,
                ) { error = it }
            }
            composeRule.waitUntil(15_000) { error != "pending" }
            assertEquals(null, error)
            composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == name } }
            return vm.servers.value.single { it.name == name }.id.also { added += it }
        }

        try {
            // Added on the screen: a broken configuration says why and cannot be saved.
            composeRule.runOnUiThread { vm.navigateTo(Screen.VpnTunnels) }
            composeRule.waitUntil(15_000) { has("vpn.add") }
            composeRule.onNodeWithTag("vpn.add").performClick()
            composeRule.waitUntil(10_000) { has("vpn.config") }
            composeRule.onNodeWithTag("vpn.name").performTextInput(tunnelName)
            composeRule.onNodeWithTag("vpn.config").performTextInput("[Interface]\nPrivateKey = not-a-key\n")
            composeRule.waitUntil(10_000) { has("vpn.check") }
            composeRule.onNodeWithTag("vpn.check").assert(hasText("Line 2: PrivateKey is not a WireGuard key.", substring = true))
            composeRule.onNodeWithTag("vpn.save").assertIsNotEnabled()
            composeRule.onNodeWithTag("vpn.config").performTextReplacement(conf)
            composeRule.waitUntil(10_000) { !has("vpn.check") }
            composeRule.onNodeWithTag("vpn.save").performClick()
            composeRule.waitUntil(15_000) { vm.tunnels.value.any { it.name == tunnelName } }
            val tunnel: TunnelEntity = vm.tunnels.value.single { it.name == tunnelName }
            assertEquals("the screen never holds the private key", "", tunnel.config)
            val stored = runBlocking { repository.getTunnel(tunnel.id) }
            assertTrue("the configuration is kept", stored?.config?.contains(clientKey) == true)

            // A name only the tunnel's DNS knows, at an address only the tunnel reaches.
            val inside = addHost("E2E VPN inside $stamp", "internal-a.lab.vpn", 22, tunnel.id)
            val (insideStatus, insideOut) = broadcast(inside, "echo vpn-$stamp-inside")
            assertEquals(insideOut, BroadcastStatus.Success, insideStatus)
            assertTrue(insideOut, insideOut.contains("vpn-$stamp-inside"))
            composeRule.waitUntil(10_000) { TunnelManager.statuses.value[tunnel.id] != null }
            assertTrue("a handshake happened", TunnelManager.statuses.value.getValue(tunnel.id).lastHandshake > 0)
            composeRule.waitUntil(10_000) { has("vpn.status.${tunnel.id}") }
            composeRule.onNodeWithTag("vpn.status.${tunnel.id}").assert(hasText("Connected", substring = true))

            // A host that answers directly...
            val direct = addHost("E2E VPN direct $stamp", "127.0.0.1", 2201, null)
            val (directStatus, directOut) = broadcast(direct, "echo vpn-$stamp-direct")
            assertEquals(directOut, BroadcastStatus.Success, directStatus)
            // ...once its tunnel is picked goes only through it, where nothing listens on 2201: the
            // pooled direct session from a moment ago is not reused, and it never falls back.
            val row: ServerEntity = vm.servers.value.single { it.id == direct }
            var saved: String? = "pending"
            composeRule.runOnUiThread { vm.updateServer(row.copy(tunnelId = tunnel.id, tunnelHost = "10.77.0.1")) { saved = it } }
            composeRule.waitUntil(15_000) { saved != "pending" }
            assertEquals(null, saved)
            composeRule.waitUntil(15_000) { vm.servers.value.single { it.id == direct }.tunnelId == tunnel.id }
            val (reroutedStatus, reroutedOut) = broadcast(direct, "echo vpn-$stamp-leaked")
            assertFalse("never reached directly: $reroutedOut", reroutedOut.contains("vpn-$stamp-leaked"))
            assertTrue(reroutedOut, reroutedStatus != BroadcastStatus.Success && reroutedOut.contains("refused", ignoreCase = true))

            // A tunnel that cannot connect fails closed too.
            var brokenSaved: String? = "pending"
            composeRule.runOnUiThread {
                vm.saveTunnel(null, "E2E broken $stamp", wireGuardConf(clientKey, serverPub, endpoint = "10.0.2.2:51829", dns = null)) { brokenSaved = it }
            }
            composeRule.waitUntil(15_000) { brokenSaved != "pending" }
            assertEquals(null, brokenSaved)
            composeRule.waitUntil(15_000) { vm.tunnels.value.any { it.name == "E2E broken $stamp" } }
            val broken = vm.tunnels.value.single { it.name == "E2E broken $stamp" }
            val stranded = addHost("E2E VPN stranded $stamp", "127.0.0.1", 2201, broken.id)
            val (strandedStatus, strandedOut) = broadcast(stranded, "echo vpn-$stamp-stranded")
            assertFalse("never reached directly: $strandedOut", strandedOut.contains("vpn-$stamp-stranded"))
            assertTrue(strandedOut, strandedStatus != BroadcastStatus.Success)

            // On a Wi-Fi its tunnel is not needed on, the stranded host is reached directly: the
            // tunnel cannot connect, so an answer can only have come the direct way. Android gives
            // the Wi-Fi's name with the location permission, which a user allows in the editor.
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION).forEach {
                instrumentation.uiAutomation.grantRuntimePermission(context.packageName, it)
            }
            instrumentation.uiAutomation.executeShellCommand("cmd location set-location-enabled true").close()
            CurrentWifi.refresh()
            composeRule.waitUntil(30_000) { CurrentWifi.state.value.name != null }
            val wifi = CurrentWifi.state.value.name!!
            composeRule.onNodeWithTag("vpn.edit.${broken.id}").performScrollTo().performClick()
            composeRule.waitUntil(10_000) { has("vpn.wifi.current") }
            composeRule.onNodeWithTag("vpn.wifi.current").performScrollTo().performClick()
            composeRule.waitUntil(10_000) { has("vpn.wifi.item.$wifi") }
            composeRule.onNodeWithTag("vpn.save").performClick()
            composeRule.waitUntil(15_000) { vm.tunnels.value.single { it.id == broken.id }.directWifi == wifi }
            composeRule.waitUntil(10_000) { has("vpn.direct.${broken.id}") }
            composeRule.onNodeWithTag("vpn.direct.${broken.id}").assert(hasText("On “$wifi” now: its hosts connect directly."))
            val (homeStatus, homeOut) = broadcast(stranded, "echo vpn-$stamp-home")
            assertEquals(homeOut, BroadcastStatus.Success, homeStatus)
            assertTrue(homeOut, homeOut.contains("vpn-$stamp-home"))

            // Off the list again, it is back behind its tunnel: the direct session from a moment
            // ago is not reused, and it fails instead of going direct.
            var cleared: String? = "pending"
            composeRule.runOnUiThread { vm.saveTunnel(broken.id, broken.name, null, emptyList()) { cleared = it } }
            composeRule.waitUntil(15_000) { cleared != "pending" }
            assertEquals(null, cleared)
            val (awayStatus, awayOut) = broadcast(stranded, "echo vpn-$stamp-away")
            assertFalse("never reached directly once the Wi-Fi is off the list: $awayOut", awayOut.contains("vpn-$stamp-away"))
            assertTrue(awayOut, awayStatus != BroadcastStatus.Success)

            // A tunnel hosts still use cannot be deleted.
            var refusal: String? = "pending"
            composeRule.runOnUiThread { vm.deleteTunnel(tunnel.id) { refusal = it } }
            composeRule.waitUntil(15_000) { refusal != "pending" }
            assertNotNull(refusal)
            assertTrue(refusal!!, refusal!!.contains("E2E VPN inside $stamp"))
            assertTrue(vm.tunnels.value.any { it.id == tunnel.id })
        } finally {
            composeRule.runOnUiThread {
                added.forEach { id -> vm.servers.value.find { it.id == id }?.let { vm.deleteServer(it) } }
            }
            composeRule.waitUntil(15_000) { vm.servers.value.none { it.id in added } }
            vm.tunnels.value.filter { it.name.endsWith(stamp) }.forEach { t ->
                var done: String? = "pending"
                composeRule.runOnUiThread { vm.deleteTunnel(t.id) { done = it } }
                composeRule.waitUntil(15_000) { done != "pending" }
            }
            TunnelManager.stopAll()
        }
    }

    private fun wireGuardConf(clientKey: String, serverPub: String, endpoint: String, dns: String?) = buildString {
        append("[Interface]\nPrivateKey = $clientKey\nAddress = 10.77.0.2/32\n")
        if (dns != null) append("DNS = $dns\n")
        append("\n[Peer]\nPublicKey = $serverPub\nEndpoint = $endpoint\nAllowedIPs = 10.77.0.0/24\nPersistentKeepalive = 15\n")
    }
}
