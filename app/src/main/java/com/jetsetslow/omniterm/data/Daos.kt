package com.jetsetslow.omniterm.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface ServerDao {
    @Query("SELECT * FROM servers ORDER BY name ASC")
    fun getAllServersFlow(): Flow<List<ServerEntity>>

    @Query("SELECT * FROM servers ORDER BY name ASC")
    suspend fun getAllServers(): List<ServerEntity>

    @Query("SELECT * FROM servers WHERE id = :id")
    suspend fun getServerById(id: Int): ServerEntity?

    @Query("SELECT * FROM servers WHERE name = :name LIMIT 1")
    suspend fun getServerByName(name: String): ServerEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertServer(server: ServerEntity): Long

    @Update
    suspend fun updateServer(server: ServerEntity)

    @Query("UPDATE servers SET status = 'offline', healthScore = 0, lastLatency = 0, authStatus = 'unknown', authError = NULL")
    suspend fun resetAllConnectionStates()

    @Query("UPDATE servers SET status = :status, healthScore = :health, lastLatency = :latency WHERE id = :id")
    suspend fun updateConnectionState(id: Int, status: String, health: Int, latency: Int)

    @Query("UPDATE servers SET authStatus = :authStatus, authError = :authError WHERE id = :id")
    suspend fun updateAuthState(id: Int, authStatus: String, authError: String?)

    @Delete
    suspend fun deleteServer(server: ServerEntity)

    @Query("DELETE FROM servers WHERE id NOT IN (:keepIds)")
    suspend fun deleteServersExcept(keepIds: List<Int>)
}

@Dao
interface MetricHistoryDao {
    @Query("SELECT * FROM metric_history WHERE serverId = :serverId ORDER BY timestamp ASC")
    fun getMetricsForServerFlow(serverId: Int): Flow<List<MetricHistoryEntity>>

    @Query("SELECT * FROM metric_history WHERE serverId = :serverId ORDER BY timestamp ASC")
    suspend fun getMetricsForServer(serverId: Int): List<MetricHistoryEntity>

    @Query("SELECT * FROM metric_history WHERE serverId = :serverId AND timestamp >= :since ORDER BY timestamp ASC")
    suspend fun getMetricsSince(serverId: Int, since: Long): List<MetricHistoryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMetric(metric: MetricHistoryEntity)

    @Query("DELETE FROM metric_history WHERE timestamp < :cutoffTimestamp")
    suspend fun pruneMetrics(cutoffTimestamp: Long)

    @Query("DELETE FROM metric_history WHERE serverId NOT IN (:keepServerIds)")
    suspend fun deleteExceptServers(keepServerIds: List<Int>)
}

@Dao
interface SshKeyDao {
    @Query("SELECT * FROM ssh_keys ORDER BY alias ASC")
    fun getAllKeysFlow(): Flow<List<SshKeyEntity>>

    @Query("SELECT * FROM ssh_keys ORDER BY alias ASC")
    suspend fun getAllKeys(): List<SshKeyEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertKey(key: SshKeyEntity)

    @Delete
    suspend fun deleteKey(key: SshKeyEntity)
}

@Dao
interface CredentialProfileDao {
    @Query("SELECT * FROM credential_profiles ORDER BY profileName ASC")
    fun getAllProfilesFlow(): Flow<List<CredentialProfileEntity>>

    @Query("SELECT * FROM credential_profiles ORDER BY profileName ASC")
    suspend fun getAllProfiles(): List<CredentialProfileEntity>

    @Query("SELECT * FROM credential_profiles WHERE id = :id LIMIT 1")
    suspend fun getProfileById(id: Int): CredentialProfileEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertProfile(profile: CredentialProfileEntity): Long

    @Delete
    suspend fun deleteProfile(profile: CredentialProfileEntity)
}

@Dao
interface AlertRuleDao {
    @Query("SELECT * FROM alert_rules")
    fun getAllRulesFlow(): Flow<List<AlertRuleEntity>>

    @Query("SELECT * FROM alert_rules")
    suspend fun getAllRules(): List<AlertRuleEntity>

    @Query("SELECT * FROM alert_rules WHERE serverId = :serverId")
    suspend fun getRulesForServer(serverId: Int): List<AlertRuleEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertRule(rule: AlertRuleEntity)

    @Delete
    suspend fun deleteRule(rule: AlertRuleEntity)

    @Query("DELETE FROM alert_rules WHERE serverId NOT IN (:keepServerIds)")
    suspend fun deleteExceptServers(keepServerIds: List<Int>)
}

