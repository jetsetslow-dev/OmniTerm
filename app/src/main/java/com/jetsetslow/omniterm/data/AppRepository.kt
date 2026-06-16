package com.jetsetslow.omniterm.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class AppRepository(private val db: AppDatabase) {
    // Server functions
    val serversFlow: Flow<List<ServerEntity>> =
        db.serverDao().getAllServersFlow().map { list -> list.map(::decryptServer) }
    suspend fun getAllServers(): List<ServerEntity> = db.serverDao().getAllServers().map(::decryptServer)
    suspend fun getServerById(id: Int): ServerEntity? = db.serverDao().getServerById(id)?.let(::decryptServer)
    suspend fun getServerByName(name: String): ServerEntity? = db.serverDao().getServerByName(name)?.let(::decryptServer)
    suspend fun insertServer(server: ServerEntity): Long = db.serverDao().insertServer(encryptServer(server))
    suspend fun updateServer(server: ServerEntity) = db.serverDao().updateServer(encryptServer(server))
    suspend fun updateConnectionState(id: Int, status: String, health: Int, latency: Int) =
        db.serverDao().updateConnectionState(id, status, health, latency)
    suspend fun resetAllConnectionStates() = db.serverDao().resetAllConnectionStates()
    suspend fun updateAuthState(id: Int, authStatus: String, authError: String?) =
        db.serverDao().updateAuthState(id, authStatus, authError)
    suspend fun deleteServer(server: ServerEntity) = db.serverDao().deleteServer(server)
    suspend fun keepOnlyServers(keepServerIds: Set<Int>) {
        val ids = keepServerIds.toList()
        if (ids.isEmpty()) return
        db.metricHistoryDao().deleteExceptServers(ids)
        db.alertRuleDao().deleteExceptServers(ids)
        db.activeAlertDao().deleteExceptServers(ids)
        db.alertHistoryDao().deleteExceptServers(ids)
        db.appSettingDao().deleteSftpBookmarksExcept(ids.map { "sftp_bookmarks_$it" })
        db.serverDao().deleteServersExcept(ids)
    }

    // Metric functions
    fun getMetricsForServerFlow(serverId: Int): Flow<List<MetricHistoryEntity>> = db.metricHistoryDao().getMetricsForServerFlow(serverId)
    suspend fun getMetricsForServer(serverId: Int): List<MetricHistoryEntity> = db.metricHistoryDao().getMetricsForServer(serverId)
    suspend fun getMetricsSince(serverId: Int, since: Long): List<MetricHistoryEntity> = db.metricHistoryDao().getMetricsSince(serverId, since)
    suspend fun insertMetric(metric: MetricHistoryEntity) = db.metricHistoryDao().insertMetric(metric)
    suspend fun pruneMetrics(cutoff: Long) = db.metricHistoryDao().pruneMetrics(cutoff)

    // SSH Key functions
    val keysFlow: Flow<List<SshKeyEntity>> =
        db.sshKeyDao().getAllKeysFlow().map { list -> list.map(::decryptKey) }
    suspend fun getAllKeys(): List<SshKeyEntity> = db.sshKeyDao().getAllKeys().map(::decryptKey)
    suspend fun insertKey(key: SshKeyEntity) = db.sshKeyDao().insertKey(encryptKey(key))
    suspend fun deleteKey(key: SshKeyEntity) = db.sshKeyDao().deleteKey(key)

    // Credential Profile functions
    val profilesFlow: Flow<List<CredentialProfileEntity>> =
        db.credentialProfileDao().getAllProfilesFlow().map { list -> list.map(::decryptProfile) }
    suspend fun getAllProfiles(): List<CredentialProfileEntity> = db.credentialProfileDao().getAllProfiles().map(::decryptProfile)
    suspend fun insertProfile(profile: CredentialProfileEntity) = db.credentialProfileDao().insertProfile(encryptProfile(profile))
    suspend fun deleteProfile(profile: CredentialProfileEntity) = db.credentialProfileDao().deleteProfile(profile)
    suspend fun getCredentialProfileById(id: Int): CredentialProfileEntity? = db.credentialProfileDao().getProfileById(id)?.let(::decryptProfile)

    // Alert Rule functions
    val rulesFlow: Flow<List<AlertRuleEntity>> = db.alertRuleDao().getAllRulesFlow()
    suspend fun getAllRules(): List<AlertRuleEntity> = db.alertRuleDao().getAllRules()
    suspend fun getRulesForServer(serverId: Int): List<AlertRuleEntity> = db.alertRuleDao().getRulesForServer(serverId)
    suspend fun insertRule(rule: AlertRuleEntity) = db.alertRuleDao().insertRule(rule)
    suspend fun deleteRule(rule: AlertRuleEntity) = db.alertRuleDao().deleteRule(rule)

    // Active Alert functions
    val activeAlertsFlow: Flow<List<ActiveAlertEntity>> = db.activeAlertDao().getActiveAlertsFlow()
    suspend fun getActiveAlerts(): List<ActiveAlertEntity> = db.activeAlertDao().getActiveAlerts()
    suspend fun insertAlert(alert: ActiveAlertEntity) = db.activeAlertDao().insertAlert(alert)
    suspend fun deleteAlert(id: Int) = db.activeAlertDao().deleteAlert(id)
    suspend fun setAcknowledged(id: Int, ack: Boolean) = db.activeAlertDao().setAcknowledged(id, ack)
    suspend fun acknowledgeAll() = db.activeAlertDao().acknowledgeAll()
    suspend fun muteAlert(id: Int, mutedUntil: Long) = db.activeAlertDao().muteAlert(id, mutedUntil)

    // Alert History functions
    val alertHistoryFlow: Flow<List<AlertHistoryEntity>> = db.alertHistoryDao().getAlertHistoryFlow()
    suspend fun getAlertHistory(): List<AlertHistoryEntity> = db.alertHistoryDao().getAlertHistory()
    suspend fun insertAlertHistory(history: AlertHistoryEntity) = db.alertHistoryDao().insertHistory(history)
    suspend fun pruneAlertHistory(limit: Int) = db.alertHistoryDao().pruneHistory(limit.coerceAtLeast(1))
    suspend fun clearAlertHistory() = db.alertHistoryDao().clearHistory()

    // Quick Script functions
    val scriptsFlow: Flow<List<QuickScriptEntity>> = db.quickScriptDao().getAllScriptsFlow()
    suspend fun getAllScripts(): List<QuickScriptEntity> = db.quickScriptDao().getAllScripts()
    suspend fun insertScript(script: QuickScriptEntity) = db.quickScriptDao().insertScript(script)
    suspend fun deleteScript(script: QuickScriptEntity) = db.quickScriptDao().deleteScript(script)

    // WOL Target functions
    val wolTargetsFlow: Flow<List<WolTargetEntity>> = db.wolTargetDao().getAllWolTargetsFlow()
    suspend fun getAllWolTargets(): List<WolTargetEntity> = db.wolTargetDao().getAllWolTargets()
    suspend fun insertWolTarget(target: WolTargetEntity) = db.wolTargetDao().insertWolTarget(target)
    suspend fun updateLastWoken(id: Int, time: Long) = db.wolTargetDao().updateLastWoken(id, time)
    suspend fun deleteWolTarget(target: WolTargetEntity) = db.wolTargetDao().deleteWolTarget(target)

    // App Settings functions
    val settingsFlow: Flow<List<AppSettingEntity>> =
        db.appSettingDao().getAllSettingsFlow().map { list -> list.map(::decryptSetting) }
    suspend fun getAllSettings(): List<AppSettingEntity> = db.appSettingDao().getAllSettings().map(::decryptSetting)
    suspend fun getSetting(key: String): String? = db.appSettingDao().getSetting(key)?.let(::decryptSetting)?.value
    suspend fun insertSetting(key: String, value: String) =
        db.appSettingDao().insertSetting(encryptSetting(AppSettingEntity(key, value)))
    suspend fun deleteSetting(key: String) = db.appSettingDao().deleteSetting(key)

    private fun decryptServer(server: ServerEntity): ServerEntity = server.copy(
        authPassword = SecretStore.decrypt(server.authPassword),
        sudoPassword = SecretStore.decrypt(server.sudoPassword) ?: "",
        proxyPassword = SecretStore.decrypt(server.proxyPassword) ?: "",
    )

    private fun encryptServer(server: ServerEntity): ServerEntity = server.copy(
        authPassword = SecretStore.encrypt(server.authPassword),
        sudoPassword = SecretStore.encrypt(server.sudoPassword) ?: "",
        proxyPassword = SecretStore.encrypt(server.proxyPassword) ?: "",
    )

    private fun decryptKey(key: SshKeyEntity): SshKeyEntity =
        key.copy(privateKey = SecretStore.decrypt(key.privateKey) ?: "")

    private fun encryptKey(key: SshKeyEntity): SshKeyEntity =
        key.copy(privateKey = SecretStore.encrypt(key.privateKey) ?: "")

    private fun decryptProfile(profile: CredentialProfileEntity): CredentialProfileEntity =
        profile.copy(password = SecretStore.decrypt(profile.password))

    private fun encryptProfile(profile: CredentialProfileEntity): CredentialProfileEntity =
        profile.copy(password = SecretStore.encrypt(profile.password))

    private fun decryptSetting(setting: AppSettingEntity): AppSettingEntity =
        if (setting.key in secureSettingKeys) setting.copy(value = SecretStore.decrypt(setting.value) ?: "") else setting

    private fun encryptSetting(setting: AppSettingEntity): AppSettingEntity =
        if (setting.key in secureSettingKeys) setting.copy(value = SecretStore.encrypt(setting.value) ?: "") else setting

    companion object {
        private val secureSettingKeys = setOf("app_pin")
    }
}
