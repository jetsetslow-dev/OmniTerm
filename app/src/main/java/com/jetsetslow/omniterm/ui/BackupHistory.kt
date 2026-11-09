package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.FleetRunHostEntity
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.McpCallOutcome
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.StackRegistryEntity
import com.jetsetslow.omniterm.data.mcp.McpSettings
import org.json.JSONArray
import org.json.JSONObject

/** What an export read for [BackupHistory]'s sections; empty for a section left out. */
internal data class BackupHistoryRows(
    val sessions: List<PersistentSessionEntity> = emptyList(),
    val stacks: List<StackRegistryEntity> = emptyList(),
    val monitoring: List<MetricHistoryEntity> = emptyList(),
    val monitoringStepMs: Long = 0L,
    val fleetRuns: List<Pair<FleetRunEntity, List<FleetRunHostEntity>>> = emptyList(),
    val assistantCalls: List<McpCallEntity> = emptyList(),
    val automationGrants: List<AutomationGrantEntity> = emptyList(),
)

/**
 * The backup sections that are history and device state rather than settings: Fleet runs,
 * monitoring history, tmux sessions, Compose stacks and the AI assistant log. Each reads back with
 * the host ids the backup saved; the restore points them at this phone's hosts. A row that does
 * not make sense is skipped rather than failing the restore.
 */
internal object BackupHistory {
    /** Finest first: a backup keeps a point a minute when that fits, and coarser points when not. */
    val MONITORING_STEPS_MS = listOf(60_000L, 5 * 60_000L, 15 * 60_000L, 60 * 60_000L)

    /** About 8 MB of points, a quarter of what a restore reads, so the rest of a backup still fits. */
    const val MONITORING_MAX_POINTS = 160_000

    private const val DAY_MS = 24 * 60 * 60_000L

    /** The finest step whose points fit, or the coarsest: hourly, what the history charts show. */
    suspend fun monitoringStep(pointsAt: suspend (Long) -> Int): Long =
        MONITORING_STEPS_MS.firstOrNull { pointsAt(it) <= MONITORING_MAX_POINTS } ?: MONITORING_STEPS_MS.last()

    /**
     * One entry per host and day, each with its points as [time, cpu, ram, disk, latency, in, out,
     * temperature]: compact, and no array long enough for an older app's limits to refuse it.
     */
    fun monitoringJson(points: List<MetricHistoryEntity>, stepMs: Long): JSONArray {
        val out = JSONArray()
        points.groupBy { it.serverId to Math.floorDiv(it.timestamp, DAY_MS) }.forEach { (key, rows) ->
            val day = JSONArray()
            for (p in rows) {
                day.put(
                    JSONArray().put(p.timestamp).put(tenths(p.cpuUsage)).put(tenths(p.ramUsage)).put(tenths(p.diskUsage))
                        .put(p.latency).put(tenths(p.networkIn)).put(tenths(p.networkOut))
                        .put(p.cpuTemperatureC?.let(::tenths) ?: JSONObject.NULL),
                )
            }
            out.put(JSONObject().put("serverId", key.first).put("stepMs", stepMs).put("points", day))
        }
        return out
    }

    fun monitoringPointCount(arr: JSONArray?): Int =
        objects(arr).sumOf { it.optJSONArray("points")?.length() ?: 0 }

    /** The backup's points by the host id it saved them under. */
    fun monitoringFrom(arr: JSONArray?): Map<Int, List<MetricHistoryEntity>> {
        val byHost = mutableMapOf<Int, MutableList<MetricHistoryEntity>>()
        for (o in objects(arr)) {
            val serverId = o.optInt("serverId", 0).takeIf { it > 0 } ?: continue
            val points = o.optJSONArray("points") ?: continue
            for (i in 0 until points.length()) {
                val p = points.optJSONArray(i) ?: continue
                val time = p.optLong(0, 0L).takeIf { it > 0 } ?: continue
                val values = (1..6).map { p.optDouble(it, Double.NaN) }
                if (values.any { !it.isFinite() }) continue
                byHost.getOrPut(serverId) { mutableListOf() } += MetricHistoryEntity(
                    serverId = serverId,
                    timestamp = time,
                    cpuUsage = values[0].toFloat(),
                    ramUsage = values[1].toFloat(),
                    diskUsage = values[2].toFloat(),
                    latency = values[3].toInt(),
                    networkIn = values[4].toFloat(),
                    networkOut = values[5].toFloat(),
                    cpuTemperatureC = p.optDouble(7, Double.NaN).takeIf { it.isFinite() }?.toFloat(),
                )
            }
        }
        return byHost
    }

