package com.jetsetslow.omniterm.ui

/**
 * Fleet hosts that ended the same way, gathered so a run on many hosts shows one card for each
 * different result ("9 hosts, same result") rather than nine identical ones. The live cards, the
 * history's and the shared report all group this way.
 *
 * Hosts match on status, output, note and whether the output was cut. Only hosts whose card has
 * nothing to do group ([GROUPED]): a running host's output is still changing, and a dropped tmux
 * run or a host without tmux has actions of its own. Groups keep the place of their first host.
 *
 * Idea credit: ClusterShell's `clush -b` and pdsh's `dshbak -c`, which gather hosts with identical
 * output.
 */
internal object FleetOutputGroups {
    /** The statuses whose card has no actions ([BroadcastHostFooter]'s empty case). */
    private val GROUPED = setOf(BroadcastStatus.Success, BroadcastStatus.Failure, BroadcastStatus.Waiting, BroadcastStatus.NotRun)

    private data class Result(val status: BroadcastStatus, val output: String, val note: String?, val truncated: Boolean)

    /** [items] in groups of hosts with the same result, in the order their first host is in. */
    fun group(items: List<BroadcastResultItem>): List<List<BroadcastResultItem>> {
        val groups = LinkedHashMap<Any, MutableList<BroadcastResultItem>>()
        for (item in items) {
            val key: Any = if (item.status in GROUPED) Result(item.status, item.output, item.note, item.truncated) else item.serverId
            groups.getOrPut(key) { mutableListOf() }.add(item)
        }
        return groups.values.toList()
    }
}
