package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.NotificationLinks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationLinksTest {
    @Test
    fun aRunbookLinkReadsBackAsItsRuleAndHost() {
        val link = NotificationLinks.runbook(12, 3)
        assertEquals("omniterm://notification/runbook/12/3", link)
        assertEquals(12 to 3, NotificationLinks.parseRunbook(link.removePrefix("omniterm://notification/").split('/')))
    }

    @Test
    fun anyOtherLinkIsNotARunbook() {
        assertNull(NotificationLinks.parseRunbook(listOf("alert", "12", "3")))
        assertNull(NotificationLinks.parseRunbook(listOf("runbook", "12")))
        assertNull(NotificationLinks.parseRunbook(listOf("runbook", "0", "3")))
        assertNull(NotificationLinks.parseRunbook(listOf("runbook", "12", "x")))
        assertNull(NotificationLinks.parseRunbook(listOf("fleet")))
    }

    @Test
    fun aRunLinkReadsBackAsItsRunKey() {
        val key = "automation-0b3e9f2a-7c1d-4e5f-9a8b-1c2d3e4f5a6b"
        val link = NotificationLinks.fleetRun(key)
        assertEquals("omniterm://notification/fleet-run/$key", link)
        assertEquals(key, NotificationLinks.parseFleetRun(link.removePrefix("omniterm://notification/").split('/')))
    }

    @Test
    fun aRunLinkFromAnywhereElseIsReadOnlyWhenItHasARunsShape() {
        // MainActivity is exported, so any app can send these.
        assertNull(NotificationLinks.parseFleetRun(listOf("fleet-run")))
        assertNull(NotificationLinks.parseFleetRun(listOf("fleet-run", "")))
        assertNull(NotificationLinks.parseFleetRun(listOf("fleet-run", "a b")))
        assertNull(NotificationLinks.parseFleetRun(listOf("fleet-run", "x".repeat(81))))
        assertNull(NotificationLinks.parseFleetRun(listOf("fleet-run", "key", "more")))
        assertNull(NotificationLinks.parseFleetRun(listOf("runbook", "12", "3")))
    }
}
