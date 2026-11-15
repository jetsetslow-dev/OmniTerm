package com.jetsetslow.omniterm

import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.BackupChecks
import com.jetsetslow.omniterm.data.CertificateTrust
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.Proxmox
import com.jetsetslow.omniterm.data.ProxmoxServerEntity
import com.jetsetslow.omniterm.data.tunnel.TailscaleSettings
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelStates
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
import kotlin.math.abs

/**
 * Tools → Proxmox VE against the repository's contract fake of the Proxmox VE API
 * (`./scripts/test-hosts.sh proxmox`), which the emulator reaches at https://10.0.2.2:8006 with a
 * self-signed certificate made when the container starts. The fake answers what the API viewer
 * documents; it proves this client, not Proxmox itself. Its two tokens are passed as `pve_token`
 * (may do everything) and `pve_audit_token` (may only read), never committed; `pve_fingerprint` is
 * the certificate's SHA-256 as `openssl x509 -fingerprint -sha256` prints it on the host.
 * - A server added in the dialog is not read until its certificate is trusted, and the fingerprint
 *   the app shows is the one OpenSSL prints. The token is stored encrypted.
 * - Once trusted: version, nodes, guests and recent backups, with a failed backup marked.
 * - Start runs at once; Stop asks first naming the guest, and Cancel sends nothing.
 * - A snapshot is taken, rolled back to and deleted, the last two each after a confirmation naming
 *   the guest and the snapshot; a name Proxmox would refuse cannot be sent.
 * - A read-only token's refusal, a wrong token and a changed certificate each say what is wrong.
 * - Removing a server asks first.
 * - A Backup Age rule for vzdump with no folder, on the lab host, reads the backup tasks of the
 *   server saved for the same address (127.0.0.1, port 8006 reversed like the hosts'): a guest a
 *   scheduled job backed up counts from when the job finished, and one whose backups only failed
 *   alerts.
 */
