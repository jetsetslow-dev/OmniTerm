package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.MIN_TERMINAL_TEXT_CONTRAST
import com.jetsetslow.omniterm.ui.contrastRatio
import com.jetsetslow.omniterm.ui.ensureLegibleOnBackground
import com.jetsetslow.omniterm.ui.lerpArgb
import com.jetsetslow.omniterm.ui.relativeLuminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalContrastTest {

    private val lightBg = 0xFFF8F8F2.toInt() // light terminal theme background
    private val darkBg = 0xFF000000.toInt() // omni_dark background

    private fun ratio(fg: Int, bg: Int): Float =
        contrastRatio(relativeLuminance(fg), relativeLuminance(bg))

    @Test
    fun `luminance endpoints are correct`() {
        assertEquals(0f, relativeLuminance(0xFF000000.toInt()), 1e-4f)
        assertEquals(1f, relativeLuminance(0xFFFFFFFF.toInt()), 1e-3f)
    }

    @Test
    fun `black on white is max contrast`() {
        assertEquals(21f, ratio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 0.1f)
    }

    @Test
    fun `already legible colours are returned unchanged`() {
        val red = 0xFFCD0000.toInt()
        assertEquals(red, ensureLegibleOnBackground(red, lightBg))
        val brightYellow = 0xFFFFFF4D.toInt()
        assertEquals(brightYellow, ensureLegibleOnBackground(brightYellow, darkBg))
    }

    @Test
    fun `256-cube greys become legible on the light background`() {
        // xterm colour 245 (0xB2B2B2) and 250 (0xBCBCBC): the washed-out CLI-status-line greys.
        for (grey in listOf(0xFFB2B2B2.toInt(), 0xFFBCBCBC.toInt(), 0xFFE5E5E5.toInt())) {
            val fixed = ensureLegibleOnBackground(grey, lightBg)
            assertTrue(
                "0x${Integer.toHexString(grey)} → 0x${Integer.toHexString(fixed)} ratio ${ratio(fixed, lightBg)}",
                ratio(fixed, lightBg) >= MIN_TERMINAL_TEXT_CONTRAST,
            )
        }
    }

    @Test
    fun `dark colours become legible on the dark background`() {
        // ANSI blue-ish and near-black cube entries that vanish on black.
        for (dark in listOf(0xFF00005F.toInt(), 0xFF1C1C1C.toInt(), 0xFF000000.toInt())) {
            val fixed = ensureLegibleOnBackground(dark, darkBg)
            assertTrue(
                "0x${Integer.toHexString(dark)} → 0x${Integer.toHexString(fixed)} ratio ${ratio(fixed, darkBg)}",
                ratio(fixed, darkBg) >= MIN_TERMINAL_TEXT_CONTRAST,
            )
        }
    }

    @Test
    fun `identical fg and bg is always corrected`() {
        for (bg in listOf(lightBg, darkBg, 0xFF808080.toInt())) {
            val fixed = ensureLegibleOnBackground(bg, bg)
            assertTrue(ratio(fixed, bg) >= MIN_TERMINAL_TEXT_CONTRAST)
        }
    }

    @Test
    fun `mid-grey background still reaches the target ratio`() {
        // 0x767676 has ~4.5:1 headroom to both extremes; both directions can satisfy 2.5:1.
        val bg = 0xFF767676.toInt()
        val fixed = ensureLegibleOnBackground(0xFF7A7A7A.toInt(), bg)
        assertTrue(ratio(fixed, bg) >= MIN_TERMINAL_TEXT_CONTRAST)
    }

    @Test
    fun `nudge preserves hue direction`() {
        // A washed-out light green on light bg should darken but stay green-dominant.
        val fixed = ensureLegibleOnBackground(0xFFAAFFAA.toInt(), lightBg)
        val r = (fixed shr 16) and 0xFF
        val g = (fixed shr 8) and 0xFF
        val b = fixed and 0xFF
        assertTrue("green channel should stay dominant: ${Integer.toHexString(fixed)}", g > r && g > b)
    }

    @Test
    fun `lerp endpoints and midpoint`() {
        val from = 0xFF000000.toInt()
        val to = 0xFFFFFFFF.toInt()
        assertEquals(from, lerpArgb(from, to, 0f))
        assertEquals(to, lerpArgb(from, to, 1f))
        assertEquals(0xFF7F7F7F.toInt(), lerpArgb(from, to, 0.5f))
    }
}
