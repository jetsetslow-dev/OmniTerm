package com.jetsetslow.omniterm.data

import androidx.room.withTransaction
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class AppRepository(private val db: AppDatabase) {
    suspend fun <T> inTransaction(block: suspend () -> T): T = db.withTransaction(block)

    // Server functions
    val serversFlow: Flow<List<ServerEntity>> =
        db.serverDao().getAllServersFlow().map { list -> list.map(::decryptServer) }
    suspend fun getAllServers(): List<ServerEntity> = db.serverDao().getAllServers().map(::decryptServer)
    suspend fun getServerById(id: Int): ServerEntity? = db.serverDao().getServerById(id)?.let(::decryptServer)
    suspend fun getServerByName(name: String): ServerEntity? = db.serverDao().getServerByName(name)?.let(::decryptServer)
    suspend fun findMatchingServer(candidate: ServerEntity): ServerEntity? {
        val profiles = getAllProfiles()
        val identity = serverIdentity(candidate, profiles) ?: return null
        return getAllServers().firstOrNull { it.id != candidate.id && serverIdentity(it, profiles) == identity }
    }

    suspend fun saveUniqueServer(server: ServerEntity, update: Boolean = false): Long = db.withTransaction {
        val existing = findMatchingServer(server)
        require(existing == null) {
            "The same host, port, SSH user and authentication method already exist as \"${existing?.name}\". Existing server unchanged."
        }
        if (update) {
            updateServer(server)
            server.id.toLong()
        } else insertServer(server)
    }
    suspend fun insertServer(server: ServerEntity): Long = db.serverDao().insertServer(encryptServer(server))
    suspend fun updateServer(server: ServerEntity) = db.serverDao().updateServer(encryptServer(server))
    suspend fun updateConnectionState(id: Int, status: String, health: Int, latency: Int) =
        db.serverDao().updateConnectionState(id, status, health, latency)
    suspend fun resetAllConnectionStates() = db.serverDao().resetAllConnectionStates()
    suspend fun updateReachability(id: Int, status: String, latency: Int) =
        db.serverDao().updateReachability(id, status, latency)
    suspend fun updateHealthScore(id: Int, health: Int) = db.serverDao().updateHealthScore(id, health)
    suspend fun updateAuthState(id: Int, authStatus: String, authError: String?) =
        db.serverDao().updateAuthState(id, authStatus, authError)
    suspend fun deleteServer(server: ServerEntity) = db.serverDao().deleteServer(server)
    suspend fun deleteServerAndDependents(serverId: Int) = db.withTransaction {
        db.metricHistoryDao().deleteForServer(serverId)
        db.alertRuleDao().deleteForServer(serverId)
        db.activeAlertDao().deleteForServer(serverId)
        db.alertHistoryDao().deleteForServer(serverId)
        db.portForwardDao().deleteForServer(serverId)
        db.stackRegistryDao().deleteForServer(serverId)
        db.persistentSessionDao().deleteForServer(serverId)
        db.appSettingDao().deleteSetting("sftp_bookmarks_$serverId")
        db.serverDao().deleteById(serverId)
    }

    /** What [deleteServerAndDependents] takes with [serverIds], counted for the delete dialog. */
    suspend fun dependentCounts(serverIds: Set<Int>): HostDependentCounts = HostDependentCounts(
        bookmarks = serverIds.sumOf { id ->
            getSetting("sftp_bookmarks_$id").orEmpty().split("|||").count { it.isNotBlank() }
        },
        tunnels = getAllPortForwards().count { it.serverId in serverIds },
        alertRules = getAllRules().count { it.serverId in serverIds },
        savedTmuxSessions = getPersistentSessions().count { it.serverId in serverIds },
        composeStacks = serverIds.sumOf { getStacksForServer(it).size },
    )
    suspend fun keepOnlyServers(keepServerIds: Set<Int>) {
        // Room expands an empty IN-list inconsistently across SQLite versions. A server ID is an
        // auto-generated positive integer, so this impossible sentinel makes the "keep none" case
        // explicit while still preserving fleet-wide rule/alert/history rows with serverId == 0.
        val ids = keepServerIds.ifEmpty { setOf(Int.MIN_VALUE) }.toList()
        db.withTransaction {
            db.metricHistoryDao().deleteExceptServers(ids)
            db.alertRuleDao().deleteExceptServers(ids)
            db.activeAlertDao().deleteExceptServers(ids)
            db.alertHistoryDao().deleteExceptServers(ids)
            db.portForwardDao().deleteExceptServers(ids)
            db.stackRegistryDao().deleteExceptServers(ids)
            db.persistentSessionDao().deleteExceptServers(ids)
            db.appSettingDao().deleteSftpBookmarksExcept(ids.map { "sftp_bookmarks_$it" })
            db.serverDao().deleteServersExcept(ids)
        }
    }

    // Metric functions
    fun getMetricsForServerFlow(serverId: Int): Flow<List<MetricHistoryEntity>> = db.metricHistoryDao().getMetricsForServerFlow(serverId)
    suspend fun getMetricsForServer(serverId: Int): List<MetricHistoryEntity> = db.metricHistoryDao().getMetricsForServer(serverId)
    suspend fun getMetricsSince(serverId: Int, since: Long): List<MetricHistoryEntity> = db.metricHistoryDao().getMetricsSince(serverId, since)
    suspend fun latestMetric(serverId: Int): MetricHistoryEntity? = db.metricHistoryDao().latestForServer(serverId)
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
    suspend fun insertProfile(profile: CredentialProfileEntity): Long = db.withTransaction {
        if (profile.id > 0) {
            // Identity fields are plaintext; do not decrypt unrelated secrets for this check.
            val conflicts = profileServerConflicts(
                db.serverDao().getAllServers(), db.credentialProfileDao().getAllProfiles(), profile,
            )
            if (conflicts.isNotEmpty()) throw ProfileServerConflictException(conflicts)
        }
        db.credentialProfileDao().insertProfile(encryptProfile(profile))
    }
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
    suspend fun updateAlertCurrentValue(id: Int, currentValue: Float) =
        db.activeAlertDao().updateCurrentValue(id, currentValue)

    // Alert History functions
    val alertHistoryFlow: Flow<List<AlertHistoryEntity>> = db.alertHistoryDao().getAlertHistoryFlow()
    suspend fun getAlertHistory(): List<AlertHistoryEntity> = db.alertHistoryDao().getAlertHistory()
    suspend fun insertAlertHistory(history: AlertHistoryEntity) = db.alertHistoryDao().insertHistory(history)
    suspend fun pruneAlertHistoryForServer(serverId: Int, limit: Int) =
        db.alertHistoryDao().pruneHistoryForServer(serverId, limit.coerceIn(10, 100))
    suspend fun pruneAlertHistoryPerServer(limit: Int) =
        db.alertHistoryDao().pruneHistoryPerServer(limit.coerceIn(10, 100))
    suspend fun clearAlertHistory() = db.alertHistoryDao().clearHistory()

    // Quick Script functions
    val scriptsFlow: Flow<List<QuickScriptEntity>> = db.quickScriptDao().getAllScriptsFlow()
    suspend fun getAllScripts(): List<QuickScriptEntity> = db.quickScriptDao().getAllScripts()

    val mcpCallsFlow: Flow<List<McpCallEntity>> = db.mcpCallDao().callsFlow()
    suspend fun recordMcpCall(call: McpCallEntity, keep: Int = com.jetsetslow.omniterm.data.mcp.McpSettings.KEEP_CALLS) = db.withTransaction {
        db.mcpCallDao().insert(call)
        db.mcpCallDao().prune(keep)
    }
    suspend fun clearMcpCalls() = db.mcpCallDao().clear()
    suspend fun insertScript(script: QuickScriptEntity) = db.quickScriptDao().insertScript(script)
    /** Deletes [script] and takes it off every rule that offered it as a runbook. */
    suspend fun deleteScript(script: QuickScriptEntity) = db.withTransaction {
        db.quickScriptDao().deleteScript(script)
        db.alertRuleDao().clearRunbook(script.id)
        // A grant for a deleted script could never run; it goes with it.
        db.automationGrantDao().deleteForScript(script.id)
    }

    // Automation grants
    val automationGrantsFlow: Flow<List<AutomationGrantEntity>> = db.automationGrantDao().grantsFlow()
    suspend fun automationGrantByTokenHash(tokenHash: String): AutomationGrantEntity? = db.automationGrantDao().byTokenHash(tokenHash)
    suspend fun automationGrantById(id: Int): AutomationGrantEntity? = db.automationGrantDao().byId(id)
    suspend fun insertAutomationGrant(grant: AutomationGrantEntity): Int = db.automationGrantDao().insert(grant).toInt()
    suspend fun deleteAutomationGrant(id: Int) = db.automationGrantDao().delete(id)
    suspend fun markAutomationGrantUsed(id: Int, at: Long) = db.automationGrantDao().markUsed(id, at)

    // Fleet run history
    val fleetRunsFlow: Flow<List<FleetRunSummary>> = db.fleetRunDao().summariesFlow()
    suspend fun fleetRunHosts(runId: Int): List<FleetRunHostEntity> = db.fleetRunDao().hostsFor(runId)

    /**
     * Saves [run] with [hosts], updating an earlier save of the same run (same runKey): its row,
     * and the hosts given. A host left out keeps what was saved for it, so a retry, which takes
     * over the failed hosts' cards, leaves their first results in the run they failed in. Then
     * drops the runs past the newest [keep].
     */
    suspend fun recordFleetRun(run: FleetRunEntity, hosts: List<FleetRunHostEntity>, keep: Int = FleetRunHistory.KEEP_RUNS) =
        db.withTransaction {
            val dao = db.fleetRunDao()
            val earlier = dao.byKey(run.runKey)
            val id = dao.insertRun(run.copy(id = earlier?.id ?: 0, startedAt = earlier?.startedAt ?: run.startedAt)).toInt()
            dao.insertHosts(hosts.map { it.copy(runId = id) })
            for (old in dao.idsBeyond(keep)) {
                dao.deleteHostsOf(old)
                dao.deleteRunRow(old)
            }
        }

    suspend fun deleteFleetRun(runId: Int) = db.withTransaction {
        db.fleetRunDao().deleteHostsOf(runId)
        db.fleetRunDao().deleteRunRow(runId)
    }

    suspend fun clearFleetRuns() = db.withTransaction {
        db.fleetRunDao().clearHosts()
        db.fleetRunDao().clearRuns()
    }

    // WOL Target functions
    val telnetHostsFlow: Flow<List<TelnetHostEntity>> = db.telnetHostDao().getAllTelnetHostsFlow()
    suspend fun getAllTelnetHosts(): List<TelnetHostEntity> = db.telnetHostDao().getAllTelnetHosts()
    suspend fun insertTelnetHost(host: TelnetHostEntity): Long = db.telnetHostDao().insertTelnetHost(host)
    suspend fun deleteTelnetHost(host: TelnetHostEntity) = db.telnetHostDao().deleteTelnetHost(host)

    val kubeClustersFlow: Flow<List<KubeClusterEntity>> =
        db.kubeClusterDao().getAllKubeClustersFlow().map { list -> list.map(::decryptKubeCluster) }
    suspend fun getAllKubeClusters(): List<KubeClusterEntity> = db.kubeClusterDao().getAllKubeClusters().map(::decryptKubeCluster)
    suspend fun insertKubeCluster(cluster: KubeClusterEntity): Long = db.kubeClusterDao().insertKubeCluster(encryptKubeCluster(cluster))
    suspend fun deleteKubeCluster(id: Int) = db.kubeClusterDao().deleteKubeCluster(id)

    val wolTargetsFlow: Flow<List<WolTargetEntity>> = db.wolTargetDao().getAllWolTargetsFlow()
    suspend fun getAllWolTargets(): List<WolTargetEntity> = db.wolTargetDao().getAllWolTargets()
    suspend fun insertWolTarget(target: WolTargetEntity) = db.wolTargetDao().insertWolTarget(target)
    suspend fun updateLastWoken(id: Int, time: Long) = db.wolTargetDao().updateLastWoken(id, time)
    suspend fun deleteWolTarget(target: WolTargetEntity) = db.wolTargetDao().deleteWolTarget(target)

    // ── Port-forward tunnels ──
    val portForwardsFlow: Flow<List<PortForwardEntity>> = db.portForwardDao().getAllPortForwardsFlow()
    suspend fun getAllPortForwards(): List<PortForwardEntity> = db.portForwardDao().getAllPortForwards()
    suspend fun insertPortForward(pf: PortForwardEntity): Long = db.portForwardDao().insertPortForward(pf)
    suspend fun updatePortForward(pf: PortForwardEntity) = db.portForwardDao().updatePortForward(pf)
    suspend fun deletePortForward(pf: PortForwardEntity) = db.portForwardDao().deletePortForward(pf)

    // ── Compose stack registry (per-host record of stacks seen up, so downed stacks stay listed) ──
    suspend fun getStacksForServer(serverId: Int): List<StackRegistryEntity> = db.stackRegistryDao().getForServer(serverId)
    suspend fun upsertStacks(stacks: List<StackRegistryEntity>) = db.stackRegistryDao().upsertAll(stacks)
    suspend fun deleteStack(serverId: Int, runtime: String, project: String) = db.stackRegistryDao().delete(serverId, runtime, project)

    // Network share functions
    val networkSharesFlow: Flow<List<NetworkShareEntity>> =
        db.networkShareDao().getAllNetworkSharesFlow().map { list -> list.map(::decryptNetworkShare) }
    suspend fun getAllNetworkShares(): List<NetworkShareEntity> =
        db.networkShareDao().getAllNetworkShares().map(::decryptNetworkShare)
    suspend fun insertNetworkShare(share: NetworkShareEntity): Long =
        db.networkShareDao().insertNetworkShare(encryptNetworkShare(share))
    suspend fun updateNetworkShare(share: NetworkShareEntity) =
        db.networkShareDao().updateNetworkShare(encryptNetworkShare(share))
    suspend fun deleteNetworkShare(share: NetworkShareEntity) = db.networkShareDao().deleteNetworkShare(share)

    // App Settings functions
    val settingsFlow: Flow<List<AppSettingEntity>> =
        db.appSettingDao().getAllSettingsFlow().map { list -> list.map(::decryptSetting) }
    suspend fun getAllSettings(): List<AppSettingEntity> = db.appSettingDao().getAllSettings().map(::decryptSetting)
    suspend fun getSetting(key: String): String? = db.appSettingDao().getSetting(key)?.let(::decryptSetting)?.value
    suspend fun insertSetting(key: String, value: String) =
        db.appSettingDao().insertSetting(encryptSetting(AppSettingEntity(key, value)))
    suspend fun deleteSetting(key: String) = db.appSettingDao().deleteSetting(key)

    // Persistent (tmux) session tracking — runtime/device state, never backed up.
    suspend fun getLastSampleTimes(): List<ServerLastSample> = db.metricHistoryDao().getLastSampleTimes()
    suspend fun getPersistentSessions(): List<PersistentSessionEntity> = db.persistentSessionDao().getAll()
    suspend fun upsertPersistentSession(session: PersistentSessionEntity) = db.persistentSessionDao().upsert(session)
    suspend fun deletePersistentSession(serverId: Int, tmuxName: String) =
        db.persistentSessionDao().delete(serverId, tmuxName)
    suspend fun deletePersistentSessionsForServer(serverId: Int) = db.persistentSessionDao().deleteForServer(serverId)
    suspend fun renamePersistentSessionsForServer(serverId: Int, serverName: String) =
        db.persistentSessionDao().renameServer(serverId, serverName)

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

    private fun decryptKubeCluster(cluster: KubeClusterEntity): KubeClusterEntity =
        cluster.copy(clientKeyPem = SecretStore.decrypt(cluster.clientKeyPem) ?: "", token = SecretStore.decrypt(cluster.token) ?: "")

    private fun encryptKubeCluster(cluster: KubeClusterEntity): KubeClusterEntity =
        cluster.copy(clientKeyPem = SecretStore.encrypt(cluster.clientKeyPem) ?: "", token = SecretStore.encrypt(cluster.token) ?: "")

    private fun decryptNetworkShare(share: NetworkShareEntity): NetworkShareEntity =
        share.copy(password = SecretStore.decrypt(share.password) ?: "")

    private fun encryptNetworkShare(share: NetworkShareEntity): NetworkShareEntity =
        share.copy(password = SecretStore.encrypt(share.password) ?: "")

    private fun decryptSetting(setting: AppSettingEntity): AppSettingEntity =
        if (setting.key in secureSettingKeys) setting.copy(value = SecretStore.decrypt(setting.value) ?: "") else setting

    private fun encryptSetting(setting: AppSettingEntity): AppSettingEntity =
        if (setting.key in secureSettingKeys) setting.copy(value = SecretStore.encrypt(setting.value) ?: "") else setting

    companion object {
        private val secureSettingKeys = setOf("app_pin", AlertForwarding.SETTING_TOKEN)
    }
}

/**
 * The rows stored for some hosts that go when they are deleted. [trustedHostKeys] is filled in by
 * the caller, which knows which hosts stay.
 */
data class HostDependentCounts(
    val bookmarks: Int = 0,
    val tunnels: Int = 0,
    val alertRules: Int = 0,
    val savedTmuxSessions: Int = 0,
    val composeStacks: Int = 0,
    val trustedHostKeys: Int = 0,
)
