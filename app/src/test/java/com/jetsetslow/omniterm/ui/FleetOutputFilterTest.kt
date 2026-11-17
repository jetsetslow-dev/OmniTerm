package com.jetsetslow.omniterm.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Narrowing a Fleet run's cards: "Failed only" keeps the hosts Retry would run again, and a text
 * keeps the hosts that have it in their name, output or note.
 */
class FleetOutputFilterTest {
    private val hosts = listOf(
        BroadcastResultItem(1, "nas", "nginx is running\n", BroadcastStatus.Success),
        BroadcastResultItem(2, "pi", "nginx is STOPPED\n", BroadcastStatus.Failure, note = "Exited with status 3."),
        BroadcastResultItem(3, "web-1", "", BroadcastStatus.NotRun, note = "Not run: pi did not succeed."),
        BroadcastResultItem(4, "web-2", "restarting", BroadcastStatus.Running),
        BroadcastResultItem(5, "db", "", BroadcastStatus.Waiting),
    )

    private fun names(filter: FleetOutputFilter) = filter.apply(hosts).map { it.serverName }

    @Test
    fun offShowsEveryHostAsItIs() {
        val off = FleetOutputFilter()
        assertFalse(off.isOn)
        assertSame(hosts, off.apply(hosts))
        assertFalse("spaces are not something to find", FleetOutputFilter(query = "  ").isOn)
    }

    @Test
    fun failedOnlyKeepsWhatRetryWouldRunAgain() {
        assertEquals(listOf("pi", "web-1"), names(FleetOutputFilter(failedOnly = true)))
        assertEquals(hosts.filter { it.didNotSucceed }.map { it.serverName }, names(FleetOutputFilter(failedOnly = true)))
    }

    @Test
    fun aTextIsFoundInNamesOutputsAndNotesInAnyCase() {
        assertEquals("in two outputs", listOf("nas", "pi"), names(FleetOutputFilter(query = "nginx")))
        assertEquals("whatever its case", listOf("pi"), names(FleetOutputFilter(query = "stopped")))
        assertEquals("in names", listOf("web-1", "web-2"), names(FleetOutputFilter(query = "WEB")))
        assertEquals("in notes, and in the name it is about", listOf("pi", "web-1"), names(FleetOutputFilter(query = "pi")))
        assertEquals("with the spaces around it left out", listOf("pi"), names(FleetOutputFilter(query = "  status 3 ")))
        assertEquals(emptyList<String>(), names(FleetOutputFilter(query = "no such text")))
    }

    @Test
    fun bothTogetherKeepOnlyHostsThatPassBoth() {
        assertEquals(listOf("pi"), names(FleetOutputFilter(failedOnly = true, query = "nginx")))
        assertTrue(FleetOutputFilter(failedOnly = true, query = "nginx").isOn)
    }
}
