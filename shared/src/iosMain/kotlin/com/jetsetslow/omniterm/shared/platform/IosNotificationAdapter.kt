@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import kotlinx.coroutines.suspendCancellableCoroutine
import platform.UserNotifications.UNAuthorizationOptionAlert
import platform.UserNotifications.UNAuthorizationOptionBadge
import platform.UserNotifications.UNAuthorizationOptionSound
import platform.UserNotifications.UNMutableNotificationContent
import platform.UserNotifications.UNNotificationRequest
import platform.UserNotifications.UNUserNotificationCenter
import kotlin.coroutines.resume

class IosNotificationAdapter(
    private val privacyMode: () -> Boolean = { true },
) : NotificationAdapter {
    private val center = UNUserNotificationCenter.currentNotificationCenter()

    override suspend fun requestPermission(): CapabilityResult<Boolean> = suspendCancellableCoroutine { continuation ->
        val options = UNAuthorizationOptionAlert or UNAuthorizationOptionBadge or UNAuthorizationOptionSound
        center.requestAuthorizationWithOptions(options) { granted, error ->
            if (!continuation.isActive) return@requestAuthorizationWithOptions
            continuation.resume(
                if (error == null) CapabilityResult.Available(granted)
                else CapabilityResult.Failed(PlatformError.PermissionDenied),
            )
        }
    }

    override suspend fun publish(notification: AlertNotification): CapabilityResult<Unit> =
        suspendCancellableCoroutine { continuation ->
            val safeNotification = privacySafeNotification(notification, privacyMode())
            val content = UNMutableNotificationContent().apply {
                setTitle(safeNotification.title)
                setBody(safeNotification.body)
                setUserInfo(
                    buildMap<Any?, Any> {
                        safeNotification.route.hostId?.let { put("hostId", it) }
                        safeNotification.route.alertId?.let { put("alertId", it) }
                    },
                )
            }
            val request = UNNotificationRequest.requestWithIdentifier(safeNotification.id, content, trigger = null)
            center.addNotificationRequest(request) { error ->
                if (!continuation.isActive) return@addNotificationRequest
                continuation.resume(
                    if (error == null) CapabilityResult.Available(Unit)
                    else CapabilityResult.Failed(PlatformError.PermissionDenied),
                )
            }
        }

    override suspend fun remove(ids: Set<String>): CapabilityResult<Unit> {
        val values = ids.toList()
        center.removePendingNotificationRequestsWithIdentifiers(values)
        center.removeDeliveredNotificationsWithIdentifiers(values)
        return CapabilityResult.Available(Unit)
    }
}
