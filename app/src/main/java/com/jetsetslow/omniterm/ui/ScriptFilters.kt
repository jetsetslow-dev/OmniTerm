package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.HostMetrics
import com.jetsetslow.omniterm.data.QuickScriptEntity
import java.util.Locale

val quickScriptOsOptions = listOf("Any", "Linux", "FreeBSD", "Darwin", "Windows")
val quickScriptSystemOptions = listOf("Any", "Proxmox", "CasaOS", "Home Assistant", "Raspberry Pi", "Docker")

fun quickScriptMatchesHost(script: QuickScriptEntity, metrics: HostMetrics?): Boolean {
    if (!script.availableForQuick) return false
    val os = metrics?.os.orEmpty()
    val platforms = metrics?.platforms.orEmpty()
    val osMatches = script.targetOs.equals("Any", ignoreCase = true) ||
        script.targetOs.isBlank() ||
        os.equals(script.targetOs, ignoreCase = true) ||
        platforms.contains(script.targetOs.lowercase(Locale.ROOT))
    val systemMatches = script.targetSystem.equals("Any", ignoreCase = true) ||
        script.targetSystem.isBlank() ||
        platforms.contains(systemPlatformKey(script.targetSystem))
    val legacyMatches = legacyCategoryPlatformKey(script.category)?.let { it in platforms } ?: true
    return osMatches && systemMatches && legacyMatches
}

fun legacyCategoryPlatformKey(category: String): String? = when (category) {
    "Linux" -> "linux"
    "FreeBSD" -> "freebsd"
    "Darwin" -> "darwin"
    "Windows" -> "windows"
    "Proxmox" -> "proxmox"
    "CasaOS" -> "casaos"
    "Home Assistant" -> "homeassistant"
    "Raspberry Pi" -> "raspberry"
    else -> null
}

fun systemPlatformKey(system: String): String = when (system) {
    "Home Assistant" -> "homeassistant"
    "Raspberry Pi" -> "raspberry"
    else -> system.lowercase(Locale.ROOT).replace(" ", "")
}