class E2eProxmoxTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun serversAreReadAndGuestsManagedOverTheApi() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_proxmox") == "yes")
        val token = requireNotNull(args.getString("pve_token")) { "-e pve_token is required" }
        val auditToken = requireNotNull(args.getString("pve_audit_token")) { "-e pve_audit_token is required" }
        val expectedFingerprint = requireNotNull(args.getString("pve_fingerprint")) { "-e pve_fingerprint is required" }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val db = AppDatabase.getDatabase(composeRule.activity)
        suspend fun clean() {
            for (s in db.proxmoxServerDao().getAll().filter { it.name.startsWith(PREFIX) }) db.proxmoxServerDao().delete(s.id)
        }
        fun server(name: String) = vm.proxmoxServers.value.single { it.name == name }
        fun view(id: Int) = vm.proxmoxViews[id]
        fun guest(id: Int, vmid: Int) = view(id)?.overview?.guests?.firstOrNull { it.vmid == vmid }
        try {
            clean()
            composeRule.runOnUiThread { vm.navigateTo(Screen.Proxmox) }
            composeRule.waitForIdle()

            // Added through the dialog: nothing is read before the certificate is trusted.
            composeRule.onNodeWithTag("proxmox.add").performClick()
            composeRule.onNodeWithTag("proxmox.field.name").performTextReplacement("$PREFIX lab")
            composeRule.onNodeWithTag("proxmox.field.host").performTextReplacement(HOST)
            composeRule.onNodeWithTag("proxmox.field.port").performTextReplacement("8006")
            composeRule.onNodeWithTag("proxmox.field.tokenId").performTextReplacement(FULL_ID)
            composeRule.onNodeWithTag("proxmox.field.tokenSecret", useUnmergedTree = true).performTextReplacement(token)
            composeRule.onNodeWithTag("proxmox.save").performClick()
            await("server saved", 10_000) { vm.proxmoxServers.value.any { it.name == "$PREFIX lab" } }
            val added = server("$PREFIX lab")
            assertEquals(listOf(HOST, 8006, FULL_ID, ""), listOf(added.host, added.port, added.tokenId, added.fingerprint))
            val raw = db.proxmoxServerDao().getAll().single { it.id == added.id }
            assertTrue("stored encrypted", raw.tokenSecret.startsWith("enc:") && token !in raw.tokenSecret)

            await("asked to trust the certificate", 20_000, { view(added.id) }) { view(added.id)?.untrusted != null }
            val untrusted = requireNotNull(view(added.id)?.untrusted)
            assertTrue("a first sight, not a change", !untrusted.changed)
            assertTrue("${untrusted.fingerprint} is what OpenSSL prints", CertificateTrust.same(untrusted.fingerprint, expectedFingerprint))
            composeRule.waitForIdle()
            composeRule.onNode(hasTestTag("proxmox.fingerprint.${added.id}") and hasText(untrusted.fingerprint), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("proxmox.status.${added.id}") and hasText("does not know the certificate $HOST presents", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNodeWithTag("proxmox.trust.${added.id}").performScrollTo().performClick()
            await("read once trusted", 20_000, { view(added.id) }) { view(added.id)?.overview != null }
            val lab = server("$PREFIX lab")
            assertTrue("the trusted fingerprint is kept", CertificateTrust.same(lab.fingerprint, expectedFingerprint))

            // Version, nodes, guests and backups.
            val overview = requireNotNull(view(lab.id)?.overview)
            assertEquals("8.4.1", overview.version)
            assertEquals(listOf("pve1" to true, "pve2" to false), overview.nodes.map { it.name to it.online })
            assertEquals(listOf("VM 100 (web)", "VM 101 (db)", "CT 200 (dns)", "VM 9000 (debian-template)"), overview.guests.map { it.label })
            assertEquals(listOf("" to true, "200" to false, "100" to true), overview.backups.map { it.id to it.ok })
            assertEquals("the scheduled job's guests, from its log", mapOf(100 to null, 101 to null), overview.runs.first().guests)
            composeRule.waitForIdle()
            composeRule.onNode(hasTestTag("proxmox.version.${lab.id}") and hasText("Proxmox VE 8.4.1"), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("proxmox.node.${lab.id}.pve2") and hasText("offline", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("proxmox.guest.${lab.id}.100") and hasText("VM 100 (web) · running", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("proxmox.guest.${lab.id}.9000") and hasText("template", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNodeWithTag("proxmox.backup.${lab.id}.0", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(hasTestTag("proxmox.backup.${lab.id}.0") and hasText("100, 101 · OK", substring = true), useUnmergedTree = true).assertExists()
            composeRule.onNode(hasTestTag("proxmox.backup.${lab.id}.1") and hasText("backup storage 'nas' is not online", substring = true), useUnmergedTree = true).assertExists()

            // The fake keeps its state while it runs: start this run from VM 101 stopped, with no snapshot of ours.
            val api = vm.proxmoxApi(lab)
            guest(lab.id, 101)?.takeIf { it.running }?.let { api.power(it, Proxmox.Power.STOP) }
            val db101 = requireNotNull(guest(lab.id, 101))
            if (api.snapshots(db101).any { it.name == SNAP }) api.deleteSnapshot(db101, SNAP)
            composeRule.runOnUiThread { vm.refreshProxmox(lab) }
            await("VM 101 stopped", 20_000, { guest(lab.id, 101) }) { guest(lab.id, 101)?.running == false && view(lab.id)?.loading == false }

            // Start runs at once.
            composeRule.onNodeWithTag("proxmox.guest.${lab.id}.101").performScrollTo().performClick()
            composeRule.onNodeWithTag("proxmox.power.start").performClick()
            await("VM 101 started", 30_000, { vm.proxmoxBusy to guest(lab.id, 101) }) { guest(lab.id, 101)?.running == true }
            composeRule.waitForIdle()
            composeRule.onNode(hasTestTag("proxmox.result") and hasText("Done."), useUnmergedTree = true).assertExists()

            // Stop asks first and names the guest; Cancel sends nothing.
            composeRule.onNodeWithTag("proxmox.power.stop").performClick()
            composeRule.onNodeWithText("Stop VM 101 (db)?").assertExists()
            composeRule.onNodeWithTag("confirm.cancel").performClick()
            composeRule.waitForIdle()
            assertEquals(null, vm.proxmoxBusy)
            delay(2_000)
            assertTrue("still running after Cancel", api.overview().guests.single { it.vmid == 101 }.running)
            composeRule.onNodeWithTag("proxmox.power.stop").performClick()
            composeRule.onNodeWithText("Stop VM 101 (db)?").assertExists()
            composeRule.onNodeWithTag("confirm.ok").performClick()
            await("VM 101 stopped", 30_000, { vm.proxmoxBusy to guest(lab.id, 101) }) { guest(lab.id, 101)?.running == false }

            // Snapshots: a name Proxmox would refuse cannot be sent; take, roll back, delete.
            composeRule.onNodeWithTag("proxmox.snap.name").performScrollTo().performTextReplacement("1st")
            composeRule.onNodeWithTag("proxmox.snap.take").assertIsNotEnabled()
            composeRule.onNodeWithTag("proxmox.snap.name").performTextReplacement(SNAP)
            composeRule.onNodeWithTag("proxmox.snap.description").performTextReplacement("from the device suite")
            composeRule.onNodeWithTag("proxmox.snap.take").performClick()
            await("snapshot listed", 30_000) { composeRule.onAllNodesWithTagCount("proxmox.snap.$SNAP") == 1 }
            composeRule.onNodeWithTag("proxmox.snap.rollback.$SNAP").performScrollTo().performClick()
            composeRule.onNodeWithText("Roll VM 101 (db) back to $SNAP?").assertExists()
            composeRule.onNodeWithTag("confirm.ok").performClick()
            await("rolled back", 30_000, { vm.proxmoxBusy }) { vm.proxmoxBusy == null && composeRule.resultIs("Done.") }
            composeRule.onNodeWithTag("proxmox.snap.delete.$SNAP").performScrollTo().performClick()
            composeRule.onNodeWithText("Delete snapshot $SNAP of VM 101 (db)?").assertExists()
            composeRule.onNodeWithTag("confirm.ok").performClick()
            await("snapshot deleted", 30_000) { composeRule.onAllNodesWithTagCount("proxmox.snap.$SNAP") == 0 && vm.proxmoxBusy == null }
            assertTrue(api.snapshots(db101).none { it.name == SNAP })
            composeRule.onNodeWithTag("proxmox.guest.close").performClick()

            // A read-only token reads, and its refusal says which permission is missing.
            val audit = save(vm, ProxmoxServerEntity(name = "$PREFIX audit", host = HOST, tokenId = AUDIT_ID, tokenSecret = auditToken, fingerprint = lab.fingerprint))
            await("audit token reads", 20_000, { view(audit) }) { view(audit)?.overview != null }
            val refused = CompletableDeferred<String?>()
            composeRule.runOnUiThread {
                vm.proxmoxAction(server("$PREFIX audit"), "test", { power(db101, Proxmox.Power.START) }) { refused.complete(it) }
            }
            val why = withTimeout(30_000) { refused.await() }.orEmpty()
            assertTrue(why, why.startsWith("The token may not do this: Permission check failed (/vms/101, VM.PowerMgmt)"))

            // A wrong token, and a certificate that is not the trusted one.
            val wrong = save(vm, ProxmoxServerEntity(name = "$PREFIX wrong", host = HOST, tokenId = FULL_ID, tokenSecret = "not-$token", fingerprint = lab.fingerprint))
            await("wrong token refused", 20_000, { view(wrong) }) { view(wrong)?.error != null }
            assertTrue(view(wrong)?.error, view(wrong)?.error.orEmpty().startsWith("Proxmox refused the token"))
            assertTrue(token !in view(wrong)?.error.orEmpty())
            val other = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"
            val moved = save(vm, ProxmoxServerEntity(name = "$PREFIX changed", host = HOST, tokenId = FULL_ID, tokenSecret = token, fingerprint = other))
            await("changed certificate refused", 20_000, { view(moved) }) { view(moved)?.untrusted != null }
            assertTrue("seen as a change", view(moved)?.untrusted?.changed == true)
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("proxmox.status.$moved", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(hasTestTag("proxmox.status.$moved") and hasText("is not the one you trusted", substring = true), useUnmergedTree = true).assertExists()

            // Removing asks first.
            composeRule.onNodeWithTag("proxmox.delete.$moved").performScrollTo().performClick()
            composeRule.onNodeWithText("Remove $PREFIX changed?").assertExists()
            composeRule.onNodeWithTag("confirm.ok").performClick()
            await("server removed", 10_000) { vm.proxmoxServers.value.none { it.id == moved } }
        } finally {
            clean()
        }
    }

    /**
     * Through a Tailscale tunnel (the Headscale fixture's subnet router serves the internal network,
     * where the fake also answers): the server is reached at its tunnel address over HTTPS with the
     * trusted certificate, and a server that answers directly is not dialled directly once the
     * tunnel is picked. Run with -e omniterm_e2e_proxmox_tailnet yes, `pve_token`,
     * `pve_fingerprint`, `ts_key` (OMNITERM_TEST_TS_PHONE_KEY) and `pve_behind` (the fake's address
     * on the internal network).
     */
    @Test fun aServerBehindATailnetIsReadThroughItAndNeverDirectly() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_proxmox_tailnet") == "yes")
        val token = requireNotNull(args.getString("pve_token")) { "-e pve_token is required" }
        val fingerprint = requireNotNull(args.getString("pve_fingerprint")) { "-e pve_fingerprint is required" }
        val tsKey = requireNotNull(args.getString("ts_key")) { "-e ts_key is required" }
        val behind = requireNotNull(args.getString("pve_behind")) { "-e pve_behind is required" }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val db = AppDatabase.getDatabase(composeRule.activity)
        val stamp = System.currentTimeMillis().toString().takeLast(6)
        val tunnelName = "E2E PVE tailnet $stamp"
        fun view(id: Int) = vm.proxmoxViews[id]
        suspend fun clean() {
            for (s in db.proxmoxServerDao().getAll().filter { it.name.startsWith(PREFIX) }) db.proxmoxServerDao().delete(s.id)
        }
        try {
            clean()
            val saved = CompletableDeferred<String?>()
            composeRule.runOnUiThread {
                vm.saveTailscaleTunnel(null, tunnelName, TailscaleSettings("http://10.0.2.2:8085", tsKey, "omniterm-pve-$stamp"), emptyList()) { saved.complete(it) }
            }
            assertEquals(null, withTimeout(15_000) { saved.await() })
            await("tunnel saved", 15_000) { vm.tunnels.value.any { it.name == tunnelName } }
            val tunnel = vm.tunnels.value.single { it.name == tunnelName }
            composeRule.runOnUiThread { vm.navigateTo(Screen.Proxmox) }

            // Its own name means nothing to the phone; through the tailnet it is reached at its internal address.
            val inside = save(vm, ProxmoxServerEntity(name = "$PREFIX tailnet", host = "pve1.omniterm.invalid", tokenId = FULL_ID,
                tokenSecret = token, fingerprint = fingerprint, tunnelId = tunnel.id, tunnelHost = behind))
            await("read through the tailnet", 120_000, { view(inside) to TunnelManager.statuses.value[tunnel.id] }) { view(inside)?.overview != null }
            val overview = requireNotNull(view(inside)?.overview)
            assertEquals("8.4.1", overview.version)
            assertEquals(4, overview.guests.size)
            assertEquals(TunnelStates.RUNNING, TunnelManager.statuses.value.getValue(tunnel.id).state)
            composeRule.waitForIdle()
            composeRule.onNode(hasTestTag("proxmox.version.$inside") and hasText("Proxmox VE 8.4.1"), useUnmergedTree = true).assertExists()

            // A server the phone could reach directly is not, once the tunnel is picked.
            val direct = save(vm, ProxmoxServerEntity(name = "$PREFIX tailnet direct", host = HOST, tokenId = FULL_ID,
                tokenSecret = token, fingerprint = fingerprint, tunnelId = tunnel.id))
            await("refused outside the tailnet", 60_000, { view(direct) }) { view(direct)?.error != null }
            assertTrue(view(direct)?.error, "is not in this tailnet" in view(direct)?.error.orEmpty())
            assertEquals(null, view(direct)?.overview)
        } finally {
            clean()
            vm.tunnels.value.filter { it.name == tunnelName }.forEach { t ->
                val done = CompletableDeferred<String?>()
                composeRule.runOnUiThread { vm.deleteTunnel(t.id) { done.complete(it) } }
                withTimeout(15_000) { done.await() }
            }
        }
    }

    @Test fun aVzdumpRuleWithNoFolderReadsTheServersBackupTasks() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_proxmox") == "yes")
        val token = requireNotNull(args.getString("pve_token")) { "-e pve_token is required" }
        val fingerprint = requireNotNull(args.getString("pve_fingerprint")) { "-e pve_fingerprint is required" }
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val db = AppDatabase.getDatabase(composeRule.activity)
        await("the lab host", 15_000) { vm.servers.value.any { it.name == LAB_HOST } }
        val host = vm.servers.value.single { it.name == LAB_HOST }
        assertEquals("the lab host over adb reverse", "127.0.0.1", host.host)
        val originalAlertsEnabled = vm.alertsEnabled
        fun rules() = runBlocking { db.alertRuleDao().getAllRules() }.filter { it.notes == NOTE }
        fun firing() = runBlocking { db.activeAlertDao().getActiveAlerts() }.filter { it.serverId == host.id }
        suspend fun clean() {
            rules().forEach(vm::deleteAlertRule)
            await("rules deleted", 10_000) { rules().isEmpty() }
            for (s in db.proxmoxServerDao().getAll().filter { it.name.startsWith(PREFIX) }) db.proxmoxServerDao().delete(s.id)
        }
        try {
            clean()
            TestNotifications.allow()
            vm.saveAlertsEnabled(true)
            val local = save(vm, ProxmoxServerEntity(name = "$PREFIX local", host = "127.0.0.1", tokenId = FULL_ID, tokenSecret = token, fingerprint = fingerprint))
            for (guest in listOf("101", "200")) {
                vm.addAlertRule(host.id, HostChecks.BACKUP_AGE, "/", 1_000_000f, "WARNING", "0m", NOTE,
                    target = BackupChecks.encode(BackupChecks.Target(BackupChecks.Tool.VZDUMP, "", guest)))
            }
            await("two rules", 10_000) { rules().size == 2 }
            val byGuest = rules().associateBy { BackupChecks.decode(it.target)?.filter }
            val backedUp = byGuest.getValue("101")
            val failedOnly = byGuest.getValue("200")
            fun result(id: Int) = vm.hostCheckResults[id to host.id]
            vm.refreshServer(host.id)
            await("both read", 120_000, { result(backedUp.id) to result(failedOnly.id) }) { result(backedUp.id) != null && result(failedOnly.id) != null }

            // The check's read shows on the screen too; the job names no guest, its log does.
            val overview = requireNotNull(vm.proxmoxViews[local]?.overview) { "read for the check: ${vm.proxmoxViews[local]}" }
            val job = overview.runs.single { it.task.id.isEmpty() }
            val expected = (System.currentTimeMillis() / 1000 - requireNotNull(job.task.end)) / 3600f
            val reading = requireNotNull(result(backedUp.id))
            assertTrue("${reading.summary}: expected about $expected h", reading.value != null && abs(reading.value!! - expected) < 0.1f)
            assertTrue(reading.summary, reading.summary.endsWith("(VM 101 (db) on pve1)"))
            assertEquals(result(failedOnly.id)?.summary, BackupChecks.NO_BACKUPS, result(failedOnly.id)?.value)
            await("the guest with only failed backups alerts", 30_000, { firing() }) { firing().any { it.ruleId == failedOnly.id } }
            await("its notification", 10_000, { TestNotifications.text(alertNotificationId(failedOnly.id, host.id)) }) {
                TestNotifications.text(alertNotificationId(failedOnly.id, host.id)) == "No Proxmox VE backup: no backup of guest 200 finished"
            }
            assertTrue("a backup within its limit is quiet", firing().none { it.ruleId == backedUp.id })
        } finally {
            clean()
            vm.saveAlertsEnabled(originalAlertsEnabled)
        }
    }

    private suspend fun save(vm: AppViewModel, server: ProxmoxServerEntity): Int {
        val saved = CompletableDeferred<Result<Int>>()
        composeRule.runOnUiThread { vm.saveProxmoxServer(server) { saved.complete(it) } }
        return withTimeout(10_000) { saved.await() }.getOrThrow()
    }

    private fun androidx.compose.ui.test.junit4.ComposeTestRule.onAllNodesWithTagCount(tag: String) =
        onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().size

    private fun androidx.compose.ui.test.junit4.ComposeTestRule.resultIs(text: String) =
        onAllNodes(hasTestTag("proxmox.result") and hasText(text), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

    /** Waits with the compose clock running, so the screen's LaunchedEffects run while it waits. */
    private fun await(what: String, timeoutMs: Long, last: () -> Any? = { null }, predicate: () -> Boolean) {
        try {
            composeRule.waitUntil(timeoutMs, predicate)
        } catch (e: ComposeTimeoutException) {
            throw AssertionError("$what: not within ${timeoutMs}ms; last: ${last()}", e)
        }
    }

    private companion object {
        const val PREFIX = "E2E PVE"
        const val LAB_HOST = "E2E Foreground Demo"
        const val NOTE = "E2E PVE backup tasks"
        const val HOST = "10.0.2.2"
        const val FULL_ID = "omniterm@pve!e2e"
        const val AUDIT_ID = "audit@pve!e2e"
        const val SNAP = "e2e-snap"
    }
}
