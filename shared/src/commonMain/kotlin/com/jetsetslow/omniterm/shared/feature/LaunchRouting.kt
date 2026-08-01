package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.platform.NotificationRoute
import com.jetsetslow.omniterm.shared.platform.validateNotificationRoute

/**
 * Something outside the app asked OmniTerm to go somewhere: a notification tap, a widget row, a
 * launcher shortcut, or an iOS quick action. Ported from Android's `ExternalLaunchRequest`.
 */
sealed interface LaunchRequest {
    data class ResumeSession(val sessionId: String) : LaunchRequest
    data class ConnectServer(val serverId: Int) : LaunchRequest
    data class OpenSplit(val firstServerId: Int, val secondServerId: Int) : LaunchRequest
    data class OpenShare(val shareId: Int) : LaunchRequest
    data class OpenAlert(val ruleId: Int, val serverId: Int) : LaunchRequest
    data object AddServer : LaunchRequest
    data object OpenSftp : LaunchRequest
    data object OpenNetworkTools : LaunchRequest
}

/**
 * Parses the `omniterm://` links the alert notification and widget rows carry. Anything that is not
 * one of the two known shapes returns null rather than a best guess: a link is untrusted input, and
 * a deep link must never be able to select a resource the app did not publish.
 *
 * Recognised:
 * - `omniterm://notification/alert/{ruleId}/{serverId}`
 * - `omniterm://widget/{widgetId}/server/{serverId}`
 */
fun parseLaunchLink(link: String): LaunchRequest? {
    val withoutScheme = link.removePrefix("omniterm://")
    if (withoutScheme == link) return null
    val segments = withoutScheme.split('/').filter { it.isNotBlank() }
    return when {
        segments.size == 4 && segments[0] == "notification" && segments[1] == "alert" -> {
            val ruleId = segments[2].toPositiveIntOrNull() ?: return null
            val serverId = segments[3].toPositiveIntOrNull() ?: return null
            LaunchRequest.OpenAlert(ruleId, serverId)
        }
        segments.size == 4 && segments[0] == "widget" && segments[2] == "server" -> {
            val serverId = segments[3].toPositiveIntOrNull() ?: return null
            LaunchRequest.ConnectServer(serverId)
        }
        else -> null
    }
}

/**
 * Drops a request that names a host, alert, or share the app does not have. Reuses the shared
 * route validation so notification taps and widget taps cannot disagree about what is addressable.
 */
fun validateLaunchRequest(
    request: LaunchRequest,
    knownServerIds: Set<Int>,
    knownAlertIds: Set<Int> = emptySet(),
    knownShareIds: Set<Int> = emptySet(),
    knownSessionIds: Set<String> = emptySet(),
): LaunchRequest? = when (request) {
    is LaunchRequest.OpenAlert ->
        request.takeIf {
            validateNotificationRoute(
                NotificationRoute(it.serverId, it.ruleId),
                knownServerIds,
                knownAlertIds,
            ) != null
        }
    is LaunchRequest.ConnectServer -> request.takeIf { it.serverId in knownServerIds }
    is LaunchRequest.OpenSplit ->
        request.takeIf { it.firstServerId in knownServerIds && it.secondServerId in knownServerIds }
    is LaunchRequest.OpenShare -> request.takeIf { it.shareId in knownShareIds }
    is LaunchRequest.ResumeSession -> request.takeIf { it.sessionId in knownSessionIds }
    LaunchRequest.AddServer, LaunchRequest.OpenSftp, LaunchRequest.OpenNetworkTools -> request
}

/**
 * Holds launch requests until the app is ready to act on them, mirroring Android's
 * `pendingExternalLaunches` / `drainPendingExternalLaunches`.
 *
 * Two rules carry over exactly: a repeat of the request already at the tail is not queued twice
 * (the platform re-delivers the same intent across configuration changes), and nothing drains while
 * settings are still loading or the app lock is engaged — a notification tap must not walk past the
 * lock screen.
 */
class LaunchRequestQueue {
    private val pending = ArrayDeque<LaunchRequest>()

    val size: Int get() = pending.size

    fun enqueue(request: LaunchRequest) {
        if (pending.lastOrNull() != request) pending.addLast(request)
    }

    /** @return the requests to act on, in arrival order; empty while the app is not ready. */
    fun drain(settingsLoaded: Boolean, locked: Boolean): List<LaunchRequest> {
        if (!settingsLoaded || locked) return emptyList()
        val drained = pending.toList()
        pending.clear()
        return drained
    }

    /** Discards everything, for lock engagement or an explicit cancellation. */
    fun clear() = pending.clear()
}

private fun String.toPositiveIntOrNull(): Int? = toIntOrNull()?.takeIf { it > 0 }
