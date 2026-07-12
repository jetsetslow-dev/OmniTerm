package com.jetsetslow.omniterm.ui.theme

import androidx.compose.ui.graphics.Color

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

    private val hostColors = listOf(cyan, amber, orange, green, red, purple)

    /** Deterministic per-host accent colour, mirroring `hostColor()` in the prototype. */
    fun hostColor(name: String): Color {
        if (name.isEmpty()) return cyan
        val idx = name.sumOf { it.code } % hostColors.size
        return hostColors[idx]
    }

    /** The user-selectable accent names, used by the Add/Edit-host colour picker. */
    val namedColors: List<Pair<String, Color>> = listOf(
        "Cyan" to cyan, "Green" to green, "Amber" to amber,
        "Orange" to orange, "Red" to red, "Purple" to purple,
    )

    /**
     * Resolve a server's stored [ServerEntity.serverColor] name to a [Color]. "Default" (or any
     * unknown value) falls back to the deterministic per-name colour so existing rows still look
     * sensible, while explicit user choices win.
     */
    fun serverAccent(colorName: String, fallbackName: String): Color =
        namedColors.firstOrNull { it.first.equals(colorName, ignoreCase = true) }?.second
            ?: hostColor(fallbackName)
}
