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
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.tunnel.CurrentWifi
import com.jetsetslow.omniterm.data.tunnel.TailscaleNetwork
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelUse
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
 * `test-hosts.sh nebula` generates the private config and starts a real userspace lighthouse and
 * node bridging to internal-a. Run with
 * `./scripts/test-hosts.sh suite E2eNebulaTunnelTest omniterm_e2e_nebula=yes nebula_config user pass`:
 * the phone's identity reaches the app's private files on adb's standard input. No certificate or
 * key is put in instrumentation arguments, source, logs or screenshots.
 */
class E2eNebulaTunnelTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test fun nebulaCarriesSshAndNeverFallsBackAndItsEditorTestAndWifiRuleWork() {
        assumeTrue(E2eArgs.on("omniterm_e2e_nebula"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val config = E2eArgs.privateFile("nebula_config")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(rule.activity)[AppViewModel::class.java]
        val name = "E2E Nebula ${System.nanoTime()}"
        val hosts = mutableListOf<Int>()
        var tunnelId: Int? = null
        fun visible(tag: String) = rule.showsNode(hasTestTag(tag))
        fun save(action: ((String?) -> Unit) -> Unit) {
            var result: String? = "pending"
            rule.runOnUiThread { action { result = it } }
            rule.waitUntil(15_000) { result != "pending" }
            assertEquals(null, result)
        }
        fun host(label: String, inside: String, port: Int): Int = runBlocking {
            repository.insertServer(ServerEntity(
                name = "$name $label", host = "127.0.0.1", port = port,
                username = user, authType = "password",
                authPassword = pass, tunnelId = tunnelId, tunnelHost = inside,
             )).toInt().also { id ->
                hosts += id
                rule.waitUntil(15_000) { vm.servers.value.any { it.id == id } }
            }
        }
        fun probe(id: Int, succeeds: Boolean) {
            val marker = "nebula-proof-${System.nanoTime()}"
            val (status, output) = rule.tunnelBroadcast(vm, id, "echo $marker")
            if (succeeds) {
                assertEquals(output, BroadcastStatus.Success, status)
                assertTrue(output, output.contains(marker))
            } else {
                assertTrue(output, status != BroadcastStatus.Success)
                assertFalse("Host must never be reached by its direct address", output.contains(marker))
            }
        }
        try {
            rule.runOnUiThread { vm.isAppLocked = false; vm.navigateTo(Screen.VpnTunnels) }
            rule.waitUntil(15_000) { visible("vpn.add.nebula") }
            rule.onNodeWithTag("vpn.add.nebula").performClick()
            rule.onNodeWithTag("vpn.name").performTextInput(name)
            rule.onNodeWithTag("vpn.config").performTextReplacement("pki: {key: /do-not-open}")
            rule.waitUntil(10_000) { visible("vpn.check") }
            rule.onNodeWithTag("vpn.save").assertIsNotEnabled()
            rule.onNodeWithTag("vpn.check").assert(hasText("inline", substring = true))
            rule.onNodeWithTag("vpn.config").performTextReplacement(config)
            rule.waitUntil(10_000) { !visible("vpn.check") }
            rule.onNodeWithTag("vpn.nebula.host").performScrollTo().performTextInput("10.88.0.3")
            rule.onNodeWithTag("vpn.nebula.test").performScrollTo().performClick()
            rule.waitUntil(30_000) { visible("vpn.nebula.result") }
            rule.onNodeWithTag("vpn.nebula.result").assert(hasText("Connected through Nebula", substring = true))
            assertTrue("Nebula alone must register for Android network changes", TailscaleNetwork.followingChanges)
            rule.onNodeWithTag("vpn.save").performClick()
            rule.waitUntil(15_000) { vm.tunnels.value.any { it.name == name } }
            val tunnel = vm.tunnels.value.single { it.name == name }
            tunnelId = tunnel.id
            assertEquals(TunnelKinds.NEBULA, tunnel.kind)
            assertEquals("Identity is never held in the list", "", tunnel.config)
            runBlocking {
                assertEquals(config, repository.getTunnel(tunnel.id)!!.config)
                assertFalse("Encrypted at rest", AppDatabase.getDatabase(context).tunnelDao().get(tunnel.id)!!.config.contains("NEBULA"))
            }
            // Same direct address but overlay SSH port is 22. Only the fixture node can answer.
            probe(host("inside", "10.88.0.3", 22), true)
            rule.waitUntil(10_000) { visible("vpn.kind.${tunnel.id}") }
            rule.onNodeWithTag("vpn.kind.${tunnel.id}").assert(hasText("Nebula"))
            rule.waitUntil(10_000) { (TunnelManager.statuses.value[tunnel.id]?.bytesIn ?: 0) > 0 }

            // A controlled direct host demonstrably answers 2201. Its unreachable overlay
            // address must never fall back to that host (even after a direct session is pooled).
            val stranded = host("stranded", "10.88.0.99", 2201)
            probe(stranded, false)
            listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION).forEach {
                instrumentation.uiAutomation.grantRuntimePermission(context.packageName, it)
            }
            instrumentation.uiAutomation.executeShellCommand("cmd location set-location-enabled true").close()
            CurrentWifi.refresh()
            rule.waitUntil(30_000) { CurrentWifi.state.value.name != null }
            val wifi = CurrentWifi.state.value.name!!
            rule.onNodeWithTag("vpn.edit.${tunnel.id}").performScrollTo().performClick()
            // Test in the editor while this tunnel runs: it goes through the running tunnel, and a
            // connection already open through it keeps working, where a second node with the same
            // certificate would take over the phone's Nebula address. sshd sends its key exchange
            // only after the client's version line, so that reply is new data after the test.
            TunnelManager.dial(tunnel.id, "10.88.0.3", 22, 10_000, TunnelUse.SSH).use { open ->
                open.setReadTimeout(10_000)
                fun line() = buildString {
                    while (true) { val b = open.input.read(); if (b < 0 || b == '\n'.code) break; append(b.toChar()) }
                }
                assertTrue("an SSH server answers through the tunnel", line().startsWith("SSH-2.0-"))
                rule.onNodeWithTag("vpn.config").performTextReplacement(config)
                rule.waitUntil(10_000) { !visible("vpn.check") }
                rule.onNodeWithTag("vpn.nebula.host").performScrollTo().performTextInput("10.88.0.3")
                rule.onNodeWithTag("vpn.nebula.test").performScrollTo().performClick()
                rule.waitUntil(30_000) { visible("vpn.nebula.result") }
                rule.onNodeWithTag("vpn.nebula.result").assert(hasText("already running", substring = true))
                open.output.write("SSH-2.0-OmniTermE2e\r\n".toByteArray())
                open.output.flush()
                assertTrue("the connection open before the test still answers", open.input.read(ByteArray(64)) > 0)
            }
            rule.onNodeWithTag("vpn.config").performTextReplacement("")
            rule.onNodeWithTag("vpn.wifi.current").performScrollTo().performClick()
            rule.waitUntil(10_000) { visible("vpn.wifi.item.$wifi") }
            rule.onNodeWithTag("vpn.save").performClick()
            rule.waitUntil(15_000) { vm.tunnels.value.single { it.id == tunnel.id }.directWifi == wifi }
            probe(stranded, true)
            // Removing the positive Wi-Fi exception closes pooled direct sessions.
            save { callback -> vm.saveTunnel(tunnel.id, name, null, emptyList(), TunnelKinds.NEBULA, callback) }
            rule.waitUntil(15_000) { vm.tunnels.value.single { it.id == tunnel.id }.directWifi.isEmpty() }
            probe(stranded, false)
            // An address outside the certificate is refused at once, even though it answers direct.
            probe(host("outside", "127.0.0.1", 2201), false)
        } finally {
            rule.runOnUiThread { hosts.forEach { id -> vm.servers.value.find { it.id == id }?.let { vm.deleteServer(it) } } }
            rule.waitUntil(15_000) { vm.servers.value.none { it.id in hosts } }
            tunnelId?.let { id -> save { callback -> vm.deleteTunnel(id, callback) } }
            TunnelManager.stopAll()
        }
    }
}
