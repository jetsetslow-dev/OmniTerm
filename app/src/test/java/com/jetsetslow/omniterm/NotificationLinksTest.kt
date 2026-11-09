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
}
