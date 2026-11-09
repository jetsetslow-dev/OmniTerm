package com.jetsetslow.omniterm.ui

/**
 * The `omniterm://notification/…` links a notification opens the app with, built and read in one
 * place so the two cannot drift apart.
 */
internal object NotificationLinks {
    /** An alert's "Run" action: [ruleId]'s runbook on [serverId]. */
    fun runbook(ruleId: Int, serverId: Int) = "omniterm://notification/runbook/$ruleId/$serverId"

    /** The rule and host of a [runbook] link, from its path segments; null for any other link. */
    fun parseRunbook(pathSegments: List<String>): Pair<Int, Int>? {
        if (pathSegments.size != 3 || pathSegments[0] != "runbook") return null
        val ruleId = pathSegments[1].toIntOrNull()?.takeIf { it > 0 } ?: return null
        val serverId = pathSegments[2].toIntOrNull()?.takeIf { it > 0 } ?: return null
        return ruleId to serverId
    }
}
