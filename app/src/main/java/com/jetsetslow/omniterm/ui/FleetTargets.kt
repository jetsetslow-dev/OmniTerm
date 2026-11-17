package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.FleetTargetSetEntity
import com.jetsetslow.omniterm.data.HostTags
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * What a Fleet run is for: picked hosts, every host in the picked groups, or the hosts with the
 * picked tags (all of them when [allTags], any otherwise). Whether a host is online is decided
 * where the targets are used; [matches] only says whether it is one of them.
 *
 * Idea credit: Termix Fleets' tag rules and Termius' saved targets.
 */
internal data class FleetTargets(
    val mode: FleetTargetMode,
    val serverIds: Set<Int> = emptySet(),
    val groups: Set<String> = emptySet(),
    val tags: List<String> = emptyList(),
    val allTags: Boolean = false,
) {
    fun matches(host: ServerEntity): Boolean = when (mode) {
        FleetTargetMode.Servers -> host.id in serverIds
        FleetTargetMode.Groups -> host.groupName.orEmpty() in groups
        FleetTargetMode.Tags -> tags.isNotEmpty() &&
            if (allTags) tags.all { HostTags.has(host, it) } else tags.any { HostTags.has(host, it) }
    }

    /** Nothing is picked in this mode. */
    val isEmpty: Boolean
        get() = when (mode) {
            FleetTargetMode.Servers -> serverIds.isEmpty()
            FleetTargetMode.Groups -> groups.isEmpty()
            FleetTargetMode.Tags -> tags.isEmpty()
        }

    /** These targets saved as [name]; only this mode's picks are kept. */
    fun toSet(name: String, id: Int = 0) = FleetTargetSetEntity(
        id = id,
        name = name.trim().take(MAX_NAME),
        mode = mode.name,
        serverIds = if (mode == FleetTargetMode.Servers) jsonOf(serverIds.sorted().map(::JsonPrimitive)) else "[]",
        groups = if (mode == FleetTargetMode.Groups) jsonOf(groups.sorted().map(::JsonPrimitive)) else "[]",
        tags = if (mode == FleetTargetMode.Tags) jsonOf(tags.map(::JsonPrimitive)) else "[]",
        allTags = mode == FleetTargetMode.Tags && allTags,
    )

    companion object {
        /** The longest name a saved set takes. */
        const val MAX_NAME = 60

        /** A saved set's targets; an unknown mode reads as hosts, and unreadable lists as empty. */
        fun of(set: FleetTargetSetEntity) = of(set.mode, set.serverIds, set.groups, set.tags, set.allTags)

        /** A schedule's targets, kept as a saved set keeps them. */
        fun of(schedule: FleetScheduleEntity) =
            of(schedule.mode, schedule.serverIds, schedule.groups, schedule.tags, schedule.allTags)

        private fun of(mode: String, serverIds: String, groups: String, tags: String, allTags: Boolean) = FleetTargets(
            mode = FleetTargetMode.entries.firstOrNull { it.name == mode } ?: FleetTargetMode.Servers,
            serverIds = list(serverIds).mapNotNull { it.intOrNull }.toSet(),
            groups = list(groups).mapNotNull { it.contentOrNull }.toSet(),
            tags = HostTags.parse(list(tags).mapNotNull { it.contentOrNull }.joinToString(",")),
            allTags = allTags,
        )

        private fun jsonOf(items: List<JsonPrimitive>) = JsonArray(items).toString()

        private fun list(json: String): List<JsonPrimitive> =
            runCatching { Json.parseToJsonElement(json).jsonArray.map { it.jsonPrimitive } }.getOrDefault(emptyList())
    }
}

/**
 * Saved Fleet targets in a backup. They go with the hosts: a set of picked hosts keeps only the
 * hosts in the backup (and, restored, only the hosts that came back), and a set left with nothing
 * to run on is dropped. Sets of groups and tags need no hosts, so they always travel.
 */
internal object BackupFleetTargets {
    fun json(sets: List<FleetTargetSetEntity>, hostIds: Set<Int>): org.json.JSONArray {
        val arr = org.json.JSONArray()
        for (set in sets) {
            if (set.name.isBlank()) continue
            targetsJson(FleetTargets.of(set), hostIds)?.let { arr.put(it.put("name", set.name)) }
        }
        return arr
    }

    /** [targets] as a backup keeps them, hosts limited to [hostIds]; null when nothing is left to run on. */
    fun targetsJson(targets: FleetTargets, hostIds: Set<Int>): org.json.JSONObject? {
        val kept = targets.copy(serverIds = targets.serverIds.filterTo(mutableSetOf()) { it in hostIds })
        if (kept.isEmpty) return null
        return org.json.JSONObject()
            .put("mode", kept.mode.name)
            .put("serverIds", org.json.JSONArray(kept.serverIds.sorted()))
            .put("groups", org.json.JSONArray(kept.groups.sorted()))
            .put("tags", org.json.JSONArray(kept.tags))
            .put("allTags", kept.allTags)
    }

