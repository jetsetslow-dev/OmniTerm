package com.jetsetslow.omniterm.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

val Purple80 = Color(0xFFD0BCFF)
val PurpleGrey80 = Color(0xFFCCC2DC)
val Pink80 = Color(0xFFEFB8C8)

val Purple40 = Color(0xFF6650a4)
val PurpleGrey40 = Color(0xFF625b71)
val Pink40 = Color(0xFF7D5260)

/**
 * OmniTerm design-system palette, ported from `nexuscomplete.jsx` (the React prototype).
 * Shared by the new terminal UI now and the broader UI revamp later. Kept as a plain
 * object of [Color]s (no Android deps beyond compose.ui.graphics) so it moves cleanly
 * into a Compose-Multiplatform `commonMain` module down the line.
 */
object OmniColors {
    val bg0 = Color(0xFF000000)   // AMOLED black — app/terminal background (pixels off)
    val bg1 = Color(0xFF0A0E15)   // bars (barely lifted off black)
    val bg2 = Color(0xFF101622)   // cards
    val bg3 = Color(0xFF161D2E)   // raised surfaces
    val bg4 = Color(0xFF1C2438)   // controls
    val border = Color(0xFF1E2D44)
    val borderHi = Color(0xFF2A3F60)

    val cyan = Color(0xFF00E5FF)
    val cyanDim = Color(0xFF00233A)
    val green = Color(0xFF00E676)
    val greenDim = Color(0xFF00231A)
    val amber = Color(0xFFFFAB00)
    val amberDim = Color(0xFF2A1F00)
    val red = Color(0xFFFF1744)
    val redDim = Color(0xFF2A0008)
    val purple = Color(0xFFD500F9)
    val purpleDim = Color(0xFF1E0026)
    val orange = Color(0xFFFF6D00)

    val textPrimary = Color(0xFFC8D4E8)
    val textSecondary = Color(0xFF56708A)
    val textMuted = Color(0xFF2C3E52)

    private data class HostColor(val name: String, val dark: Color, val light: Color) {
        fun on(background: Color): Color = if (background.luminance() > 0.5f) light else dark
    }

    // Muted identity hues span the colour wheel; adjacent automatic choices deliberately differ
    // in hue. Each has a lighter dark-theme tone and a deeper light-theme tone. Status tokens
    // above remain separate: a host's identity is not its connection or health state.
    private val hostColors = listOf(
        HostColor("Blue", Color(0xFF6FA7EE), Color(0xFF2B61A3)),
        HostColor("Copper", Color(0xFFE68677), Color(0xFF994135)),
        HostColor("Teal", Color(0xFF4DBC92), Color(0xFF007252)),
        HostColor("Rose", Color(0xFFDA85B6), Color(0xFF8E4170)),
        HostColor("Gold", Color(0xFFD09945), Color(0xFF825601)),
        HostColor("Plum", Color(0xFFB093E5), Color(0xFF6B4E9A)),
        HostColor("Olive", Color(0xFF9BB054), Color(0xFF586901)),
        HostColor("Ocean", Color(0xFF6BAFB9), Color(0xFF246371)),
    )

    /** Default dark-surface tones, also usable without composition in identity-policy tests. */
    val namedColors: List<Pair<String, Color>> = namedHostColors(bg2)

    /** The same named choices in the tone suited to the surface hosting their text and swatches. */
    fun namedHostColors(background: Color): List<Pair<String, Color>> =
        hostColors.map { it.name to it.on(background) }

    // Read old names without rewriting stored hosts or backups. The six previous explicit
    // choices still map to six distinct identities; original status-name aliases also work.
    private val legacyColorNames = mapOf(
        "cyan" to "Blue", "green" to "Teal", "amber" to "Gold", "orange" to "Copper", "red" to "Rose",
        "indigo" to "Teal", "violet" to "Gold", "purple" to "Plum", "magenta" to "Copper", "pink" to "Rose",
    )

    /** [saved] as one of [namedColors]' names, or "Default" when it names none of them. */
    fun hostColorName(saved: String): String =
        legacyColorNames[saved.lowercase()]
            ?: namedColors.firstOrNull { it.first.equals(saved, ignoreCase = true) }?.first
            ?: "Default"

    /** The colour a host on "Default" gets: picked by its id, so it stays put through a rename. */
    fun hostColor(serverId: Int, background: Color = bg2): Color =
        hostColors[Math.floorMod(serverId, hostColors.size)].on(background)

    /**
     * A server's colour from its saved [colorName]. "Default" (or any unknown value) takes the
     * colour its id picks, while explicit user choices win.
     */
    fun serverAccent(colorName: String, serverId: Int, background: Color = bg2): Color =
        hostColors.firstOrNull { it.name == hostColorName(colorName) }?.on(background) ?: hostColor(serverId, background)
}
