package com.jetsetslow.omniterm

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
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.tunnel.TailscaleSettings
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelStates
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Tailscale tunnels against the repository's Headscale fixture (scripts/test-hosts, services
 * `headscale` and `tailnet-router`): the router is a subnet router for the internal network, where
 * internal-a answers on port 2222 and is reachable no other way. As a user sets it up:
 * - a plain-HTTP control server is warned about, a bad device name is refused, and the tunnel is
 *   saved with an auth key the screen never holds again;
 * - a host behind the subnet router is reached through the tunnel, which signs in by itself, and
 *   the device's keys are kept encrypted for the tunnel alone;
 * - a host that answers directly, once the tunnel is picked, is never dialled directly;
 * - a tunnel without a key shows a Sign in button and carries nothing, and its host never goes
 *   direct.
 * Run with `./scripts/test-hosts.sh suite E2eTailscaleTunnelTest omniterm_e2e_tailscale=yes ts_key
 * ts_behind user pass` (the key and address are written by `./scripts/test-hosts.sh up` or
 * `tailnet`). Everything it adds is removed again.
 */
class E2eTailscaleTunnelTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun hostsBehindATailnetAreReachedThroughItAndNeverDirectly() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_tailscale") == "yes")
        val authKey = E2eArgs.require("ts_key")
        val behindAddress = E2eArgs.require("ts_behind")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val db = AppDatabase.getDatabase(context)
        val repository = AppRepository(db)
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        fun has(tag: String) = composeRule.showsNode(hasTestTag(tag))
        val stamp = System.currentTimeMillis().toString().takeLast(6)
        val tunnelName = "E2E Tailnet $stamp"
        val control = "http://10.0.2.2:8085"
        val added = mutableListOf<Int>()

        fun broadcast(serverId: Int, command: String) = composeRule.tunnelBroadcast(vm, serverId, command)

        fun addHost(name: String, host: String, port: Int, tunnelId: Int?): Int {
            var error: String? = "pending"
            composeRule.runOnUiThread {
                vm.addServer(
                    name = name, host = host, port = port, username = user, group = "E2E", authType = "password",
                    notes = "", keepAlive = 30, compression = false, proxy = "", password = pass,
                    tunnelId = tunnelId, tunnelHost = "",
                ) { error = it }
            }
            composeRule.waitUntil(15_000) { error != "pending" }
            assertEquals(null, error)
            composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == name } }
            return vm.servers.value.single { it.name == name }.id.also { added += it }
        }

        try {
            // Added on the screen.
            composeRule.runOnUiThread { vm.navigateTo(Screen.VpnTunnels) }
            composeRule.waitUntil(15_000) { has("vpn.add.tailscale") }
            composeRule.onNodeWithTag("vpn.add.tailscale").performClick()
            composeRule.waitUntil(10_000) { has("vpn.ts.control") }
            composeRule.onNodeWithTag("vpn.name").performTextInput(tunnelName)
            composeRule.onNodeWithTag("vpn.ts.control").performTextInput(control)
            composeRule.waitUntil(10_000) { has("vpn.ts.plainhttp") }
            composeRule.onNodeWithTag("vpn.ts.device").performTextReplacement("-bad")
            composeRule.waitUntil(10_000) { has("vpn.check") }
            composeRule.onNodeWithTag("vpn.check").assert(hasText("device name", substring = true))
            composeRule.onNodeWithTag("vpn.save").assertIsNotEnabled()
            composeRule.onNodeWithTag("vpn.ts.device").performTextReplacement("omniterm-e2e-$stamp")
            composeRule.waitUntil(10_000) { !has("vpn.check") }
            composeRule.onNodeWithTag("vpn.ts.authkey").performTextInput(authKey)
            composeRule.onNodeWithTag("vpn.save").performClick()
            composeRule.waitUntil(15_000) { vm.tunnels.value.any { it.name == tunnelName } }
            val tunnel = vm.tunnels.value.single { it.name == tunnelName }
            assertEquals(TunnelKinds.TAILSCALE, tunnel.kind)
            assertEquals("the screen never holds the auth key", "", tunnel.config)
            val stored = runBlocking { repository.getTunnel(tunnel.id) }!!
            assertEquals(TailscaleSettings(control, authKey, "omniterm-e2e-$stamp"), TailscaleSettings.parse(stored.config))

            // A host behind the subnet router, through the tunnel, which signs in with the key.
            val behind = addHost("E2E TS behind $stamp", behindAddress, 2222, tunnel.id)
            val (behindStatus, behindOut) = broadcast(behind, "echo ts-$stamp-behind")
            assertEquals(behindOut, BroadcastStatus.Success, behindStatus)
            assertTrue(behindOut, behindOut.contains("ts-$stamp-behind"))
            val status = TunnelManager.statuses.value.getValue(tunnel.id)
            assertEquals(TunnelStates.RUNNING, status.state)
            assertTrue(status.addresses, status.addresses.startsWith("100."))
            composeRule.waitUntil(10_000) { has("vpn.status.${tunnel.id}") }
            composeRule.onNodeWithTag("vpn.status.${tunnel.id}").assert(hasText("Connected as 100.", substring = true))
            // The device's keys: kept for the tunnel alone, and encrypted.
            val node = runBlocking { repository.tunnelNodeState(tunnel.id) }
            assertTrue("the node's keys are kept", node.contains("_machinekey"))
            val raw = runBlocking { db.tunnelDao().nodeState(tunnel.id) }.orEmpty()
            assertFalse("and encrypted", raw.contains("_machinekey"))
            assertEquals("", runBlocking { repository.getTunnel(tunnel.id) }!!.nodeState)

            // A host that answers directly, through the tunnel: not in the tailnet, so not dialled.
            val direct = addHost("E2E TS direct $stamp", "127.0.0.1", 2201, tunnel.id)
            val (directStatus, directOut) = broadcast(direct, "echo ts-$stamp-leaked")
            assertFalse("never reached directly: $directOut", directOut.contains("ts-$stamp-leaked"))
            assertTrue(directOut, directStatus != BroadcastStatus.Success && directOut.contains("is not in this tailnet"))

            // Without a key it waits for a sign-in, shows where, and carries nothing.
            var unsigned: String? = "pending"
            composeRule.runOnUiThread {
                vm.saveTailscaleTunnel(null, "E2E Unsigned $stamp", TailscaleSettings(control, "", "omniterm-e2e-u$stamp"), emptyList()) { unsigned = it }
            }
            composeRule.waitUntil(15_000) { unsigned != "pending" }
            assertEquals(null, unsigned)
            composeRule.waitUntil(15_000) { vm.tunnels.value.any { it.name == "E2E Unsigned $stamp" } }
            val waiting = vm.tunnels.value.single { it.name == "E2E Unsigned $stamp" }
            composeRule.waitUntil(10_000) { has("vpn.connect.${waiting.id}") }
            composeRule.onNodeWithTag("vpn.connect.${waiting.id}").performScrollTo().performClick()
            composeRule.waitUntil(60_000) { TunnelManager.statuses.value[waiting.id]?.state == TunnelStates.NEEDS_LOGIN }
            assertTrue(TunnelManager.statuses.value.getValue(waiting.id).authUrl.startsWith(control))
            composeRule.waitUntil(10_000) { has("vpn.signin.${waiting.id}") }
            composeRule.onNodeWithTag("vpn.status.${waiting.id}").assert(hasText("Waiting for you to sign in", substring = true))
            val stranded = addHost("E2E TS stranded $stamp", "127.0.0.1", 2201, waiting.id)
            val (strandedStatus, strandedOut) = broadcast(stranded, "echo ts-$stamp-stranded")
            assertFalse("never reached directly: $strandedOut", strandedOut.contains("ts-$stamp-stranded"))
            assertTrue(strandedOut, strandedStatus != BroadcastStatus.Success && strandedOut.contains("is not signed in"))
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
        }
    }
}
