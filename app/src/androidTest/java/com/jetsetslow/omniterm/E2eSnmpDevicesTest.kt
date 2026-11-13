package com.jetsetslow.omniterm

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AlertSubjects
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.DeviceChecks
import com.jetsetslow.omniterm.data.SnmpDeviceEntity
import com.jetsetslow.omniterm.data.SnmpDevices
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.alertNotificationId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Network → SNMP against the repository's net-snmp fixture (`./scripts/test-hosts.sh snmp`),
 * which the emulator reaches at 10.0.2.2:1161 over UDP. Its community and v3 password are passed
 * as `snmp_community` and `snmp_pass`, never committed.
 * - A v2c device added in the dialog is polled and shows the fixture's name, uptime, memory and
 *   interfaces with their error counters, an interface switched on with no link among them, and
 *   its UPS on a low battery (UPS-MIB); its community is stored encrypted.
 * - A v3 device (SHA-256, AES) answers too.
 * - A wrong community, an unknown user and a wrong password each say what to check: the unknown
 *   user from the agent's USM report; a wrong password as no answer, since net-snmp reports it
 *   unauthenticated and SNMP4J ignores that report (RFC 3412 §7.2.11).
 * - Alert rules read it from the phone: Interface Down for an interface picked in the editor, UPS
 *   On Battery and UPS Battery Low each alert, with the device named on the incident, the rule
 *   list and the device's card.
 * - Delete asks first and removes it, with its alert rules, incidents and their notifications.
 */
