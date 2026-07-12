package com.jetsetslow.omniterm.ui

import kotlin.math.pow

/**
 * Legibility guard for terminal text. Remote programs pick colours assuming *their* idea of the
 * background — usually a dark one — so 256-cube greys, truecolour output, and reverse-video blocks
 * can land nearly invisible when the user's terminal theme disagrees (light theme + pale grey text
 * is the classic case). The renderer runs every resolved foreground through
 * [ensureLegibleOnBackground] against the cell's effective background, nudging it toward black or
 * white just far enough to clear a minimum contrast ratio.
 *
 * Pure JVM (no Android/Compose deps) so the maths is unit-testable in plain tests.
 */

/**
 * Minimum WCAG contrast ratio the renderer guarantees between text and its cell background.
 * 2.5:1 keeps hue identity for the 256-colour cube (full AA 4.5:1 would repaint most of it) while
 * making every glyph clearly readable.
 */
const val MIN_TERMINAL_TEXT_CONTRAST = 2.5f

private fun srgbChannelToLinear(channel: Int): Float {
    val c = channel / 255f
    return if (c <= 0.03928f) c / 12.92f else ((c + 0.055f) / 1.055f).pow(2.4f)
}

/** WCAG relative luminance of a packed ARGB colour (alpha ignored). */
fun relativeLuminance(argb: Int): Float =
    0.2126f * srgbChannelToLinear((argb shr 16) and 0xFF) +
        0.7152f * srgbChannelToLinear((argb shr 8) and 0xFF) +
        0.0722f * srgbChannelToLinear(argb and 0xFF)

/** WCAG contrast ratio (≥ 1.0) between two relative luminances. */
fun contrastRatio(lum1: Float, lum2: Float): Float {
    val hi = maxOf(lum1, lum2)
    val lo = minOf(lum1, lum2)
    return (hi + 0.05f) / (lo + 0.05f)
}

/** Channel-wise sRGB blend of [from] toward [to] by [t] ∈ [0,1]; alpha forced opaque. */
fun lerpArgb(from: Int, to: Int, t: Float): Int {
    fun ch(shift: Int): Int {
        val a = (from shr shift) and 0xFF
        val b = (to shr shift) and 0xFF
        return (a + ((b - a) * t)).toInt().coerceIn(0, 255)
    }
    return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
}

/**
 * Return [fg] if it already clears [minRatio] against [bg]; otherwise blend it toward black or
 * white — whichever side of [bg] has more contrast headroom — in 25% steps and return the first
 * blend that clears the ratio. Small nudges preserve the original hue; only a colour that started
 * hopelessly close to the background ends up at the full extreme.
 */
fun ensureLegibleOnBackground(fg: Int, bg: Int, minRatio: Float = MIN_TERMINAL_TEXT_CONTRAST): Int {
    val bgLum = relativeLuminance(bg)
    if (contrastRatio(relativeLuminance(fg), bgLum) >= minRatio) return fg
    // Max achievable ratio in each direction decides which way to push.
    val towardBlackMax = (bgLum + 0.05f) / 0.05f
    val towardWhiteMax = 1.05f / (bgLum + 0.05f)
    val target = if (towardBlackMax >= towardWhiteMax) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
    var t = 0.25f
    while (t < 1f) {
        val candidate = lerpArgb(fg, target, t)
        if (contrastRatio(relativeLuminance(candidate), bgLum) >= minRatio) return candidate
        t += 0.25f
    }
    return target
}
