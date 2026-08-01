package com.jetsetslow.omniterm.shared.platform

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SafetyPoliciesTest {
    @Test
    fun sanitizesUnsafeFilenames() {
        assertEquals("_private_key", sanitizeFilename("../private/key"))
        assertEquals("OmniTerm-export", sanitizeFilename("..."))
    }

    @Test
    fun rejectsUnknownNotificationTargets() {
        assertNull(validateNotificationRoute(NotificationRoute(hostId = 99, alertId = 2), setOf(1), setOf(2)))
        assertEquals(
            NotificationRoute(1, 2),
            validateNotificationRoute(NotificationRoute(1, 2), setOf(1), setOf(2)),
        )
    }

    @Test
    fun masksPrivateNotificationDetails() {
        val original = AlertNotification("1", "db.example", "Disk 95%", NotificationRoute(1, 2), private = true)
        val masked = privacySafeNotification(original, maskHosts = true)
        assertEquals("OmniTerm alert", masked.title)
        assertEquals("Open OmniTerm to view private alert details.", masked.body)
    }
}
