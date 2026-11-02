package com.jetsetslow.omniterm

import androidx.compose.ui.graphics.Color
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.getServerColor
import com.jetsetslow.omniterm.ui.hostAccent
import com.jetsetslow.omniterm.ui.theme.OmniColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * A host's colour is the one the user picked, else one its id picks, and it is the same on every
 * card that stands for the host. Broadcast and terminal cards hashed the host's name instead, so
 * they disagreed with the colour the host was given, and several host colours were the status
 * colours, so a host could look failed or running when it was neither.
 */
class HostColorsTest {
    private fun host(id: Int, name: String = "host $id", color: String = "Default") =
        ServerEntity(id = id, name = name, host = "$id.invalid", username = "fixture", serverColor = color)

    @Test
    fun noHostColourLooksLikeAStatusColour() {
        val statuses = mapOf(
            "ok" to OmniColors.green,
            "warning" to OmniColors.amber,
            "failed" to OmniColors.red,
            "running" to OmniColors.cyan,
            "offline" to Color.Gray,
        )
        for ((name, color) in OmniColors.namedColors) {
            for ((status, statusColor) in statuses) {
                assertTrue("$name is too close to the $status colour", distance(color, statusColor) >= 0.3f)
            }
        }
    }

    @Test
    fun coloursSavedBeforeTheChangeShowTheirReplacements() {
        val expected = mapOf(
            "Cyan" to "Blue", "Green" to "Indigo", "Amber" to "Violet", "Orange" to "Magenta",
            "Red" to "Pink", "Purple" to "Purple", "pink" to "Pink", "Default" to "Default",
            "" to "Default", "Teal" to "Default",
        )
        expected.forEach { (saved, name) -> assertEquals(saved, name, OmniColors.hostColorName(saved)) }
        assertEquals(OmniColors.blue, getServerColor(host(7, color = "Cyan")))
        assertEquals(OmniColors.pink, getServerColor(host(7, color = "Red")))
    }

    @Test
    fun aHostOnDefaultIsColouredByItsIdSoARenameKeepsItsColour() {
        val web = host(3, name = "web")
        assertEquals(getServerColor(web), getServerColor(web.copy(name = "web renamed")))
        assertNotEquals("neighbouring hosts differ", getServerColor(web), getServerColor(host(4, name = "web")))
        assertTrue(getServerColor(web) in OmniColors.namedColors.map { it.second })
    }

    @Test
    fun cardsHoldingOnlyAHostIdShowTheHostsOwnColour() {
        val servers = listOf(host(1, color = "Pink"), host(2))
        assertEquals(OmniColors.pink, hostAccent(servers, 1))
        assertEquals(getServerColor(servers[1]), hostAccent(servers, 2))
        assertEquals("a host no longer listed keeps its id's colour", OmniColors.hostColor(9), hostAccent(servers, 9))
    }

    /** Straight-line distance between two colours' red, green and blue, each from 0 to 1. */
    private fun distance(a: Color, b: Color): Float {
        val red = a.red - b.red
        val green = a.green - b.green
        val blue = a.blue - b.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}