    fun fleetRunsJson(runs: List<Pair<FleetRunEntity, List<FleetRunHostEntity>>>): JSONArray = JSONArray().apply {
        for ((run, hosts) in runs) {
            put(
                JSONObject().put("runKey", run.runKey).put("startedAt", run.startedAt).put("finishedAt", run.finishedAt)
                    .put("command", run.command).put("scriptName", run.scriptName ?: JSONObject.NULL).put("source", run.source)
                    .put(
                        "hosts",
                        JSONArray().apply {
                            for (h in hosts) {
                                put(
                                    JSONObject().put("serverId", h.serverId).put("serverName", h.serverName).put("status", h.status)
                                        .put("note", h.note ?: JSONObject.NULL).put("output", h.output).put("truncated", h.truncated),
                                )
                            }
                        },
                    ),
            )
        }
    }

    /** Runs with their hosts, the hosts still under the ids the backup saved. */
    fun fleetRunsFrom(arr: JSONArray?): List<Pair<FleetRunEntity, List<FleetRunHostEntity>>> = objects(arr).mapNotNull { o ->
        val runKey = o.optString("runKey").trim().takeIf { it.isNotEmpty() && it.length <= 200 } ?: return@mapNotNull null
        val startedAt = o.optLong("startedAt", 0L).takeIf { it > 0 } ?: return@mapNotNull null
        val sources = setOf(
            FleetRunHistory.SOURCE_FLEET, FleetRunHistory.SOURCE_RETRY, FleetRunHistory.SOURCE_RUNBOOK,
            FleetRunHistory.SOURCE_AUTOMATION, FleetRunHistory.SOURCE_MCP,
        )
        val run = FleetRunEntity(
            runKey = runKey,
            startedAt = startedAt,
            finishedAt = o.optLong("finishedAt", startedAt).coerceAtLeast(startedAt),
            command = o.optString("command"),
            scriptName = nullableString(o, "scriptName"),
            source = o.optString("source").takeIf { it in sources } ?: FleetRunHistory.SOURCE_FLEET,
        )
        val statuses = BroadcastStatus.entries.mapTo(mutableSetOf()) { it.name }
        val hosts = objects(o.optJSONArray("hosts")).mapNotNull { h ->
            val serverId = h.optInt("serverId", 0).takeIf { it != 0 } ?: return@mapNotNull null
            FleetRunHistory.host(
                serverId = serverId,
                serverName = h.optString("serverName"),
                status = h.optString("status").takeIf { it in statuses } ?: BroadcastStatus.Failure.name,
                note = nullableString(h, "note"),
                output = h.optString("output"),
                truncated = h.optBoolean("truncated", false),
            )
        }.distinctBy { it.serverId }
        run to hosts
    }

    fun sessionsJson(sessions: List<PersistentSessionEntity>): JSONArray = JSONArray().apply {
        for (s in sessions) {
            put(
                JSONObject().put("serverId", s.serverId).put("serverName", s.serverName).put("tmuxName", s.tmuxName)
                    .put("createdAt", s.createdAt).put("backgroundedAt", s.backgroundedAt).put("adopted", s.adopted),
            )
        }
    }

    fun sessionsFrom(arr: JSONArray?): List<PersistentSessionEntity> = objects(arr).mapNotNull { o ->
        val tmuxName = o.optString("tmuxName").takeIf { it.isNotBlank() && it.length <= 200 } ?: return@mapNotNull null
        val serverId = o.optInt("serverId", 0).takeIf { it > 0 } ?: return@mapNotNull null
        val createdAt = o.optLong("createdAt", 0L).takeIf { it > 0 } ?: return@mapNotNull null
        PersistentSessionEntity(
            tmuxName = tmuxName,
            serverId = serverId,
            serverName = o.optString("serverName"),
            createdAt = createdAt,
            backgroundedAt = o.optLong("backgroundedAt", createdAt),
            adopted = o.optBoolean("adopted", false),
        )
    }