class E2eSnmpDevicesTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun devicesArePolledFromThePhoneOverV2cAndV3() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_snmp") == "yes")
        val community = requireNotNull(args.getString("snmp_community")) { "-e snmp_community is required" }
        val password = requireNotNull(args.getString("snmp_pass")) { "-e snmp_pass is required" }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val db = AppDatabase.getDatabase(composeRule.activity)
        suspend fun mine() = vm.snmpDevices.value.filter { it.name.startsWith(PREFIX) }
        val originalAlertsEnabled = vm.alertsEnabled
        try {
            forgetMine(vm, db)
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Network)
                vm.activeNetworkTab = SNMP_TAB
            }
            composeRule.waitForIdle()

            // v2c, through the dialog.
            composeRule.onNodeWithTag("snmp.add").performClick()
            composeRule.onNodeWithTag("snmp.field.name").performTextReplacement("$PREFIX v2c")
            composeRule.onNodeWithTag("snmp.field.host").performTextReplacement(HOST)
            composeRule.onNodeWithTag("snmp.field.port").performTextReplacement("1161")
            composeRule.onNodeWithTag("snmp.field.community", useUnmergedTree = true).performTextReplacement(community)
            composeRule.onNodeWithTag("snmp.save").performClick()
            await("v2c device saved", 10_000) { vm.snmpDevices.value.any { it.name == "$PREFIX v2c" } }
            val v2c = vm.snmpDevices.value.single { it.name == "$PREFIX v2c" }
            assertEquals(listOf(HOST, 1161, 2), listOf(v2c.host, v2c.port, v2c.version))
            val raw = db.snmpDeviceDao().getAllSnmpDevices().single { it.id == v2c.id }
            assertTrue("stored encrypted", raw.community.startsWith("enc:") && community !in raw.community)

            // The tab polls it as soon as it is listed.
            await("v2c device answered", 30_000, { vm.snmpReadings[v2c.id]?.outcome }) { vm.snmpReadings[v2c.id]?.outcome is SnmpDevices.Outcome.Answered }
            val snap = (vm.snmpReadings.getValue(v2c.id).outcome as SnmpDevices.Outcome.Answered).snapshot
            assertEquals("omniterm-snmp-fixture", snap.name)
            assertEquals("OmniTerm test rack", snap.location)
            assertTrue("uptime", (snap.uptimeSeconds ?: -1) >= 0)
            assertTrue(snap.interfaces.map { it.name }.toString(), snap.interfaces.any { it.name == "lo" && it.operUp == true })
            assertTrue(snap.storage.toString(), snap.storage.any { it.kind == SnmpDevices.StorageKind.RAM && (it.usedPercent ?: -1f) in 0f..100f })
            composeRule.waitForIdle()
            composeRule.onNode(hasTestTag("snmp.status.${v2c.id}") and hasText("omniterm-snmp-fixture", substring = true), useUnmergedTree = true).assertExists()
            val lo = snap.interfaces.first { it.name == "lo" }
            composeRule.onNodeWithTag("snmp.if.${v2c.id}.${lo.index}", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(hasTestTag("snmp.if.${v2c.id}.${lo.index}") and hasText("lo: up", substring = true), useUnmergedTree = true).assertExists()
            assertTrue("error and discard counters are read", lo.countsProblems)

            // An interface switched on with no link, and one switched off, which is not down.
            val unplugged = snap.interfaces.single { it.name == "omni-up" }
            assertTrue(unplugged.toString(), unplugged.down)
            assertTrue(snap.interfaces.single { it.name == "omni-down" }.let { it.adminUp == false && !it.down })
            composeRule.onNodeWithTag("snmp.if.${v2c.id}.${unplugged.index}", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(hasTestTag("snmp.if.${v2c.id}.${unplugged.index}") and hasText("omni-up: down", substring = true), useUnmergedTree = true).assertExists()

            // Its UPS, from UPS-MIB: on battery, battery low.
            val ups = requireNotNull(snap.ups) { "no UPS read" }
            assertEquals(listOf<Any?>("OmniTerm Fixture UPS 1500", SnmpDevices.PowerSource.BATTERY, SnmpDevices.BatteryState.LOW, 18, 7, 420L),
                listOf(ups.model, ups.source, ups.battery, ups.chargePercent, ups.minutesLeft, ups.secondsOnBattery))
            assertEquals(ups.toString(), listOf(1, 1, 1), listOf(ups.inputVolts.size, ups.outputVolts.size, ups.loadPercent.size))
            composeRule.onNodeWithTag("snmp.ups.${v2c.id}", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(hasTestTag("snmp.ups.${v2c.id}") and hasText("OmniTerm Fixture UPS 1500: on battery", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("snmp.ups.lines.${v2c.id}") and hasText("output 230 V", substring = true), useUnmergedTree = true).assertExists()

            // A second poll gives each interface its traffic rate.
            delay(1_500)
            composeRule.runOnUiThread { vm.pollSnmpDevice(v2c) }
            await("rates after a second poll", 30_000) { vm.snmpReadings[v2c.id]?.rates?.containsKey(lo.index) == true }

            // v3 with SHA-256 and AES.
            val v3 = SnmpDeviceEntity(name = "$PREFIX v3", host = HOST, port = 1161, version = 3, user = "omniterm",
                authProtocol = "SHA-256", authPassword = password, privProtocol = "AES", privPassword = password)
            val saved = CompletableDeferred<String?>()
            composeRule.runOnUiThread { vm.saveSnmpDevice(v3) { saved.complete(it) } }
            assertEquals(null, withTimeout(10_000) { saved.await() })
            val outcomeV3 = vm.snmpOutcome(v3)
            assertTrue(outcomeV3.toString().take(200), outcomeV3 is SnmpDevices.Outcome.Answered)
            assertEquals("omniterm-snmp-fixture", (outcomeV3 as SnmpDevices.Outcome.Answered).snapshot.name)

            // Each way of being turned away says why.
            fun reason(o: SnmpDevices.Outcome) = (o as SnmpDevices.Outcome.Failed).reason
            assertTrue(reason(vm.snmpOutcome(v2c.copy(community = "not-$community"))).startsWith("no answer within 3 s"))
            assertEquals("the device does not know this SNMPv3 user", reason(vm.snmpOutcome(v3.copy(user = "stranger"))))
            // net-snmp reports a wrong digest unauthenticated, and SNMP4J drops that (RFC 3412 §7.2.11).
            val wrongAuth = reason(vm.snmpOutcome(v3.copy(authPassword = "not-$password")))
            assertTrue(wrongAuth, wrongAuth.startsWith("no answer within 3 s") && "user and passwords" in wrongAuth)
            val wrongPriv = reason(vm.snmpOutcome(v3.copy(privPassword = "not-$password")))
            assertTrue(wrongPriv, password !in wrongPriv && community !in wrongPriv)

            // Alert rules on the v2c device: an interface picked in the editor, then the UPS.
            val subject = AlertSubjects.snmp(v2c.id)
            fun rules() = runBlocking { db.alertRuleDao().getAllRules() }.filter { it.notes == NOTE }
            fun firing() = runBlocking { db.activeAlertDao().getActiveAlerts() }.filter { it.serverId == subject }
            TestNotifications.allow()
            vm.saveAlertsEnabled(true)
            composeRule.runOnUiThread {
                vm.activeAlertsTab = 1
                vm.navigateTo(Screen.Alerts)
            }
            composeRule.onNodeWithContentDescription("Add").performClick()
            await("the rule editor", 10_000) { composeRule.onAllNodes(hasText("Add Alert Rule Trigger")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNode(hasText(DeviceChecks.SNMP_INTERFACE_DOWN) and hasClickAction()).performScrollTo().performClick()
            assertTrue("a device rule picks no hosts", composeRule.onAllNodes(hasContentDescription("Choose hosts")).fetchSemanticsNodes().isEmpty())
            composeRule.onNodeWithTag("alertRule.device.$subject").performScrollTo().performClick()
            await("its interfaces", 10_000) { composeRule.onAllNodes(hasTestTag("alertRule.item.omni-up")).fetchSemanticsNodes().isNotEmpty() }
            composeRule.onNodeWithTag("alertRule.device.problem").performScrollTo().assertTextEquals("Pick the interfaces to watch")
            composeRule.onNodeWithTag("alertRule.item.omni-up").performScrollTo().performClick()
            composeRule.onNodeWithText("Notes (optional)", substring = true).performScrollTo().performTextReplacement(NOTE)
            composeRule.onNodeWithText("Confirm").performClick()
            await("the interface rule saved", 10_000) { rules().size == 1 }
            val down = rules().single()
            assertEquals(listOf<Any>(subject, DeviceChecks.SNMP_INTERFACE_DOWN, "omni-up", "2m"), listOf(down.serverId, down.metricName, down.target, down.triggerWindow))
            // From the first reading rather than after two minutes, to keep the suite short.
            vm.updateAlertRule(down.copy(triggerWindow = "0m"))
            vm.addAlertRule(subject, DeviceChecks.SNMP_UPS_ON_BATTERY, "/", 0f, "CRITICAL", "0m", NOTE)
            vm.addAlertRule(subject, DeviceChecks.SNMP_UPS_BATTERY_LOW, "/", DeviceChecks.DEFAULT_CHARGE_PERCENT, "WARNING", "0m", NOTE)
            await("three rules", 10_000) { rules().size == 3 && rules().all { it.triggerWindow == "0m" } }
            fun rule(metric: String): AlertRuleEntity = rules().single { it.metricName == metric }
            val onBattery = rule(DeviceChecks.SNMP_UPS_ON_BATTERY)
            val low = rule(DeviceChecks.SNMP_UPS_BATTERY_LOW)
            val all = listOf(down, onBattery, low)
            // Devices are read once a minute for their rules; adding one reads it at once.
            await("each rule alerts", 150_000, { firing().map { it.ruleId } }) { firing().map { it.ruleId }.toSet() == all.map { it.id }.toSet() }
            fun summary(r: AlertRuleEntity) = vm.hostCheckResults[r.id to subject]?.summary
            assertEquals("1 interface down: omni-up", summary(down))
            assertEquals("on battery: 7 min left, 18% charged", summary(onBattery))
            assertEquals("battery low: 18% charged, 7 min left", summary(low))
            fun notification(r: AlertRuleEntity) = TestNotifications.text(alertNotificationId(r.id, subject))
            await("the notifications", 10_000, { all.map(::notification) }) {
                all.map(::notification) == listOf("Down: omni-up", "UPS on battery: 7 min left, 18% charged", "The UPS reports a low battery: 18% charged, 7 min left")
            }

            // The rule list says what each last saw; the incident names the device.
            val ruleList = composeRule.onNode(hasScrollToNodeAction() and hasAnyDescendant(isRuleSwitch()))
            ruleList.performScrollToNode(hasTestTag("alertRule.enabled.${down.id}"))
            composeRule.onNode(hasTestTag("alertRule.check.${down.id}") and hasText("1 interface down: omni-up", substring = true), useUnmergedTree = true).assertExists()
            composeRule.runOnUiThread { vm.activeAlertsTab = 0 }
            await("the incident", 10_000) { composeRule.onAllNodes(hasText("Device: $PREFIX v2c", substring = true), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }

            // And its card says what is alerting.
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Network)
                vm.activeNetworkTab = SNMP_TAB
            }
            await("the card's alerts", 10_000) {
                composeRule.onAllNodes(hasTestTag("snmp.alerts.${v2c.id}") and hasText(DeviceChecks.SNMP_INTERFACE_DOWN, substring = true), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
            }

            // Delete asks first, and takes its rules, incidents and their notifications with it.
            composeRule.onNodeWithTag("snmp.delete.${v2c.id}").performScrollTo().performClick()
            composeRule.onNodeWithTag("snmp.delete.confirm").performClick()
            await("v2c device deleted", 10_000) { vm.snmpDevices.value.none { it.id == v2c.id } }
            assertTrue(mine().map { it.name } == listOf("$PREFIX v3"))
            await("its rules and incidents", 10_000, { rules() to firing() }) { rules().isEmpty() && firing().isEmpty() }
            assertTrue("its alert history", db.alertHistoryDao().getAlertHistory().none { it.serverId == subject })
            await("its notifications", 10_000) { all.all { TestNotifications.posted(alertNotificationId(it.id, subject)) == null } }
        } finally {
            forgetMine(vm, db)
            vm.saveAlertsEnabled(originalAlertsEnabled)
        }
    }

    /** Deletes this suite's devices with their alert rows, and any rule of its left without one. */
    private suspend fun forgetMine(vm: AppViewModel, db: AppDatabase) {
        for (d in db.snmpDeviceDao().getAllSnmpDevices().filter { it.name.startsWith(PREFIX) }) vm.deleteSnmpDevice(d)
        db.alertRuleDao().getAllRules().filter { it.notes == NOTE }.forEach(vm::deleteAlertRule)
        await("this suite's devices and rules deleted", 10_000) {
            runBlocking { db.snmpDeviceDao().getAllSnmpDevices().none { it.name.startsWith(PREFIX) } && db.alertRuleDao().getAllRules().none { it.notes == NOTE } }
        }
    }

    private fun isRuleSwitch() = SemanticsMatcher("an alert rule's switch") {
        it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("alertRule.enabled.") == true
    }

    /**
     * Waits with the compose clock running: the tab's poll loop is a LaunchedEffect, which the test
     * clock only runs while the test waits through the rule.
     */
    private fun await(what: String, timeoutMs: Long, last: () -> Any? = { null }, predicate: () -> Boolean) {
        try {
            composeRule.waitUntil(timeoutMs, predicate)
        } catch (e: ComposeTimeoutException) {
            throw AssertionError("$what: not within ${timeoutMs}ms; last: ${last()}", e)
        }
    }

    private companion object {
        const val PREFIX = "E2E SNMP"
        const val NOTE = "E2E SNMP device rule"
        const val HOST = "10.0.2.2"
        const val SNMP_TAB = 9
    }
}
