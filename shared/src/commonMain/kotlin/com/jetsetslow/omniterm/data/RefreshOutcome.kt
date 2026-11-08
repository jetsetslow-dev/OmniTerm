package com.jetsetslow.omniterm.data

/**
 * One host's state exactly as the Servers list renders it, so a pull-to-refresh can report on the
 * same thing the user is looking at.
 *
 * [probed] mirrors `AppViewModel.probedServerIds`: a host that has never completed a probe shows
 * the "Checking host…" spinner regardless of the status column, because the stored `offline` is
 * only the startup reset at that point.
 */
data class RefreshHostState(
    val name: String,
    val status: String,
    val probed: Boolean,
    val authStatus: String,
    val authError: String?,
)

/**
 * Turns the post-refresh state of the fleet into the one sentence the user should be told, or null
 * when everything is fine.
 *
 * Pulled out of the view model so the rule is testable and so Kotlin and Flutter can be held to the
 * same wording. It exists because a pull-to-refresh used to report nothing at all: a host whose
 * probe never reached a verdict simply sat on "Checking host…" indefinitely with no error and
 * nothing to retry, which reads as the app being broken rather than the host being slow.
 */
object RefreshOutcome {

    /** True while the row would still render the "Checking host…" spinner. */
    fun isStillChecking(host: RefreshHostState): Boolean =
        host.status == "connecting" || !host.probed

    fun describe(hosts: List<RefreshHostState>, waitedSeconds: Long): String? {
        val problems = buildList {
            for (h in hosts) {
                when {
                    isStillChecking(h) -> add("${h.name} is still not answering after ${waitedSeconds}s")
                    h.status == "offline" -> add("${h.name} did not respond on its configured SSH route")
                    h.authStatus == "failed" -> add("${h.name}: ${h.authError ?: "SSH authentication failed."}")
                }
            }
        }
        if (problems.isEmpty()) return null
        return "Refresh problem on ${problems.size} host(s): ${problems.joinToString("; ")}"
    }
}
