package com.jetsetslow.omniterm.ui

/**
 * Which of a Fleet run's hosts the cards show: all of them, or only those that did not succeed
 * ([failedOnly]), and only those with [query] in their name, output or note, in any case. What is
 * left groups as before ([FleetOutputGroups]). The shared report always has every host.
 */
internal data class FleetOutputFilter(val failedOnly: Boolean = false, val query: String = "") {
    val isOn: Boolean get() = failedOnly || query.isNotBlank()

    fun shows(item: BroadcastResultItem): Boolean {
        if (failedOnly && !item.didNotSucceed) return false
        val wanted = query.trim()
        return wanted.isEmpty() ||
            item.serverName.contains(wanted, ignoreCase = true) ||
            item.output.contains(wanted, ignoreCase = true) ||
            item.note?.contains(wanted, ignoreCase = true) == true
    }

    fun apply(items: List<BroadcastResultItem>): List<BroadcastResultItem> = if (isOn) items.filter(::shows) else items
}

/** A host that failed, or was not run after a failure or a stop: what Retry runs again. */
internal val BroadcastResultItem.didNotSucceed: Boolean
    get() = status == BroadcastStatus.Failure || status == BroadcastStatus.NotRun