    fun stacksJson(stacks: List<StackRegistryEntity>): JSONArray = JSONArray().apply {
        for (s in stacks) {
            put(
                JSONObject().put("serverId", s.serverId).put("runtime", s.runtime).put("project", s.project)
                    .put("workingDir", s.workingDir).put("configFiles", s.configFiles).put("lastSeenAt", s.lastSeenAt),
            )
        }
    }

    fun stacksFrom(arr: JSONArray?): List<StackRegistryEntity> = objects(arr).mapNotNull { o ->
        val serverId = o.optInt("serverId", 0).takeIf { it > 0 } ?: return@mapNotNull null
        val runtime = o.optString("runtime").takeIf { it == "docker" || it == "podman" } ?: return@mapNotNull null
        val project = o.optString("project").takeIf { it.isNotBlank() } ?: return@mapNotNull null
        StackRegistryEntity(
            serverId = serverId,
            runtime = runtime,
            project = project,
            workingDir = o.optString("workingDir"),
            configFiles = o.optString("configFiles"),
            lastSeenAt = o.optLong("lastSeenAt", 0L),
        )
    }

    fun assistantCallsJson(calls: List<McpCallEntity>): JSONArray = JSONArray().apply {
        for (c in calls) {
            put(
                JSONObject().put("at", c.at).put("client", c.client).put("tool", c.tool)
                    .put("outcome", c.outcome).put("detail", c.detail),
            )
        }
    }

    fun assistantCallsFrom(arr: JSONArray?): List<McpCallEntity> = objects(arr).mapNotNull { o ->
        val at = o.optLong("at", 0L).takeIf { it > 0 } ?: return@mapNotNull null
        val outcomes = setOf(McpCallOutcome.OK, McpCallOutcome.FAILED, McpCallOutcome.REFUSED)
        McpCallEntity(
            at = at,
            client = o.optString("client"),
            tool = o.optString("tool"),
            outcome = o.optString("outcome").takeIf { it in outcomes } ?: McpCallOutcome.FAILED,
            detail = o.optString("detail"),
        )
    }

    private fun objects(arr: JSONArray?): List<JSONObject> =
        if (arr == null) emptyList() else (0 until arr.length()).mapNotNull(arr::optJSONObject)

    private fun nullableString(o: JSONObject, key: String): String? =
        if (!o.has(key) || o.isNull(key)) null else o.optString(key)

    private fun tenths(value: Float): Double = Math.round(value * 10.0) / 10.0
}

/**
 * Automation, the AI assistant and App Lock: what lets other apps, assistants or a person in. A
 * backup carries them, so a restored phone works as the old one did (user, Nov 9), but a restore
 * never switches automation or the assistant on, and never takes a lock away.
 */
internal object BackupAccess {
    /** App Lock's settings, restored only to turn a lock on (see [appLockToRestore]). */
    val APP_LOCK_SETTINGS = setOf("app_pin", "app_lock_enabled", "app_lock_grace_ms")

    private val SHA256_HEX = Regex("[0-9a-f]{64}")

    /**
     * The Automation section: each grant with its script by category and name, as alert rules
     * name theirs, and the hosts the backup has; and the assistant's settings, without its switch.
     */
    fun automationJson(
        grants: List<AutomationGrantEntity>,
        settings: Map<String, String>,
        scriptRef: (Int) -> JSONObject?,
        exportedServerIds: Set<Int>,
    ): JSONObject {
        val grantArr = JSONArray()
        for (g in grants) {
            val script = scriptRef(g.scriptId) ?: continue
            val hosts = Automation.parseServerIds(g.serverIds).filter { it in exportedServerIds }
            if (hosts.isEmpty()) continue
            grantArr.put(
                JSONObject().put("script", script).put("serverIds", JSONArray(hosts)).put("tokenHash", g.tokenHash)
                    .put("label", g.label).put("createdAt", g.createdAt).put("lastUsedAt", g.lastUsedAt ?: JSONObject.NULL),
            )
        }
        val out = JSONObject().put("grants", grantArr)
        if (settings[McpSettings.TOKEN_HASH] != null || settings[McpSettings.HOSTS] != null) {
            val tunnelHost = settings[McpSettings.TUNNEL_HOST]?.toIntOrNull()?.takeIf { it in exportedServerIds }
            out.put(
                "assistant",
                JSONObject()
                    .put("tokenHash", settings[McpSettings.TOKEN_HASH] ?: JSONObject.NULL)
                    .put("hosts", JSONArray(Automation.parseServerIds(settings[McpSettings.HOSTS].orEmpty()).filter { it in exportedServerIds }))
                    .put("anyCommand", settings[McpSettings.ANY_COMMAND] == "true")
                    .put("port", McpSettings.port(settings[McpSettings.PORT]) ?: JSONObject.NULL)
                    .put("tunnelHost", tunnelHost ?: JSONObject.NULL)
                    .put("tunnelPort", tunnelHost?.let { McpSettings.port(settings[McpSettings.TUNNEL_PORT]) } ?: JSONObject.NULL),
            )
        }
        return out
    }

