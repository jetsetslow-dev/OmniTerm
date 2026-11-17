package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.AlertHistoryEntity
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AlertSubjects
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.DeviceChecks
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SnmpDeviceEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.remapBackupServerId
import com.jetsetslow.omniterm.ui.restoredRuleEnabled
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Alert rules about an SNMP device rather than a host: they travel in an encrypted backup with the
 * device and come back about the restored device, switched off; they go when the device is deleted,
 * and stay when the hosts are cut down to one.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class DeviceAlertRulesRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun aBackedUpDeviceRuleComesBackAboutTheRestoredDeviceSwitchedOff() = withModel { repo, model, main ->
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        // A gap in the ids, so the restored device gets another id than it had.
        repo.insertSnmpDevice(SnmpDeviceEntity(name = "old", host = "192.0.2.9", community = COMMUNITY))
        val deviceId = repo.insertSnmpDevice(SnmpDeviceEntity(name = "core-switch", host = "192.0.2.10", community = COMMUNITY)).toInt()
        repo.deleteSnmpDevice(repo.getAllSnmpDevices().single { it.name == "old" }.id)
        val subject = AlertSubjects.snmp(deviceId)
        repo.insertRule(AlertRuleEntity(serverId = subject, metricName = DeviceChecks.SNMP_INTERFACE_DOWN, mountPoint = "/", thresholdValue = 0f,
            severity = "CRITICAL", triggerWindow = "2m", target = DeviceChecks.encodePicked(listOf("uplink", "nas"))))
        val ruleId = repo.getAllRules().single().id
        repo.insertAlert(ActiveAlertEntity(ruleId = ruleId, serverId = subject, metricName = DeviceChecks.SNMP_INTERFACE_DOWN,
            currentValue = 1f, thresholdValue = 0f, severity = "CRITICAL", triggeredTime = 1_000L))
        repo.insertAlertHistory(AlertHistoryEntity(activeAlertId = 99, serverId = subject, serverName = "core-switch",
            metricName = DeviceChecks.SNMP_INTERFACE_DOWN, currentValue = 1f, thresholdValue = 0f, severity = "CRITICAL",
            triggeredTime = 500L, historyTime = 600L, status = "resolved"))

        val uri = Uri.parse("content://backup-fixture/devices.json")
        val bytes = ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val exported = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.exportBackup(uri, PASSPHRASE, application, SELECTION) { ok, message -> exported.complete(ok to message) } }
        assertTrue(withTimeout(10_000) { exported.await() }.second, exported.await().first)
        waitWhileOnMain(main) { model.backupExportRunning }
        val backup = bytes.toString(Charsets.UTF_8)

        withContext(Dispatchers.IO) { db.clearAllTables() }
        val restored = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> restored.complete(ok to message) } }
        val (ok, message) = withTimeout(10_000) { restored.await() }
        assertTrue(message, ok)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        val device = repo.getAllSnmpDevices().single()
        val rule = repo.getAllRules().single { it.metricName == DeviceChecks.SNMP_INTERFACE_DOWN }
        assertEquals("about the restored device", AlertSubjects.snmp(device.id), rule.serverId)
        assertFalse("the phone reads a device every minute only once turned on again", rule.enabled)
        assertEquals(listOf("uplink", "nas"), DeviceChecks.picked(rule.target))
        assertEquals(listOf(rule.id to AlertSubjects.snmp(device.id)), repo.getActiveAlerts().map { it.ruleId to it.serverId })
        assertEquals(listOf(AlertSubjects.snmp(device.id)), repo.getAlertHistory().map { it.serverId })
    }

    @Test
    fun deletingADeviceTakesItsAlertRowsAndCuttingHostsDownKeepsThem() = withModel { repo, model, main ->
        val host = repo.insertServer(ServerEntity(name = "web", host = "192.0.2.30", username = "root")).toInt()
        val other = repo.insertServer(ServerEntity(name = "db", host = "192.0.2.31", username = "root")).toInt()
        val switch = repo.insertSnmpDevice(SnmpDeviceEntity(name = "switch", host = "192.0.2.10", community = COMMUNITY)).toInt()
        val ups = repo.insertSnmpDevice(SnmpDeviceEntity(name = "ups", host = "192.0.2.11", community = COMMUNITY)).toInt()
        for (subject in listOf(other, AlertSubjects.snmp(switch), AlertSubjects.snmp(ups))) {
            repo.insertRule(AlertRuleEntity(serverId = subject, metricName = DeviceChecks.SNMP_UPS_ON_BATTERY, mountPoint = "/", thresholdValue = 0f,
                severity = "WARNING", triggerWindow = "2m"))
            val rule = repo.getAllRules().single { it.serverId == subject }
            repo.insertAlert(ActiveAlertEntity(ruleId = rule.id, serverId = subject, metricName = rule.metricName,
                currentValue = 1f, thresholdValue = 0f, severity = "WARNING", triggeredTime = 1_000L))
        }

        repo.keepOnlyServers(setOf(host))
        assertEquals("the other host's rule went; the devices' stayed", setOf(AlertSubjects.snmp(switch), AlertSubjects.snmp(ups)),
            repo.getAllRules().map { it.serverId }.toSet())

        val device = repo.getAllSnmpDevices().single { it.id == switch }
        withContext(main) { model.deleteSnmpDevice(device) }
        withTimeout(10_000) { while (repo.getAllSnmpDevices().any { it.id == switch }) delay(20) }
        assertEquals(listOf(AlertSubjects.snmp(ups)), repo.getAllRules().map { it.serverId })
        assertEquals(listOf(AlertSubjects.snmp(ups)), repo.getActiveAlerts().map { it.serverId })
    }

    @Test
    fun aDeviceIdIsMappedThroughTheRestoredDevicesAndADeviceRuleComesBackOff() {
        val devices = mapOf(AlertSubjects.snmp(4) to AlertSubjects.snmp(1))
        assertEquals(AlertSubjects.snmp(1), remapBackupServerId(AlertSubjects.snmp(4), mapOf(4 to 40), devices))
        assertEquals("never a host's id", 40, remapBackupServerId(4, mapOf(4 to 40), devices))
        assertEquals(null, remapBackupServerId(AlertSubjects.proxmox(4), mapOf(4 to 40), devices))
        assertTrue(restoredRuleEnabled(true, "CPU Usage", 3))
        assertFalse(restoredRuleEnabled(true, DeviceChecks.SNMP_UPS_ON_BATTERY, AlertSubjects.snmp(1)))
    }

    private fun withModel(block: suspend (AppRepository, AppViewModel, ExecutorCoroutineDispatcher) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("devices", model)
            block(AppRepository(db), model, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private companion object {
        const val COMMUNITY = "device-rules-fixture"
        const val PASSPHRASE = "device-rules-backup-passphrase"
        val SELECTION = BackupSelection.NONE.copy(servers = true, alertRules = true, activeAlerts = true, alertHistory = true)
    }
}
