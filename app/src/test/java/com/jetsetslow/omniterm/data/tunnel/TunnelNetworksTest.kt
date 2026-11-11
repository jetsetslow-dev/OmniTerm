package com.jetsetslow.omniterm.data.tunnel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Wi-Fi networks a tunnel is not needed on: only a network the user named, spelled exactly,
 * sends its hosts direct, and a name Android gave once is kept for that connection only.
 */
class TunnelNetworksTest {
    @Test
    fun namesAreKeptAsSpelledOnceEachAndWithinTheLimits() {
        val stored = TunnelNetworks.stored(listOf("Home", "Café 5G, upstairs", "Home", "", " Guest ", "line\nbreak", "x".repeat(33)))
        assertEquals(listOf("Home", "Café 5G, upstairs", " Guest ", "linebreak"), TunnelNetworks.names(stored))
        assertEquals(emptyList<String>(), TunnelNetworks.names(""))
        assertEquals(TunnelNetworks.MAX_NAMES, TunnelNetworks.names(TunnelNetworks.stored((1..40).map { "net$it" })).size)
        assertFalse("32 bytes is the longest a name can be", TunnelNetworks.tooLong("x".repeat(32)))
        assertTrue("counted in bytes, as the network does", TunnelNetworks.tooLong("é".repeat(17)))
    }

    @Test
    fun onlyANamedWifiSpelledExactlyGoesDirect() {
        val stored = TunnelNetworks.stored(listOf("Home", "Office"))
        assertTrue(TunnelNetworks.goesDirect(stored, "Home"))
        assertTrue(TunnelNetworks.goesDirect(stored, "Office"))
        assertFalse("another network", TunnelNetworks.goesDirect(stored, "Cafe"))
        assertFalse("a Wi-Fi name is case-sensitive", TunnelNetworks.goesDirect(stored, "home"))
        assertFalse("part of a name is not the name", TunnelNetworks.goesDirect(stored, "Hom"))
        assertFalse("not on Wi-Fi, or Android did not say which", TunnelNetworks.goesDirect(stored, null))
        assertFalse("a tunnel that names none is always used", TunnelNetworks.goesDirect("", "Home"))
    }

    @Test
    fun androidsSpellingOfANameIsReadAsTheUserSeesIt() {
        assertEquals("Home", WifiMemory.clean("\"Home\""))
        assertEquals("say \"hi\"", WifiMemory.clean("\"say \"hi\"\""))
        assertEquals("a name that is not text stays as its hex digits", "486f6d65", WifiMemory.clean("486f6d65"))
        assertNull(WifiMemory.clean("<unknown ssid>"))
        assertNull(WifiMemory.clean("\"\""))
        assertNull(WifiMemory.clean(""))
        assertNull(WifiMemory.clean(null))
    }

    @Test
    fun aNameGivenOnceIsKeptForThatConnectionAndNoOther() {
        val memory = WifiMemory()
        assertNull("never told: not known", memory.name(boot = 7, connection = 100, reported = "<unknown ssid>"))
        assertEquals("Home", memory.name(7, 100, "\"Home\""))
        assertEquals("withheld in the background: the same connection is still Home", "Home", memory.name(7, 100, "<unknown ssid>"))
        assertEquals("Home", memory.name(7, 100, null))
        assertNull("the phone joined another Wi-Fi", memory.name(7, 101, "<unknown ssid>"))
        assertNull("the phone restarted: its count of connections began again", memory.name(8, 100, "<unknown ssid>"))
        assertEquals("Cafe", memory.name(7, 101, "\"Cafe\""))
        assertNull("the earlier connection is forgotten once another was named", memory.name(7, 100, "<unknown ssid>"))
        assertEquals(WifiMemory.Seen(7, 101, "Cafe"), memory.seen)
    }

    @Test
    fun aKeptNameSurvivesTheAppBeingStartedAgain() {
        val restarted = WifiMemory(WifiMemory.Seen(boot = 7, connection = 100, name = "Home"))
        assertEquals("Home", restarted.name(7, 100, "<unknown ssid>"))
        assertNull(restarted.name(7, 102, "<unknown ssid>"))
    }
}
