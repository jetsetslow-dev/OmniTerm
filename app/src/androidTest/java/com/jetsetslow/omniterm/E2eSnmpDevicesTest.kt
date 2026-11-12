package com.jetsetslow.omniterm

import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.SnmpDeviceEntity
import com.jetsetslow.omniterm.data.SnmpDevices
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
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
 *   interfaces; its community is stored encrypted.
 * - A v3 device (SHA-256, AES) answers too.
 * - A wrong community, an unknown user and a wrong password each say what to check: the unknown
 *   user from the agent's USM report; a wrong password as no answer, since net-snmp reports it
 *   unauthenticated and SNMP4J ignores that report (RFC 3412 §7.2.11).
 * - Delete asks first and removes it.
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
        try {
            for (d in db.snmpDeviceDao().getAllSnmpDevices().filter { it.name.startsWith(PREFIX) }) db.snmpDeviceDao().deleteSnmpDevice(d.id)
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

            // Delete asks first.
            composeRule.onNodeWithTag("snmp.delete.${v2c.id}").performScrollTo().performClick()
            composeRule.onNodeWithTag("snmp.delete.confirm").performClick()
            await("v2c device deleted", 10_000) { vm.snmpDevices.value.none { it.id == v2c.id } }
            assertTrue(mine().map { it.name } == listOf("$PREFIX v3"))
        } finally {
            for (d in db.snmpDeviceDao().getAllSnmpDevices().filter { it.name.startsWith(PREFIX) }) db.snmpDeviceDao().deleteSnmpDevice(d.id)
        }
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
        const val HOST = "10.0.2.2"
        const val SNMP_TAB = 9
    }
}
