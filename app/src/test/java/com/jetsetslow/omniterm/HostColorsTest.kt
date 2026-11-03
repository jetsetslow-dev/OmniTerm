package com.jetsetslow.omniterm

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.getServerColor
import com.jetsetslow.omniterm.ui.hostAccent
import com.jetsetslow.omniterm.ui.theme.OmniColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt
import kotlin.math.pow

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
    fun hostChoicesDoNotClusterAroundTheSameHue() {
        for (background in listOf(OmniColors.bg2, Color.White)) {
            val choices = OmniColors.namedHostColors(background)
            choices.forEachIndexed { i, (name, color) ->
                choices.drop(i + 1).forEach { (otherName, other) ->
                    assertTrue("$name and $otherName are too similar", perceptualDistance(color, other) >= 0.075)
                }
            }
        }
    }

    @Test
    fun noHostColourLooksLikeAStatusColour() {
        val statuses = mapOf(
            "ok" to OmniColors.green, "warning" to OmniColors.amber, "failed" to OmniColors.red,
            "running" to OmniColors.cyan, "offline" to Color.Gray,
        )
        for (background in listOf(OmniColors.bg2, Color.White)) {
            for ((name, color) in OmniColors.namedHostColors(background)) {
                for ((status, statusColor) in statuses) {
                    assertTrue("$name is too close to the $status colour", perceptualDistance(color, statusColor) >= 0.09)
                }
            }
        }
    }

    @Test
    fun hostTextHasReadableContrastOnAllSupportedAppSurfaces() {
        val backgrounds = listOf(
            Color.Black, OmniColors.bg1, OmniColors.bg2, OmniColors.bg3, OmniColors.bg4,
            Color.White, Color(0xFFF6F8FB), Color(0xFFEDF1F6), Color(0xFFE6EAF0), Color(0xFFDFE4EC),
        )
        for (background in backgrounds) {
            for ((name, color) in OmniColors.namedHostColors(background)) {
                val foregroundY = color.luminance()
                val backgroundY = background.luminance()
                val contrast = (maxOf(foregroundY, backgroundY) + 0.05f) / (minOf(foregroundY, backgroundY) + 0.05f)
                assertTrue("$name has only $contrast contrast", contrast >= 4.5f)
            }
        }
    }

    @Test
    fun coloursSavedBeforeTheChangeShowTheirReplacements() {
        val expected = mapOf(
            "Cyan" to "Blue", "Green" to "Teal", "Amber" to "Gold", "Orange" to "Copper", "Red" to "Rose",
            "Blue" to "Blue", "Indigo" to "Teal", "Violet" to "Gold", "Purple" to "Plum", "Magenta" to "Copper", "Pink" to "Rose",
            "pink" to "Rose", "Default" to "Default", "" to "Default", "unknown" to "Default", "Ocean" to "Ocean",
        )
        expected.forEach { (saved, name) -> assertEquals(saved, name, OmniColors.hostColorName(saved)) }
        for (background in listOf(OmniColors.bg2, Color.White)) {
            val colors = OmniColors.namedHostColors(background).toMap()
            expected.filterValues { it != "Default" }.forEach { (saved, name) ->
                assertEquals(colors.getValue(name), getServerColor(host(7, color = saved), background))
            }
        }
        val oldChoices = listOf("Blue", "Indigo", "Violet", "Purple", "Magenta", "Pink")
        assertEquals("Previously different choices stay different", 6, oldChoices.map(OmniColors::hostColorName).toSet().size)
    }

    @Test
    fun aHostOnDefaultIsColouredByItsIdSoARenameKeepsItsColour() {
        val web = host(3, name = "web")
        for (background in listOf(OmniColors.bg2, Color.White)) {
            assertEquals(getServerColor(web, background), getServerColor(web.copy(name = "web renamed"), background))
            assertNotEquals("neighbouring hosts differ", getServerColor(web, background), getServerColor(host(4, name = "web"), background))
            assertTrue(getServerColor(web, background) in OmniColors.namedHostColors(background).map { it.second })
        }
        assertEquals(OmniColors.namedColors.size, (0 until OmniColors.namedColors.size).map { OmniColors.hostColor(it) }.toSet().size)
        assertTrue(OmniColors.hostColor(Int.MIN_VALUE) in OmniColors.namedColors.map { it.second })
    }

    @Test
    fun cardsHoldingOnlyAHostIdShowTheHostsOwnColour() {
        val servers = listOf(host(1, color = "Pink"), host(2))
        for (background in listOf(OmniColors.bg2, Color.White)) {
            assertEquals(OmniColors.serverAccent("Rose", 1, background), hostAccent(servers, 1, background))
            assertEquals(getServerColor(servers[1], background), hostAccent(servers, 2, background))
            assertEquals("A host no longer listed keeps its ID", OmniColors.hostColor(9, background), hostAccent(servers, 9, background))
        }
    }

    /** Oklab's Euclidean distance, rather than RGB channel distance; a design regression guard,
     * not a claim that every hue can be distinguished with every type of colour-vision deficiency.
     * Conversion: https://bottosson.github.io/posts/oklab/ (linear sRGB matrices).
     */
    private fun perceptualDistance(first: Color, second: Color): Double {
        fun lab(color: Color): List<Double> {
            fun linear(channel: Float): Double = channel.toDouble().let {
                if (it <= 0.04045) it / 12.92 else ((it + 0.055) / 1.055).pow(2.4)
            }
            val r = linear(color.red)
            val g = linear(color.green)
            val b = linear(color.blue)
            val l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            val m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            val s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return listOf(
                0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            )
        }
        return sqrt(lab(first).zip(lab(second)).sumOf { (a, b) -> (a - b).pow(2) })
    }
}
