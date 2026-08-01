package com.jetsetslow.omniterm.shared.platform

import kotlinx.coroutines.CancellationException

class PrivilegedActionGate {
    private var pending: (() -> Unit)? = null

    suspend fun authenticateThenRun(authenticator: BiometricAuthenticator, action: () -> Unit): CapabilityResult<Unit> {
        pending = action
        return try {
            when (val result = authenticator.authenticate(AuthenticationReason.ConfirmSensitiveAction)) {
                is CapabilityResult.Available -> {
                    val approved = pending
                    pending = null
                    approved?.invoke()
                    result
                }
                is CapabilityResult.Failed -> result.also { pending = null }
                is CapabilityResult.Unsupported -> result.also { pending = null }
            }
        } catch (cancelled: CancellationException) {
            pending = null
            authenticator.cancel()
            throw cancelled
        }
    }

    fun clear(authenticator: BiometricAuthenticator) {
        pending = null
        authenticator.cancel()
    }
}

fun sanitizeFilename(input: String, fallback: String = "OmniTerm-export"): String {
    val cleaned = input
        .replace('\\', '_')
        .replace('/', '_')
        .replace(Regex("[\\u0000-\\u001F\\u007F]"), "")
        .replace(Regex("\\s+"), " ")
        .trim(' ', '.')
        .take(128)
    return cleaned.ifBlank { fallback }
}

fun validateNotificationRoute(
    route: NotificationRoute,
    knownHostIds: Set<Int>,
    knownAlertIds: Set<Int>,
): NotificationRoute? {
    if (route.hostId != null && route.hostId !in knownHostIds) return null
    if (route.alertId != null && route.alertId !in knownAlertIds) return null
    if (route.hostId == null && route.alertId == null) return null
    return route
}

fun privacySafeNotification(notification: AlertNotification, maskHosts: Boolean): AlertNotification =
    if (!maskHosts || !notification.private) notification else notification.copy(
        title = "OmniTerm alert",
        body = "Open OmniTerm to view private alert details.",
    )