@Dao
interface ActiveAlertDao {
    @Query("SELECT * FROM active_alerts ORDER BY triggeredTime DESC")
    fun getActiveAlertsFlow(): Flow<List<ActiveAlertEntity>>

    @Query("SELECT * FROM active_alerts ORDER BY triggeredTime DESC")
    suspend fun getActiveAlerts(): List<ActiveAlertEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAlert(alert: ActiveAlertEntity)

    @Query("DELETE FROM active_alerts WHERE id = :id")
    suspend fun deleteAlert(id: Int)

    @Query("UPDATE active_alerts SET acknowledged = :acknowledged WHERE id = :id")
    suspend fun setAcknowledged(id: Int, acknowledged: Boolean)

    @Query("UPDATE active_alerts SET acknowledged = 1")
    suspend fun acknowledgeAll()

    @Query("UPDATE active_alerts SET mutedUntil = :mutedUntil WHERE id = :id")
    suspend fun muteAlert(id: Int, mutedUntil: Long)

    @Query("DELETE FROM active_alerts WHERE serverId NOT IN (:keepServerIds)")
    suspend fun deleteExceptServers(keepServerIds: List<Int>)
}

@Dao
interface AlertHistoryDao {
    @Query("SELECT * FROM alert_history ORDER BY historyTime DESC")
    fun getAlertHistoryFlow(): Flow<List<AlertHistoryEntity>>

    @Query("SELECT * FROM alert_history ORDER BY historyTime DESC")
    suspend fun getAlertHistory(): List<AlertHistoryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertHistory(history: AlertHistoryEntity)

    @Query("DELETE FROM alert_history WHERE id NOT IN (SELECT id FROM alert_history ORDER BY historyTime DESC LIMIT :limit)")
    suspend fun pruneHistory(limit: Int)

    @Query("DELETE FROM alert_history")
    suspend fun clearHistory()

    @Query("DELETE FROM alert_history WHERE serverId NOT IN (:keepServerIds)")
    suspend fun deleteExceptServers(keepServerIds: List<Int>)
}

@Dao
interface QuickScriptDao {
    @Query("SELECT * FROM quick_scripts ORDER BY category ASC, sortOrder ASC, name ASC")
    fun getAllScriptsFlow(): Flow<List<QuickScriptEntity>>

    @Query("SELECT * FROM quick_scripts ORDER BY category ASC, sortOrder ASC, name ASC")
    suspend fun getAllScripts(): List<QuickScriptEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertScript(script: QuickScriptEntity)

    @Delete
    suspend fun deleteScript(script: QuickScriptEntity)
}

@Dao
interface WolTargetDao {
    @Query("SELECT * FROM wol_targets ORDER BY name ASC")
    fun getAllWolTargetsFlow(): Flow<List<WolTargetEntity>>

    @Query("SELECT * FROM wol_targets ORDER BY name ASC")
    suspend fun getAllWolTargets(): List<WolTargetEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertWolTarget(target: WolTargetEntity)

    @Query("UPDATE wol_targets SET lastWokenTime = :time WHERE id = :id")
    suspend fun updateLastWoken(id: Int, time: Long)

    @Delete
    suspend fun deleteWolTarget(target: WolTargetEntity)
}

@Dao
interface AppSettingDao {
    @Query("SELECT * FROM app_settings WHERE `key` = :key LIMIT 1")
    suspend fun getSetting(key: String): AppSettingEntity?

    @Query("SELECT * FROM app_settings")
    fun getAllSettingsFlow(): Flow<List<AppSettingEntity>>

    @Query("SELECT * FROM app_settings")
    suspend fun getAllSettings(): List<AppSettingEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSetting(setting: AppSettingEntity)

    @Query("DELETE FROM app_settings WHERE `key` = :key")
    suspend fun deleteSetting(key: String)

    @Query("DELETE FROM app_settings WHERE `key` LIKE 'sftp_bookmarks_%' AND `key` NOT IN (:keepKeys)")
    suspend fun deleteSftpBookmarksExcept(keepKeys: List<String>)
}

@Dao
interface PersistentSessionDao {
    @Query("SELECT * FROM persistent_sessions ORDER BY createdAt ASC")
    suspend fun getAll(): List<PersistentSessionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(session: PersistentSessionEntity)

    @Query("DELETE FROM persistent_sessions WHERE tmuxName = :tmuxName")
    suspend fun delete(tmuxName: String)

    @Query("DELETE FROM persistent_sessions WHERE serverId = :serverId")
    suspend fun deleteForServer(serverId: Int)
}