    fun grantCount(obj: JSONObject?): Int = obj?.optJSONArray("grants")?.length() ?: 0

    fun hasAssistant(obj: JSONObject?): Boolean = obj?.optJSONObject("assistant") != null

    /**
     * The grants to add, pointed at this phone's scripts and hosts by [scriptId] and [serverId]. A
     * grant whose script, or every host, is not here is skipped; so is one with a malformed token.
     */
    fun grantsFrom(obj: JSONObject?, scriptId: (JSONObject?) -> Int?, serverId: (Int) -> Int?): List<AutomationGrantEntity> {
        val arr = obj?.optJSONArray("grants") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val tokenHash = o.optString("tokenHash").takeIf { SHA256_HEX.matches(it) } ?: return@mapNotNull null
            val script = scriptId(o.optJSONObject("script")) ?: return@mapNotNull null
            val ids = o.optJSONArray("serverIds")
            val hosts = (0 until (ids?.length() ?: 0)).mapNotNull { ids!!.optInt(it, 0).takeIf { id -> id > 0 }?.let(serverId) }
            if (hosts.isEmpty()) return@mapNotNull null
            AutomationGrantEntity(
                scriptId = script,
                serverIds = Automation.joinServerIds(hosts),
                tokenHash = tokenHash,
                label = o.optString("label").take(200),
                createdAt = o.optLong("createdAt", 0L).takeIf { it > 0 } ?: System.currentTimeMillis(),
                lastUsedAt = o.optLong("lastUsedAt", 0L).takeIf { it > 0 },
            )
        }.distinctBy { it.tokenHash }
    }

    /**
     * The assistant's settings to write, its hosts pointed at this phone's by [serverId], and its
     * switch off; null when the backup has none.
     */
    fun assistantFrom(obj: JSONObject?, serverId: (Int) -> Int?): Map<String, String>? {
        val o = obj?.optJSONObject("assistant") ?: return null
        val ids = o.optJSONArray("hosts")
        val hosts = (0 until (ids?.length() ?: 0)).mapNotNull { ids!!.optInt(it, 0).takeIf { id -> id > 0 }?.let(serverId) }
        val tunnelHost = o.optInt("tunnelHost", 0).takeIf { it > 0 }?.let(serverId)
        val out = mutableMapOf(
            McpSettings.ENABLED to "false",
            McpSettings.HOSTS to Automation.joinServerIds(hosts),
            McpSettings.ANY_COMMAND to o.optBoolean("anyCommand", false).toString(),
            McpSettings.TUNNEL_HOST to tunnelHost?.toString().orEmpty(),
        )
        o.optString("tokenHash").takeIf { SHA256_HEX.matches(it) }?.let { out[McpSettings.TOKEN_HASH] = it }
        McpSettings.port(o.opt("port")?.toString())?.let { out[McpSettings.PORT] = it.toString() }
        if (tunnelHost != null) McpSettings.port(o.opt("tunnelPort")?.toString())?.let { out[McpSettings.TUNNEL_PORT] = it.toString() }
        return out
    }

    /**
     * App Lock's settings to write from a backup's [settings]: all of them when the backup's lock
     * is on with a PIN, and none otherwise, so restoring an unlocked phone's backup never turns
     * this phone's lock off. Biometrics and the failed-attempt lockout stay with each phone.
     */
    fun appLockToRestore(settings: JSONObject?): Map<String, String> {
        val pin = settings?.optString("app_pin").orEmpty()
        if (pin.isBlank() || settings?.optString("app_lock_enabled") != "true") return emptyMap()
        val out = mutableMapOf("app_pin" to pin, "app_lock_enabled" to "true")
        settings.optString("app_lock_grace_ms").toLongOrNull()?.takeIf { it >= 0 }?.let { out["app_lock_grace_ms"] = it.toString() }
        return out
    }
}