    /** The targets [targetsJson] wrote, hosts re-pointed through [hostIdMap]; null when nothing is left. */
    fun targetsFrom(o: org.json.JSONObject, hostIdMap: Map<Int, Int>): FleetTargets? {
        val mode = FleetTargetMode.entries.firstOrNull { it.name == o.optString("mode") } ?: return null
        return FleetTargets(
            mode = mode,
            serverIds = ints(o.optJSONArray("serverIds")).mapNotNullTo(mutableSetOf()) { hostIdMap[it] },
            groups = strings(o.optJSONArray("groups")).toSet(),
            tags = HostTags.parse(strings(o.optJSONArray("tags")).joinToString(",")),
            allTags = o.optBoolean("allTags", false),
        ).takeUnless { it.isEmpty }
    }

    /** A backup's name for a set or a schedule; null when it is blank or [taken] (lower-cased) has it. */
    fun freeName(o: org.json.JSONObject, taken: MutableSet<String>): String? {
        val name = o.optString("name", "").trim().take(FleetTargets.MAX_NAME)
        return name.takeIf { it.isNotEmpty() && taken.add(it.lowercase()) }
    }

    /**
     * The sets in [arr], their hosts re-pointed through [hostIdMap] (backup id to this phone's id).
     * A set named like one in [keepNames] is left out: the phone's own set of that name wins.
     */
    fun restore(arr: org.json.JSONArray?, hostIdMap: Map<Int, Int>, keepNames: Collection<String>): List<FleetTargetSetEntity> {
        val taken = keepNames.mapTo(mutableSetOf()) { it.trim().lowercase() }
        val sets = mutableListOf<FleetTargetSetEntity>()
        for (i in 0 until (arr?.length() ?: 0)) {
            val o = arr?.optJSONObject(i) ?: continue
            val targets = targetsFrom(o, hostIdMap) ?: continue
            val name = freeName(o, taken) ?: continue
            sets += targets.toSet(name)
        }
        return sets
    }

    private fun ints(arr: org.json.JSONArray?): List<Int> =
        (0 until (arr?.length() ?: 0)).mapNotNull { arr?.opt(it) as? Int }

    private fun strings(arr: org.json.JSONArray?): List<String> =
        (0 until (arr?.length() ?: 0)).mapNotNull { arr?.opt(it) as? String }
}

/**
 * Fleet's schedules in a backup, with Automation's tokens: each names its script by category and
 * name, as alert rules do, and keeps its hosts as saved sets do. A restored schedule is paused,
 * like automation, so nothing runs on its own until the user turns it on here.
 */
internal object BackupFleetSchedules {
    fun json(schedules: List<FleetScheduleEntity>, scriptRef: (Int) -> org.json.JSONObject?, hostIds: Set<Int>): org.json.JSONArray {
        val arr = org.json.JSONArray()
        for (s in schedules) {
            if (s.name.isBlank()) continue
            val script = scriptRef(s.scriptId) ?: continue
            val o = BackupFleetTargets.targetsJson(FleetTargets.of(s), hostIds) ?: continue
            arr.put(
                o.put("name", s.name).put("script", script).put("repeat", s.repeat).put("everyMinutes", s.everyMinutes)
                    .put("minuteOfDay", s.minuteOfDay).put("dayOfWeek", s.dayOfWeek).put("notify", RunNotify.of(s.notify))
                    .put("createdAt", s.createdAt),
            )
        }
        return arr
    }

    /**
     * The schedules in [arr], paused, on this phone's scripts ([scriptId]) and hosts ([hostIdMap]).
     * One whose script or hosts are not here is left out, and so is one named like one in
     * [keepNames]: the phone's own schedule of that name wins.
     */
    fun restore(
        arr: org.json.JSONArray?,
        scriptId: (org.json.JSONObject?) -> Int?,
        hostIdMap: Map<Int, Int>,
        keepNames: Collection<String>,
    ): List<FleetScheduleEntity> {
        val taken = keepNames.mapTo(mutableSetOf()) { it.trim().lowercase() }
        val out = mutableListOf<FleetScheduleEntity>()
        for (i in 0 until (arr?.length() ?: 0)) {
            val o = arr?.optJSONObject(i) ?: continue
            val script = scriptId(o.optJSONObject("script")) ?: continue
            val picks = BackupFleetTargets.targetsFrom(o, hostIdMap)?.toSet("") ?: continue
            val name = BackupFleetTargets.freeName(o, taken) ?: continue
            out += FleetScheduleEntity(
                name = name,
                scriptId = script,
                mode = picks.mode, serverIds = picks.serverIds, groups = picks.groups, tags = picks.tags, allTags = picks.allTags,
                repeat = o.optString("repeat").takeIf { it in FleetScheduleTiming.REPEATS } ?: FleetScheduleTiming.DAILY,
                everyMinutes = o.optInt("everyMinutes", 60).takeIf { it in FleetScheduleTiming.EVERY_MINUTES } ?: 60,
                minuteOfDay = o.optInt("minuteOfDay", 3 * 60).coerceIn(0, 24 * 60 - 1),
                dayOfWeek = o.optInt("dayOfWeek", 1).coerceIn(1, 7),
                enabled = false,
                notify = RunNotify.of(o.optString("notify")),
                createdAt = o.optLong("createdAt", 0L).takeIf { it > 0 } ?: System.currentTimeMillis(),
            )
        }
        return out
    }
}
