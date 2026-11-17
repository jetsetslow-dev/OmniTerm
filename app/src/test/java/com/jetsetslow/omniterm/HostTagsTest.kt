package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.HostTags
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.FleetTargets
import com.jetsetslow.omniterm.ui.hostMatchesSearch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host tags and the Fleet targets built on them: a run on "every host tagged prod" must reach
 * exactly those hosts, whatever case the tag was typed in, and a saved set must read back as saved.
 */
class HostTagsTest {

    @Test
    fun tagsAreTrimmedDedupedWithoutRegardToCaseAndKeepTheirFirstSpelling() {
        assertEquals(listOf("Prod", "db"), HostTags.parse(" Prod , db,, prod ,DB "))
        assertEquals("Prod, db", HostTags.format(listOf("Prod", " db", "PROD", "")))
        assertEquals(emptyList<String>(), HostTags.parse(" , ,"))
    }

    @Test
    fun aHostTakesAtMostTwentyTagsOfThirtyTwoCharacters() {
        val many = (1..30).joinToString(",") { "t$it" }
        assertEquals(HostTags.MAX_TAGS, HostTags.parse(many).size)
        assertEquals("x".repeat(HostTags.MAX_LENGTH), HostTags.parse("x".repeat(50)).single())
    }

    @Test
    fun everyTagOnTheHostsIsListedOnceInOrder() {
        assertEquals(listOf("db", "Prod", "web"), HostTags.all(listOf(host(1, "Prod, web"), host(2, "prod, db"), host(3, ""))))
        assertTrue(HostTags.has(host(1, "Prod, web"), "PROD"))
        assertFalse(HostTags.has(host(1, "production"), "prod"))
    }

    @Test
    fun tagTargetsReachHostsWithAnyOrEveryPickedTag() {
        val hosts = listOf(host(1, "db, prod"), host(2, "prod"), host(3, "db"), host(4, ""))
        val any = FleetTargets(FleetTargetMode.Tags, tags = listOf("db", "prod"))
        assertEquals(listOf(1, 2, 3), hosts.filter(any::matches).map { it.id })
        val every = any.copy(allTags = true)
        assertEquals(listOf(1), hosts.filter(every::matches).map { it.id })
        assertTrue("no tags picked reaches nothing", hosts.none(FleetTargets(FleetTargetMode.Tags)::matches))
    }

    @Test
    fun groupAndHostTargetsIgnoreTags() {
        val hosts = listOf(host(1, "prod", group = "Rack"), host(2, "prod"), host(3, "", group = "Rack"))
        assertEquals(listOf(1, 3), hosts.filter(FleetTargets(FleetTargetMode.Groups, groups = setOf("Rack"))::matches).map { it.id })
        assertEquals(listOf(2), hosts.filter(FleetTargets(FleetTargetMode.Servers, serverIds = setOf(2))::matches).map { it.id })
    }

    @Test
    fun aSavedSetKeepsOnlyItsModesPicksAndReadsBackTheSame() {
        val targets = FleetTargets(FleetTargetMode.Tags, serverIds = setOf(4, 2), groups = setOf("Rack"), tags = listOf("prod", "db"), allTags = true)
        val set = targets.toSet("  Prod DBs  ")
        assertEquals("Prod DBs", set.name)
        assertEquals("[]", set.serverIds)
        assertEquals("[]", set.groups)
        assertEquals(FleetTargets(FleetTargetMode.Tags, tags = listOf("prod", "db"), allTags = true), FleetTargets.of(set))

        val picked = FleetTargets(FleetTargetMode.Servers, serverIds = setOf(4, 2), tags = listOf("prod"), allTags = true).toSet("Pair")
        assertEquals("[2,4]", picked.serverIds)
        assertFalse("every-tag only applies to tags", picked.allTags)
        assertEquals(FleetTargets(FleetTargetMode.Servers, serverIds = setOf(2, 4)), FleetTargets.of(picked))
        assertEquals(FleetTargets.MAX_NAME, FleetTargets(FleetTargetMode.Groups, groups = setOf("g")).toSet("n".repeat(99)).name.length)
    }

    @Test
    fun anUnreadableSetReadsAsHostsWithNothingPicked() {
        val set = FleetTargets(FleetTargetMode.Groups, groups = setOf("Rack")).toSet("Odd").copy(mode = "Planets", serverIds = "not json")
        val read = FleetTargets.of(set)
        assertEquals(FleetTargetMode.Servers, read.mode)
        assertTrue(read.isEmpty)
    }

    @Test
    fun searchFindsHostsByTagWithOrWithoutTheHash() {
        val nas = host(1, "storage, Prod", name = "nas")
        assertTrue(hostMatchesSearch(nas, "#prod"))
        assertTrue(hostMatchesSearch(nas, "stor"))
        assertTrue(hostMatchesSearch(nas, "nas"))
        assertFalse(hostMatchesSearch(nas, "#web"))
        assertTrue("an empty search shows every host", hostMatchesSearch(nas, ""))
    }

    private fun host(id: Int, tags: String, group: String? = null, name: String = "h$id") = ServerEntity(
        id = id, name = name, host = "$name.lan", port = 22, username = "u", authType = "password", groupName = group, tags = tags,
    )
}
