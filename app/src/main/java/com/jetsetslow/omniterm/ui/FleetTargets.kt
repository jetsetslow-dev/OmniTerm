package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.FleetTargetSetEntity
import com.jetsetslow.omniterm.data.HostTags
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
        fun of(set: FleetTargetSetEntity) = FleetTargets(
            mode = FleetTargetMode.entries.firstOrNull { it.name == set.mode } ?: FleetTargetMode.Servers,
            serverIds = list(set.serverIds).mapNotNull { it.intOrNull }.toSet(),
            groups = list(set.groups).mapNotNull { it.contentOrNull }.toSet(),
            tags = HostTags.parse(list(set.tags).mapNotNull { it.contentOrNull }.joinToString(",")),
            allTags = set.allTags,
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
            val targets = FleetTargets.of(set).let { it.copy(serverIds = it.serverIds.filterTo(mutableSetOf()) { id -> id in hostIds }) }
            if (targets.isEmpty || set.name.isBlank()) continue
            arr.put(org.json.JSONObject().apply {
                put("name", set.name)
                put("mode", targets.mode.name)
                put("serverIds", org.json.JSONArray(targets.serverIds.sorted()))
                put("groups", org.json.JSONArray(targets.groups.sorted()))
                put("tags", org.json.JSONArray(targets.tags))
                put("allTags", targets.allTags)
            })
        }
        return arr
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
            val name = o.optString("name", "").trim().take(FleetTargets.MAX_NAME)
            if (name.isEmpty() || !taken.add(name.lowercase())) continue
            val mode = FleetTargetMode.entries.firstOrNull { it.name == o.optString("mode") } ?: continue
            val targets = FleetTargets(
                mode = mode,
                serverIds = ints(o.optJSONArray("serverIds")).mapNotNullTo(mutableSetOf()) { hostIdMap[it] },
                groups = strings(o.optJSONArray("groups")).toSet(),
                tags = HostTags.parse(strings(o.optJSONArray("tags")).joinToString(",")),
                allTags = o.optBoolean("allTags", false),
            )
            if (!targets.isEmpty) sets += targets.toSet(name)
        }
        return sets
    }

    private fun ints(arr: org.json.JSONArray?): List<Int> =
        (0 until (arr?.length() ?: 0)).mapNotNull { arr?.opt(it) as? Int }

    private fun strings(arr: org.json.JSONArray?): List<String> =
        (0 until (arr?.length() ?: 0)).mapNotNull { arr?.opt(it) as? String }
}
