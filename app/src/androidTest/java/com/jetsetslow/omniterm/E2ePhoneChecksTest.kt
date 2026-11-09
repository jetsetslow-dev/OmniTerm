package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationManager
import android.os.Build
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.EndpointChecks
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

/**
 * Ping, TCP Port and DNS checks from the phone, on the API 35 emulator, against the repository's
 * provisioned disposable host and a DNS stand-in in this process:
 * - A TCP Port rule made in the editor, given just the fixture's port, connects to the host's own
 *   address, and the rule list shows the reading.
 * - Ping of the host's address and a DNS name the stand-in knows read a time.
 * - A closed port and a name the stand-in calls NXDOMAIN open incidents with their own words.
 * - Tools → Ping refuses a target that ping would read as an option.
 */
class E2ePhoneChecksTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun phoneChecksReadTheFixtureAndAlertOnAClosedPortAndAMissingName() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_phone_checks") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = vm.servers.value.single { it.name == HOST }
        val fixturePort = args.getString("port")?.toIntOrNull() ?: 2205
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertEquals("Use the repository fixture port", fixturePort, host.port)
        val originalAlertsEnabled = vm.alertsEnabled
        val originalScreen = vm.currentScreen
        val originalTab = vm.activeAlertsTab

        // Answers A for up.test and NXDOMAIN for anything else.
        val dns = DatagramSocket(0, InetAddress.getByName("127.0.0.1"))
        val responder = thread(isDaemon = true) {
            val buf = ByteArray(512)
            while (!dns.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                runCatching { dns.receive(p) }.getOrElse { return@thread }
                val q = buf.copyOf(p.length)
                val up = questionName(q) == "up.test"
                val reply = q.copyOf()
                reply[2] = (0x80 or (q[2].toInt() and 0x01)).toByte()
                reply[3] = (if (up) 0x80 else 0x83).toByte()
                val answers = if (up && q[q.size - 3].toInt() == 1) 1 else 0
                reply[7] = answers.toByte()
                val out = if (answers == 1) reply + byteArrayOf(0xc0.toByte(), 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1) else reply
                dns.send(DatagramPacket(out, out.size, p.address, p.port))
            }
        }
        val dnsServer = "127.0.0.1:${dns.localPort}"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                instrumentation.uiAutomation.executeShellCommand(
                    "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS",
                ).close()
            }
            composeRule.runOnUiThread { vm.startPing("-f", 1) }
            assertEquals(listOf("Enter a valid hostname or IP address."), vm.pingLines)

            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            composeRule.waitUntil(10_000) { vm.alertRules.value.none { it.notes == NOTE } }
            vm.saveAlertsEnabled(true)

            composeRule.runOnUiThread {
                vm.activeAlertsTab = 1
                vm.navigateTo(Screen.Alerts)
            }
            composeRule.onNodeWithContentDescription("Add").performClick()
            composeRule.waitUntil(10_000) { composeRule.onAllNodes(hasText("Add Alert Rule Trigger")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithContentDescription("Choose hosts").performClick()
            composeRule.onNodeWithText(HOST).performClick()
            composeRule.onNodeWithText("Done").performClick()
            composeRule.onNodeWithText(EndpointChecks.TCP_PORT).performScrollTo().performClick()
            composeRule.onNodeWithText("Enter a port, or host:port").performScrollTo()
            composeRule.onNodeWithTag("alertRule.target").performScrollTo().performTextReplacement(fixturePort.toString())
            // Once a port is typed, the error gives way to what a bare port means.
            composeRule.onNodeWithText("A port alone connects to each host's own address", substring = true).performScrollTo()
            val fields = composeRule.onAllNodes(hasSetTextAction())
            fields[fields.fetchSemanticsNodes().size - 1].performScrollTo().performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").performClick()
            composeRule.waitUntil(10_000) { vm.alertRules.value.any { it.notes == NOTE } }
            val tcp = vm.alertRules.value.single { it.notes == NOTE }
            assertEquals(EndpointChecks.TCP_PORT, tcp.metricName)
            assertEquals(fixturePort.toString(), tcp.target)
            assertEquals("the editor's default for a TCP check", 1000f, tcp.thresholdValue)

            vm.addAlertRule(host.id, EndpointChecks.PING, "/", 2000f, "WARNING", "5m", NOTE, target = "")
            vm.addAlertRule(host.id, EndpointChecks.DNS_CHECK, "/", 2000f, "WARNING", "5m", NOTE, target = "up.test@$dnsServer")
            vm.addAlertRule(host.id, EndpointChecks.DNS_CHECK, "/", 2000f, "CRITICAL", "0m", NOTE, target = "gone.test@$dnsServer")
            vm.addAlertRule(host.id, EndpointChecks.TCP_PORT, "/", 1000f, "CRITICAL", "0m", NOTE, target = "127.0.0.1:1")
            composeRule.waitUntil(10_000) { vm.alertRules.value.count { it.notes == NOTE } == 5 }
            val mine = vm.alertRules.value.filter { it.notes == NOTE }
            val ping = mine.single { it.metricName == EndpointChecks.PING }
            val dnsUp = mine.single { it.target.startsWith("up.test") }
            val dnsGone = mine.single { it.target.startsWith("gone.test") }
            val closed = mine.single { it.target == "127.0.0.1:1" }

            composeRule.waitUntil(30_000) { mine.all { vm.endpointCheckResults[it.id to host.id] != null } }
            fun reading(ruleId: Int) = vm.endpointCheckResults.getValue(ruleId to host.id)
            assertEquals("127.0.0.1:$fixturePort", reading(tcp.id).target)
            assertTrue(reading(tcp.id).summary, (reading(tcp.id).value ?: -1f) >= 0f)
            assertTrue("ping of the host: ${reading(ping.id).summary}", (reading(ping.id).value ?: -1f) >= 0f)
            assertTrue(reading(dnsUp.id).summary, (reading(dnsUp.id).value ?: -1f) >= 0f)
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("127.0.0.1:$fixturePort · ", substring = true)).fetchSemanticsNodes().isNotEmpty()
            }

            composeRule.waitUntil(30_000) {
                vm.activeAlerts.value.any { it.ruleId == closed.id } && vm.activeAlerts.value.any { it.ruleId == dnsGone.id }
            }
            composeRule.waitUntil(10_000) {
                notificationText(closed.id, host.id) == "TCP Port 127.0.0.1:1 failed: not accepting connections"
            }
            composeRule.waitUntil(10_000) {
                notificationText(dnsGone.id, host.id) == "DNS gone.test @ $dnsServer failed: no such name (NXDOMAIN)"
            }
            assertTrue(vm.activeAlerts.value.none { it.ruleId in setOf(tcp.id, ping.id, dnsUp.id) })
        } finally {
            dns.close()
            responder.join(2_000)
            vm.alertRules.value.filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
            vm.saveAlertsEnabled(originalAlertsEnabled)
            composeRule.runOnUiThread {
                vm.activeAlertsTab = originalTab
                vm.navigateTo(originalScreen)
            }
        }
    }

    private fun questionName(q: ByteArray): String {
        val labels = mutableListOf<String>()
        var i = 12
        while (i < q.size && q[i].toInt() != 0) {
            val n = q[i].toInt()
            labels += String(q, i + 1, n, Charsets.US_ASCII)
            i += n + 1
        }
        return labels.joinToString(".")
    }

    private fun notificationText(ruleId: Int, serverId: Int): String? {
        val manager = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(NotificationManager::class.java)
        val expectedId = "alert_${ruleId}_$serverId".hashCode()
        return manager?.activeNotifications?.firstOrNull { it.id == expectedId }
            ?.notification?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
        const val NOTE = "E2E phone checks"
    }
}
