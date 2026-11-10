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

    /** Fleet's Schedules tab, for a schedule that could not run and so is not in the history. */
    fun fleetSchedules() = "omniterm://notification/$FLEET_SCHEDULES"
    const val FLEET_SCHEDULES = "fleet-schedules"

    /** A run another app or an AI assistant started: [runKey]'s run in Fleet's history. */
    fun fleetRun(runKey: String) = "omniterm://notification/fleet-run/$runKey"

    private val RUN_KEY = Regex("[A-Za-z0-9-]{1,80}")

    /**
     * The run key of a [fleetRun] link, from its path segments; null for any other link. Anything
     * can send this exported link, so only a key of the shape runs are given is read.
     */
    fun parseFleetRun(pathSegments: List<String>): String? {
        if (pathSegments.size != 2 || pathSegments[0] != "fleet-run") return null
        return pathSegments[1].takeIf(RUN_KEY::matches)
    }
}
