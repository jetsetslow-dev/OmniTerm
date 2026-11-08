package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.HostMetrics
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import java.util.Locale

val quickScriptOsOptions = listOf("Any", "Linux", "FreeBSD", "Darwin", "Windows")
/** Systems a script can target; each matches the platform key the metrics probe reports ([systemPlatformKey]). */
val quickScriptSystemOptions = listOf(
    "Any", "Proxmox", "CasaOS", "Home Assistant", "Raspberry Pi", "Docker", "Podman", "Kubernetes",
    "Synology", "TrueNAS", "Unraid", "OpenWrt", "pfSense", "OPNsense",
)

fun quickScriptMatchesHost(script: QuickScriptEntity, metrics: HostMetrics?): Boolean =
    script.availableForQuick && scriptTargetsHost(script, metrics)

/** True when [script] has no target OS or system at all, so it suits every host. */
fun scriptTargetsAnyHost(script: QuickScriptEntity): Boolean =
    (script.targetOs.isBlank() || script.targetOs.equals("Any", ignoreCase = true)) &&
        (script.targetSystem.isBlank() || script.targetSystem.equals("Any", ignoreCase = true)) &&
        legacyCategoryPlatformKey(script.category) == null

/**
 * The hosts a Fleet run of [script] leaves out: those whose detected OS or system its target rules
 * out. A host not probed yet ([metricsById] has nothing for it) is kept, so the run tries it and
 * shows the real result rather than skipping it on a guess.
 */
fun fleetHostsScriptSkips(
    script: QuickScriptEntity?,
    hosts: List<ServerEntity>,
    metricsById: Map<Int, HostMetrics>,
): List<ServerEntity> {
    if (script == null || scriptTargetsAnyHost(script)) return emptyList()
    return hosts.filter { host -> metricsById[host.id]?.let { !scriptTargetsHost(script, it) } ?: false }
}

/** The target a script names, such as "Linux · Proxmox", for a skipped-hosts note. */
fun scriptTargetLabel(script: QuickScriptEntity): String =
    listOfNotNull(
        script.targetOs.takeUnless { it.isBlank() || it.equals("Any", ignoreCase = true) },
        script.targetSystem.takeUnless { it.isBlank() || it.equals("Any", ignoreCase = true) },
        script.category.takeIf { legacyCategoryPlatformKey(it) != null },
    ).distinct().joinToString(" · ")

/** Whether [script]'s target OS and system allow a host with [metrics], whatever screen runs it. */
fun scriptTargetsHost(script: QuickScriptEntity, metrics: HostMetrics?): Boolean {
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
