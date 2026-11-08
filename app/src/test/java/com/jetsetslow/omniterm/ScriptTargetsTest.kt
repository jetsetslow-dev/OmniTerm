package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.HostMetrics
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ScriptParams
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.FLEET_SYSLOG_COMMAND
import com.jetsetslow.omniterm.ui.HOMELAB_UPDATES_COMMAND
import com.jetsetslow.omniterm.ui.builtInFleetPresetCommands
import com.jetsetslow.omniterm.ui.fleetHostsScriptSkips
import com.jetsetslow.omniterm.ui.homelabPresetScripts
import com.jetsetslow.omniterm.ui.quickScriptMatchesHost
import com.jetsetslow.omniterm.ui.retiredPresetScripts
import com.jetsetslow.omniterm.ui.scriptTargetLabel
import com.jetsetslow.omniterm.ui.scriptTargetsAnyHost
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

/** Fleet runs follow a saved script's target OS and system, and the built-in scripts are sound. */
class ScriptTargetsTest {

    private fun metrics(os: String, vararg platforms: String) =
        HostMetrics(0f, 0, 0, 0, 0, 0f, 0f, 0f, 0, 0, os = os, platforms = platforms.toSet())

    private fun host(id: Int) = ServerEntity(id = id, name = "h$id", host = "10.0.0.$id", username = "u")

    private fun script(os: String = "Any", system: String = "Any", category: String = "General") =
        QuickScriptEntity(emoji = "X", name = "s", command = "true", color = "cyan", category = category, targetOs = os, targetSystem = system, availableForFleet = true)

    @Test
    fun fleetSkipsOnlyHostsKnownNotToMatch() {
        val hosts = listOf(host(1), host(2), host(3), host(4))
        val metricsById = mapOf(
            1 to metrics("Linux", "linux", "proxmox"),
            2 to metrics("Windows", "windows"),
            3 to metrics("FreeBSD", "freebsd"),
            // Host 4 has not been probed yet: it is tried, not skipped on a guess.
        )
        assertEquals(listOf(2, 3), fleetHostsScriptSkips(script(os = "Linux"), hosts, metricsById).map { it.id })
        assertEquals(listOf(2, 3), fleetHostsScriptSkips(script(system = "Proxmox"), hosts, metricsById).map { it.id })
        // The older category-only targeting counts too.
        assertEquals(listOf(2, 3), fleetHostsScriptSkips(script(category = "Proxmox"), hosts, metricsById).map { it.id })
        assertTrue(fleetHostsScriptSkips(script(), hosts, metricsById).isEmpty())
        assertTrue(fleetHostsScriptSkips(null, hosts, metricsById).isEmpty())
    }

    @Test
    fun theTargetLabelNamesWhatTheScriptIsFor() {
        assertEquals("Linux · Proxmox", scriptTargetLabel(script(os = "Linux", system = "Proxmox")))
        assertEquals("Proxmox", scriptTargetLabel(script(category = "Proxmox")))
        assertTrue(scriptTargetsAnyHost(script()))
        assertFalse(scriptTargetsAnyHost(script(os = "Windows")))
    }

    @Test
    fun quickScriptsStillNeedTheQuickFlag() {
        val linux = metrics("Linux", "linux")
        assertTrue(quickScriptMatchesHost(script().copy(availableForQuick = true), linux))
        assertFalse(quickScriptMatchesHost(script().copy(availableForQuick = false), linux))
        assertFalse(quickScriptMatchesHost(script(os = "Windows").copy(availableForQuick = true), linux))
    }

    @Test
    fun proxmoxVmPresetsAskWhichVm() {
        val start = homelabPresetScripts.single { it.presetKey == "homelab.pve_start_vm" }
        val stop = homelabPresetScripts.single { it.presetKey == "homelab.pve_stop_vm" }
        // They used to act on VM 100 whatever the user meant.
        assertEquals(listOf("vmid"), ScriptParams.parse(start.command).map { it.name })
        assertEquals(listOf("vmid"), ScriptParams.parse(stop.command).map { it.name })
        assertFalse(start.command.contains("100"))
        assertEquals("qm shutdown 105", ScriptParams.fill(stop.command, mapOf("vmid" to "105"), ScriptParams.Shell.Posix))
    }

    @Test
    fun everyRetiredPresetHasACurrentReplacementThatDiffers() {
        val current = (homelabPresetScripts + builtInFleetPresetCommands.keys.map { key ->
            QuickScriptEntity(emoji = "", name = "", command = builtInFleetPresetCommands.getValue(key), color = "", presetKey = key)
        }).associateBy { it.presetKey }
        retiredPresetScripts.forEach { retired ->
            val replacement = current[retired.presetKey]
            assertTrue("${retired.presetKey} has no current preset", replacement != null)
            assertNotEquals(retired.presetKey, retired.command, replacement!!.command)
        }
        assertEquals(retiredPresetScripts.size, retiredPresetScripts.map { it.presetKey }.distinct().size)
    }

    @Test
    fun builtInPresetsKeepPlaceholdersOutOfDockerTemplates() {
        builtInFleetPresetCommands.values.forEach { assertFalse(it, ScriptParams.hasParams(it)) }
    }

    /** The rewritten fallback chains are valid sh, and each branch is reached by testing for its tool. */
    @Test
    fun rewrittenFallbacksParseInSh() {
        val sh = File("/bin/sh")
        assumeTrue("needs /bin/sh", sh.canExecute())
        listOf(FLEET_SYSLOG_COMMAND, HOMELAB_UPDATES_COMMAND).forEach { command ->
            val process = ProcessBuilder(sh.path, "-n", "-c", command).redirectErrorStream(true).start()
            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
            assertEquals(command + "\n" + process.inputStream.readBytes().toString(Charsets.UTF_8), 0, process.exitValue())
        }
    }

    /** `dnf check-update` exits 100 when there are updates: that is a result, not a failure. */
    @Test
    fun dnfUpdatesAvailableIsSuccess() {
        val sh = File("/bin/sh")
        assumeTrue("needs /bin/sh", sh.canExecute())
        val dir = kotlin.io.path.createTempDirectory("omniterm-dnf").toFile()
        try {
            // A PATH holding only a fake dnf, so the apt branch is not taken on this machine.
            File(dir, "dnf").apply { writeText("#!/bin/sh\necho 'bash.x86_64 5.2 updates'\nexit 100\n"); setExecutable(true) }
            val process = ProcessBuilder(sh.path, "-c", HOMELAB_UPDATES_COMMAND)
                .redirectErrorStream(true)
                .apply { environment()["PATH"] = dir.path }
                .start()
            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
            val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
            assertTrue(output, output.contains("bash.x86_64"))
            assertEquals(output, 0, process.exitValue())
        } finally {
            dir.deleteRecursively()
        }
    }
}
