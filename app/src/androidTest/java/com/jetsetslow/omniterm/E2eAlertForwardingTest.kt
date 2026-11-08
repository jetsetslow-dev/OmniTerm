package com.jetsetslow.omniterm

import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AlertForwarding
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.EndpointChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Alert forwarding on the API 35 emulator, to a webhook stand-in in this process:
 * - The Alerts screen's dialog sets up a webhook with a bearer token, warns that plain HTTP is
 *   clear text, and "Send test" delivers a test alert carrying the token.
 * - Saved, the token is stored encrypted, not as typed.
 * - An incident on the provisioned host (a TCP Port check of a closed port) is forwarded with the
 *   notification's words, and the screen says when the last alert went out.
 */
class E2eAlertForwardingTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun aWebhookSetUpInTheDialogReceivesTheTestAndARealIncident() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_alert_forwarding") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        val originalForwarding = vm.alertForwarding
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab

        val hook = Hook()
        val url = "http://127.0.0.1:${hook.port}/hook"
        try {
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(true)
            composeRule.runOnUiThread {
                vm.saveAlertForwarding(AlertForwarding.Config())
                vm.activeAlertsTab = 0
                vm.navigateTo(Screen.Alerts)
            }

            composeRule.onNodeWithText("Off: alerts stay on this phone.").assertExists()
            composeRule.onNodeWithTag("alertForward.open").performClick()
            composeRule.onNodeWithText("Webhook").performClick()
            composeRule.onNodeWithText("Enter the server's address").performScrollTo()
            composeRule.onNodeWithTag("alertForward.url").performScrollTo().performTextReplacement(url)
            composeRule.onNodeWithTag("alertForward.token").performScrollTo().performTextReplacement(TOKEN)
            composeRule.onNodeWithText("Without HTTPS, alerts and the token travel in clear text.").performScrollTo()

            composeRule.onNodeWithTag("alertForward.test").performScrollTo().performClick()
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodes(hasText("Test delivered (HTTP 200)")).fetchSemanticsNodes().isNotEmpty()
            }
            val test = hook.requests.poll(5, TimeUnit.SECONDS)
            assertNotNull("the test reached the webhook", test)
            assertEquals("POST /hook HTTP/1.1", test!!.line)
            assertEquals("Bearer $TOKEN", test.headers["authorization"])
            assertTrue(test.body, test.body.contains(""""title":"OmniTerm test alert""""))

            composeRule.onNodeWithText("Save").performClick()
            composeRule.waitUntil(10_000) { vm.alertForwarding.kind == AlertForwarding.KIND_WEBHOOK }
            assertEquals(url, vm.alertForwarding.url)
            assertEquals(TOKEN, vm.alertForwarding.token)
            composeRule.onNodeWithText("Webhook: 127.0.0.1").assertExists()
            val stored = runBlocking {
                AppDatabase.getDatabase(context).appSettingDao().getSetting(AlertForwarding.SETTING_TOKEN)?.value
            }
            assertTrue("a token is stored", !stored.isNullOrEmpty())
            assertTrue("the token is stored encrypted, not as typed", !stored!!.contains(TOKEN))

            vm.addAlertRule(host.id, EndpointChecks.TCP_PORT, "/", 1000f, "CRITICAL", "0m", NOTE, target = "127.0.0.1:1")
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }
            val rule = vm.alertRules.value.single { it.notes == NOTE }
            composeRule.waitUntil(30_000) { vm.activeAlerts.value.any { it.ruleId == rule.id } }
            // Other rules on this device may forward too; find this one's.
            var incident: Hook.Request? = null
            val deadline = System.currentTimeMillis() + 30_000
            while (incident == null && System.currentTimeMillis() < deadline) {
                incident = hook.requests.poll(1, TimeUnit.SECONDS)?.takeIf { it.body.contains("127.0.0.1:1") }
            }
            assertNotNull("the incident was forwarded", incident)
            for (part in listOf(
                """"event":"triggered"""", """"severity":"CRITICAL"""", """"host":"$HOST"""", """"rule":"TCP Port"""",
                """"title":"CRITICAL: $HOST"""", """"message":"TCP Port 127.0.0.1:1 failed: not accepting connections"""",
            )) {
                assertTrue(incident!!.body, incident.body.contains(part))
            }
            assertEquals("Bearer $TOKEN", incident!!.headers["authorization"])
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("Last alert forwarded at", substring = true)).fetchSemanticsNodes().isNotEmpty()
            }
        } finally {
            hook.close()
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.runOnUiThread {
                vm.saveAlertForwarding(originalForwarding)
                vm.saveAlertsEnabled(originalAlertsEnabled)
                vm.activeAlertsTab = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    /** Just enough HTTP/1.1 to take one POST per connection and answer 200. */
    private class Hook : AutoCloseable {
        data class Request(val line: String, val headers: Map<String, String>, val body: String)

        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val port = socket.localPort
        val requests = LinkedBlockingQueue<Request>()
        private val worker = thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrElse { return@thread }
                runCatching {
                    client.use { c ->
                        c.soTimeout = 5_000
                        val input = BufferedInputStream(c.getInputStream())
                        val lines = readHead(input).split("\r\n")
                        val headers = lines.drop(1).filter { ':' in it }
                            .associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
                        val length = headers["content-length"]?.toIntOrNull() ?: 0
                        val body = ByteArray(length)
                        var read = 0
                        while (read < length) {
                            val n = input.read(body, read, length - read)
                            if (n < 0) break
                            read += n
                        }
                        requests.add(Request(lines.first(), headers, String(body, 0, read, Charsets.UTF_8)))
                        c.getOutputStream().apply {
                            write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                            flush()
                        }
                    }
                }
            }
        }

        private fun readHead(input: InputStream): String {
            val head = StringBuilder()
            while (!head.endsWith("\r\n\r\n")) {
                val b = input.read()
                if (b < 0 || head.length > 16_384) break
                head.append(b.toChar())
            }
            return head.toString().trimEnd()
        }

        override fun close() {
            socket.close()
            worker.join(2_000)
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NOTE = "E2E alert forwarding"
        const val TOKEN = "e2e-forward-token"
    }
}
