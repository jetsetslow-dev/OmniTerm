package com.jetsetslow.omniterm.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Fleet hosts that ended the same way share one card and one report section; anything that tells
 * them apart, or a card with something left to do, keeps a host on its own.
 */
class FleetOutputGroupsTest {
    private fun host(id: Int, status: BroadcastStatus = BroadcastStatus.Success, output: String = "ok\n", note: String? = null, truncated: Boolean = false) =
        BroadcastResultItem(serverId = id, serverName = "h$id", output = output, status = status, note = note, truncated = truncated)

    private fun ids(groups: List<List<BroadcastResultItem>>) = groups.map { group -> group.map { it.serverId } }

    @Test
    fun hostsThatEndedTheSameWayShareAGroupInTheirFirstHostsPlace() {
        val groups = FleetOutputGroups.group(
            listOf(host(1), host(2, output = "other\n"), host(3), host(4, BroadcastStatus.Failure, "", "Exited with status 1."), host(5)),
        )
        assertEquals(listOf(listOf(1, 3, 5), listOf(2), listOf(4)), ids(groups))
    }

    @Test
    fun anythingThatTellsThemApartKeepsThemApart() {
        val groups = FleetOutputGroups.group(
            listOf(
                host(1),
                host(2, output = "ok"),
                host(3, BroadcastStatus.Failure),
                host(4, note = "Took 3 tries."),
                host(5, truncated = true),
            ),
        )
        assertEquals(listOf(listOf(1), listOf(2), listOf(3), listOf(4), listOf(5)), ids(groups))
    }

    @Test
    fun waitingAndNotRunHostsGroupButHostsWithSomethingToDoNeverDo() {
        val notRun = "Not run: h1 did not succeed, and the run stops on a failure."
        val groups = FleetOutputGroups.group(
            listOf(
                host(1, BroadcastStatus.Waiting, ""),
                host(2, BroadcastStatus.Waiting, ""),
                host(3, BroadcastStatus.NotRun, "", notRun),
                host(4, BroadcastStatus.NotRun, "", notRun),
                host(5, BroadcastStatus.Running),
                host(6, BroadcastStatus.Running),
                host(7, BroadcastStatus.NeedsTmux, ""),
                host(8, BroadcastStatus.NeedsTmux, ""),
                host(9, BroadcastStatus.Reconnecting),
                host(10, BroadcastStatus.Reconnecting),
                host(11, BroadcastStatus.Detached),
                host(12, BroadcastStatus.Detached),
            ),
        )
        assertEquals(
            listOf(listOf(1, 2), listOf(3, 4), listOf(5), listOf(6), listOf(7), listOf(8), listOf(9), listOf(10), listOf(11), listOf(12)),
            ids(groups),
        )
    }
}
