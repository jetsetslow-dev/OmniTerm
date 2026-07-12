package com.jetsetslow.omniterm.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppRepositoryCascadeTest {
    private lateinit var db: AppDatabase
    private lateinit var repository: AppRepository

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            AppDatabase::class.java,
        ).allowMainThreadQueries().build()
        repository = AppRepository(db)
    }

    @After fun tearDown() = db.close()

    @Test fun keepNoneDeletesEveryHostScopedRowButPreservesFleetWideAlerts() = runBlocking {
        val serverId = db.serverDao().insertServer(
            ServerEntity(name = "host", host = "host.test", username = "user"),
        ).toInt()
        db.metricHistoryDao().insertMetric(MetricHistoryEntity(serverId = serverId, timestamp = 1, cpuUsage = 1f, ramUsage = 2f, diskUsage = 3f, latency = 4, networkIn = 5f, networkOut = 6f))
        db.alertRuleDao().insertRule(AlertRuleEntity(id = 1, serverId = serverId, metricName = "CPU Usage", thresholdValue = 90f, severity = "WARNING"))
        db.alertRuleDao().insertRule(AlertRuleEntity(id = 2, serverId = 0, metricName = "CPU Usage", thresholdValue = 95f, severity = "CRITICAL"))
        db.activeAlertDao().insertAlert(ActiveAlertEntity(id = 1, ruleId = 1, serverId = serverId, metricName = "CPU Usage", currentValue = 99f, thresholdValue = 90f, severity = "WARNING", triggeredTime = 1))
        db.activeAlertDao().insertAlert(ActiveAlertEntity(id = 2, ruleId = 2, serverId = 0, metricName = "CPU Usage", currentValue = 99f, thresholdValue = 95f, severity = "CRITICAL", triggeredTime = 2))
        db.alertHistoryDao().insertHistory(AlertHistoryEntity(id = 1, activeAlertId = 1, serverId = serverId, serverName = "host", metricName = "CPU Usage", currentValue = 99f, thresholdValue = 90f, severity = "WARNING", triggeredTime = 1, historyTime = 1, status = "resolved"))
        db.alertHistoryDao().insertHistory(AlertHistoryEntity(id = 2, activeAlertId = 2, serverId = 0, serverName = "Fleet", metricName = "CPU Usage", currentValue = 99f, thresholdValue = 95f, severity = "CRITICAL", triggeredTime = 2, historyTime = 2, status = "active"))
        db.portForwardDao().insertPortForward(PortForwardEntity(serverId = serverId, name = "local", bindPort = 8080, destHost = "127.0.0.1", destPort = 80))
        db.stackRegistryDao().upsertAll(listOf(StackRegistryEntity(serverId = serverId, runtime = "docker", project = "app", workingDir = "/srv/app", configFiles = "compose.yml")))
        db.persistentSessionDao().upsert(PersistentSessionEntity("omniterm-test", serverId, "host", 1))
        db.appSettingDao().insertSetting(AppSettingEntity("sftp_bookmarks_$serverId", "[]"))

        repository.keepOnlyServers(emptySet())

        assertEquals(0, count("servers"))
        assertEquals(0, count("metric_history"))
        assertEquals(0, count("port_forwards"))
        assertEquals(0, count("stack_registry"))
        assertEquals(0, count("persistent_sessions"))
        assertEquals(0, count("app_settings", "`key` LIKE 'sftp_bookmarks_%'"))
        assertEquals(1, count("alert_rules", "serverId = 0"))
        assertEquals(1, count("active_alerts", "serverId = 0"))
        assertEquals(1, count("alert_history", "serverId = 0"))
        assertEquals(0, count("alert_rules", "serverId != 0"))
        assertEquals(0, count("active_alerts", "serverId != 0"))
        assertEquals(0, count("alert_history", "serverId != 0"))
    }

    private fun count(table: String, where: String? = null): Int {
        val sql = "SELECT COUNT(*) FROM $table" + (where?.let { " WHERE $it" } ?: "")
        return db.openHelper.readableDatabase.query(sql).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }
    }
}
