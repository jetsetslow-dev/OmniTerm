package com.jetsetslow.omniterm

import android.Manifest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.tunnel.CloudflareAccessSettings
import com.jetsetslow.omniterm.data.tunnel.CurrentWifi
import com.jetsetslow.omniterm.data.tunnel.TunnelCannotCarry
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelUse
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Omnitunnel
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Contract fake only; this test makes no connection to the Cloudflare service. It needs the
 * fixture's test library, which trusts the fake's CA (scripts/test-hosts/fixtures/cloudflare-access):
 * `scripts/build-tunnel.sh --access-fixture`, then the app built with `-Pomniterm.tunnelAar` set to
 * that library. With `./scripts/test-hosts.sh cloudflare-access` up, run
 * `./scripts/test-hosts.sh suite E2eCloudflareAccessTunnelTest omniterm_e2e_access=yes access_config access_ca user pass`:
 * the service token and CA reach the app's private files on adb's standard input.
 */
class E2eCloudflareAccessTunnelTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Test fun serviceTokenSshRejectionsEncryptedEditingAndWifiBypass() {
        assumeTrue(E2eArgs.on("omniterm_e2e_access"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val settings = CloudflareAccessSettings.parse(E2eArgs.privateFile("access_config"))!!
        val ca = E2eArgs.privateFile("access_ca")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        // The symbol is absent from production AARs. No production trust or endpoint setting.
        Omnitunnel::class.java.getMethod("cloudflareFixture", String::class.java, String::class.java)
            .invoke(null, ca, E2eArgs.get("access_endpoint") ?: "127.0.0.1:8447")
        val repo = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(rule.activity)[AppViewModel::class.java]
        val label = "E2E Access ${System.nanoTime()}"
        var tunnelId: Int? = null
        val hosts = mutableListOf<Int>()
        fun shown(tag: String) = rule.showsNode(hasTestTag(tag))
        fun action(block: ((String?) -> Unit) -> Unit) {
            val result = java.util.concurrent.CompletableFuture<String?>()
            rule.runOnUiThread { block { result.complete(it) } }
            rule.waitUntil(15_000) { result.isDone }
            assertNull(result.get())
        }
        fun addHost(inside: String): Int = runBlocking {
            repo.insertServer(ServerEntity(
                name = "$label ${hosts.size}", host = "127.0.0.1", port = 2201,
                username = user, authType = "password",
                authPassword = pass, tunnelId = tunnelId, tunnelHost = inside,
            )).toInt().also { id -> hosts += id; rule.waitUntil(15_000) { vm.servers.value.any { it.id == id } } }
        }
        fun command(id: Int, succeeds: Boolean) {
            val marker = "access-proof-${System.nanoTime()}"
            val (status, output) = rule.tunnelBroadcast(vm, id, "echo $marker")
            if (succeeds) { assertEquals(output, BroadcastStatus.Success, status); assertTrue(output.contains(marker)) }
            else { assertNotEquals(output, BroadcastStatus.Success, status); assertFalse(output.contains(marker)) }
        }
        fun testEditor(host: String, expected: String) {
            rule.onNodeWithTag("vpn.access.hostname").performScrollTo().performTextReplacement(host)
            rule.onNodeWithTag("vpn.access.test").performScrollTo().performClick()
            rule.waitUntil(20_000) { shown("vpn.access.result") }
            rule.onNodeWithTag("vpn.access.result").assert(hasText(expected, substring = true))
        }
        try {
            rule.runOnUiThread { vm.isAppLocked = false; vm.navigateTo(Screen.VpnTunnels) }
            rule.waitUntil(15_000) { shown("vpn.add.access") }
            rule.onNodeWithTag("vpn.add.access").performScrollTo().performClick()
            rule.onNodeWithTag("vpn.access.privacy").assert(hasText("third party", substring = true))
            rule.onNodeWithTag("vpn.name").performTextInput(label)
            rule.onNodeWithTag("vpn.access.id").performScrollTo().assert(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsProperties.Password)).performTextInput(settings.clientId)
            rule.onNodeWithTag("vpn.access.secret").performScrollTo().assert(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsProperties.Password)).performTextInput(settings.clientSecret)
            rule.onNodeWithTag("vpn.access.secret").performTextReplacement("wrong-fixture-value")
            testEditor(settings.hostname, "rejected the service token")
            rule.onNodeWithTag("vpn.access.secret").performTextReplacement(settings.clientSecret)
            testEditor(settings.hostname, "Connected through Cloudflare Access")
            rule.onNodeWithTag("vpn.save").performClick()
            rule.waitUntil(15_000) { vm.tunnels.value.any { it.name == label } }
            val tunnel = vm.tunnels.value.single { it.name == label }.also { tunnelId = it.id }
            assertEquals(TunnelKinds.CLOUDFLARE_ACCESS, tunnel.kind)
            assertEquals("", tunnel.config)
            runBlocking {
                val raw = AppDatabase.getDatabase(context).tunnelDao().get(tunnel.id)!!.config
                assertFalse(raw.contains(settings.clientSecret)); assertFalse(raw.contains(settings.clientId))
                assertEquals(settings, CloudflareAccessSettings.parse(repo.getTunnel(tunnel.id)!!.config))
            }
            // Open the real host form and choose this kind through the existing shared picker.
            rule.runOnUiThread { vm.navigateTo(Screen.Servers); vm.addServerSheetRequested = true }
            rule.waitUntil(15_000) { shown("addHost.importSshConfig") }
            rule.onNodeWithText(context.getString(R.string.advanced)).performScrollTo().performClick()
            rule.onNodeWithTag("host.tunnel.${tunnel.id}").performScrollTo().performClick()
            rule.onNodeWithTag("host.tunnelHost").performScrollTo().performTextInput(settings.hostname)
            rule.onNodeWithTag("host.tunnelHost").assert(hasText("Cloudflare selects the SSH destination", substring = true))
            repeat(2) { rule.onNodeWithText(context.getString(R.string.back)).performClick() }
            rule.onNodeWithText(context.getString(R.string.cancel)).performClick()
            rule.runOnUiThread { vm.navigateTo(Screen.VpnTunnels) }
            rule.waitUntil(15_000) { shown("vpn.edit.${tunnel.id}") }
            command(addHost(settings.hostname), true)
            // Access reaches only the SSH service its hostname publishes: anything else, such as a
            // port check or a web client, is refused rather than sent into that SSH service.
            val other = runCatching { TunnelManager.dial(tunnel.id, settings.hostname, 443, 10_000, TunnelUse.OTHER) }
            assertTrue("$other", other.exceptionOrNull() is TunnelCannotCarry)
            // An idle connection stays open. The fake, as Cloudflare does, closes a WebSocket that
            // carries nothing for 100 s, and the tunnel pings every 54 s. sshd sends its key
            // exchange only after the client's version line, so that reply is new data after the wait.
            TunnelManager.dial(tunnel.id, settings.hostname, 22, 10_000, TunnelUse.SSH).use { open ->
                open.setReadTimeout(10_000)
                fun line() = buildString {
                    while (true) { val b = open.input.read(); if (b < 0 || b == '\n'.code) break; append(b.toChar()) }
                }
                assertTrue("an SSH server answers through Access", line().startsWith("SSH-2.0-"))
                Thread.sleep(110_000)
                open.output.write("SSH-2.0-OmniTermE2e\r\n".toByteArray())
                open.output.flush()
                assertTrue("the connection idle for 110 s still answers", open.input.read(ByteArray(64)) > 0)
            }
            val wrong = addHost("wrong.access.test")
            command(wrong, false) // direct host answers 2201, but mismatch must fail closed
            rule.onNodeWithTag("vpn.edit.${tunnel.id}").performScrollTo().performClick()
            rule.waitUntil(10_000) { shown("vpn.access.hostname") }
            rule.onNodeWithTag("vpn.access.id").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
            rule.onNodeWithTag("vpn.access.secret").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
            testEditor("reject.access.test", "rejected the service token")
            testEditor("login.access.test", "interactive login")
            testEditor("ordinary.access.test", "did not accept an Access TCP")
            testEditor(settings.hostname, "Connected through Cloudflare Access")
            listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION).forEach {
                instrumentation.uiAutomation.grantRuntimePermission(context.packageName, it)
            }
            instrumentation.uiAutomation.executeShellCommand("cmd location set-location-enabled true").close()
            CurrentWifi.refresh()
            rule.waitUntil(30_000) { CurrentWifi.state.value.name != null }
            val wifi = CurrentWifi.state.value.name!!
            rule.onNodeWithTag("vpn.wifi.current").performScrollTo().performClick()
            rule.waitUntil(10_000) { shown("vpn.wifi.item.$wifi") }
            rule.onNodeWithTag("vpn.save").performClick()
            rule.waitUntil(15_000) { vm.tunnels.value.single { it.id == tunnel.id }.directWifi == wifi }
            command(wrong, true)
            action { callback -> vm.saveTunnel(tunnel.id, label, null, emptyList(), TunnelKinds.CLOUDFLARE_ACCESS, callback) }
            rule.waitUntil(15_000) { vm.tunnels.value.single { it.id == tunnel.id }.directWifi.isEmpty() }
            command(wrong, false)
        } finally {
            rule.runOnUiThread { hosts.forEach { id -> vm.servers.value.find { it.id == id }?.let { vm.deleteServer(it) } } }
            rule.waitUntil(15_000) { vm.servers.value.none { it.id in hosts } }
            tunnelId?.let { id -> action { vm.deleteTunnel(id, it) } }
            TunnelManager.stopAll()
        }
    }
}
