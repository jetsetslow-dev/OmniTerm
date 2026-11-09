package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.DiskUsage
import com.jetsetslow.omniterm.data.HostChecks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HostChecksTest {
    @get:Rule val tmp = TemporaryFolder()

    private val tab = "\t"

    private fun row(vararg cells: String) = cells.joinToString(tab)

    private val fullOutput = listOf(
        "@FAILED", "!OK", "nginx.service", "smartd.service",
        "@CONTAINERS", "!OK",
        row("docker", "a1", "web", "nginx", "Up 2 hours (unhealthy)", "80/tcp"),
        row("docker", "a2", "job", "alpine", "Exited (0) 1 hour ago", ""),
        row("docker", "a3", "stopped", "alpine", "Exited (137) 1 hour ago", ""),
        row("docker", "a4", "crash", "alpine", "Exited (1) 5 minutes ago", ""),
        row("podman", "a5", "loop", "alpine", "Restarting (1) 3 seconds ago", ""),
        row("podman", "a6", "db", "postgres", "Up 3 days (healthy)", "5432/tcp"),
        "@ZFS", "!OK", row("tank", "ONLINE", "1729988641"), row("backup", "DEGRADED", ""),
        "@MDSTAT", "!OK",
        "Personalities : [raid1]",
        "md0 : active raid1 sdb1[1] sda1[0]",
        "      1046528 blocks super 1.2 [2/1] [U_]",
        "md1 : inactive sdc1[0](S)",
        "md2 : active raid1 sdd1[1] sde1[0]",
        "      1046528 blocks super 1.2 [2/2] [UU]",
        "unused devices: <none>",
        "@UPS", "!OK", row("ups1", "OL CHRG"), row("ups2", "OB DISCHRG"),
        "@REBOOT", "!OK", "yes",
    ).joinToString("\n")

    @Test
    fun aHostThatAnswersEverySectionReportsWhatIsWrong() {
        val r = HostChecks.parse(fullOutput)
        assertEquals(listOf("nginx.service", "smartd.service"), r.failedServices)
        // A container stopped by hand (0, or 137 after SIGKILL) is not trouble; one that crashed is.
        assertEquals(listOf("web (unhealthy)", "crash (exited 1)", "loop (restarting)"), r.containerProblems)
        assertEquals(listOf("backup (degraded)", "md0 (degraded)", "md1 (inactive)"), r.arrayProblems)
        assertEquals(mapOf("tank" to 1729988641L), r.scrubbedAt)
        assertEquals(listOf("ups2"), r.upsOnBattery)
        assertEquals(true, r.rebootRequired)
    }

    @Test
    fun aSectionWhoseToolDidNotRunIsUnknownNotNone() {
        val r = HostChecks.parse("@FAILED\n@CONTAINERS\n@ZFS\n@MDSTAT\n@UPS\n@REBOOT\n!OK\n")
        assertNull(r.failedServices)
        assertNull(r.containerProblems)
        assertNull(r.arrayProblems)
        assertNull(r.scrubbedAt)
        assertNull(r.upsOnBattery)
        assertEquals(false, r.rebootRequired)
        val now = 1_800_000_000L
        for (check in HostChecks.ALL - HostChecks.HOST_OFFLINE - HostChecks.REBOOT_REQUIRED) {
            assertNull(check, HostChecks.valueOf(check, r, disks = emptyList(), nowEpochSec = now))
        }
        assertEquals(0f to emptyList<String>(), HostChecks.valueOf(HostChecks.REBOOT_REQUIRED, r, emptyList(), now))
    }

    @Test
    fun eachCheckReadsItsNumberAndNamesWhatIsBehindIt() {
        val r = HostChecks.parse(fullOutput)
        val now = 1729988641L + 40 * 86_400L
        val disks = listOf(
            DiskUsage("/", "/dev/sda1", 100, 50, health = "PASSED"),
            DiskUsage("/srv", "/dev/sdf1", 100, 50, health = "FAILED!"),
            DiskUsage("/mnt", "/dev/sdg1", 100, 50),
        )
        fun value(check: String) = HostChecks.valueOf(check, r, disks, now)
        assertEquals(2f to listOf("nginx.service", "smartd.service"), value(HostChecks.FAILED_SERVICES))
        assertEquals(3f, value(HostChecks.CONTAINER_PROBLEMS)?.first)
        assertEquals(
            4f to listOf("backup (degraded)", "md0 (degraded)", "md1 (inactive)", "/dev/sdf1 (SMART FAILED!)"),
            value(HostChecks.STORAGE_HEALTH),
        )
        assertEquals(40f to listOf("tank"), value(HostChecks.SCRUB_AGE))
        assertEquals(1f to listOf("ups2"), value(HostChecks.UPS_ON_BATTERY))
        assertEquals(1f, value(HostChecks.REBOOT_REQUIRED)?.first)
        // SMART alone is enough to know a host's storage health, healthy or not.
        val smartOnly = HostChecks.Reading()
        assertEquals(1f, HostChecks.valueOf(HostChecks.STORAGE_HEALTH, smartOnly, disks, now)?.first)
        assertEquals(0f, HostChecks.valueOf(HostChecks.STORAGE_HEALTH, smartOnly, disks.take(1), now)?.first)
        assertNull(HostChecks.valueOf(HostChecks.STORAGE_HEALTH, smartOnly, disks.takeLast(1), now))
    }

    @Test
    fun notificationsNameUpToFiveItems() {
        val names = (1..7).map { "unit$it.service" }
        assertEquals(
            "7 failed services: unit1.service, unit2.service, unit3.service, unit4.service, unit5.service and 2 more",
            HostChecks.alertText(HostChecks.FAILED_SERVICES, 7f, 0f, names),
        )
        assertEquals("1 container in trouble: web (unhealthy)", HostChecks.alertText(HostChecks.CONTAINER_PROBLEMS, 1f, 0f, listOf("web (unhealthy)")))
        assertEquals("Pool tank last scrubbed 40 days ago (limit 35)", HostChecks.alertText(HostChecks.SCRUB_AGE, 40.6f, 35f, listOf("tank")))
        assertEquals("On battery: ups2", HostChecks.alertText(HostChecks.UPS_ON_BATTERY, 1f, 0f, listOf("ups2")))
        assertEquals("Not reachable over SSH", HostChecks.alertText(HostChecks.HOST_OFFLINE, 1f, 0f, emptyList()))
        assertEquals("offline", HostChecks.describe(HostChecks.HOST_OFFLINE, 1f))
        assertEquals("online", HostChecks.describe(HostChecks.HOST_OFFLINE, 0f))
    }

    @Test
    fun yesNoChecksTakeNoThresholdAndOneOffFactsAlertAtOnce() {
        assertTrue(HostChecks.isYesNo(HostChecks.HOST_OFFLINE))
        assertFalse(HostChecks.isYesNo(HostChecks.FAILED_SERVICES))
        assertEquals(35f, HostChecks.defaultThreshold(HostChecks.SCRUB_AGE))
        assertEquals("0m", HostChecks.defaultWindow(HostChecks.REBOOT_REQUIRED))
        assertEquals("2m", HostChecks.defaultWindow(HostChecks.HOST_OFFLINE))
        assertFalse(HostChecks.needsProbe(HostChecks.HOST_OFFLINE))
        assertTrue(HostChecks.needsProbe(HostChecks.STORAGE_HEALTH))
        assertFalse(HostChecks.needsProbe("CPU Usage"))
    }

    /**
     * The probe itself, in a real POSIX shell, against stand-in tools: only the stubs and a few
     * base utilities are on PATH, and the system paths it reads point into a scratch folder, so the
     * result does not depend on what this machine runs.
     */
    @Test
    fun theProbeReportsEachToolThatRanAndNothingForToolsThatAreMissing() {
        val sh = TestShell.sh
        assumeTrue("needs a POSIX shell", sh != null)
        val bin = tmp.newFolder("bin")
        val base = listOf("sed", "awk", "head", "date", "cat", "ls", "sort", "tail", "grep", "timeout")
        for (tool in base) {
            val real = System.getenv("PATH").orEmpty().split(File.pathSeparator).map { File(it, tool) }.firstOrNull { it.canExecute() }
            assumeTrue("needs $tool", real != null)
            java.nio.file.Files.createSymbolicLink(File(bin, tool).toPath(), real!!.toPath())
        }
        assumeTrue("needs a date that reads -d", run(sh!!, bin, "date -d 'Sun Oct 27 00:24:01 2024' +%s").trim() == "1729988641")

        // Nothing but the base tools: every section is unknown.
        val bare = HostChecks.parse(run(sh!!, bin, probeIn(tmp.root)))
        assertEquals(HostChecks.Reading(), bare)

        fun stub(name: String, body: String) = File(bin, name).apply {
            writeText("#!/bin/sh\n$body\n")
            setExecutable(true)
        }
        stub("systemctl", "printf 'nginx.service loaded failed failed A web server\\n'")
        stub(
            "docker",
            """case "$*" in "ps") exit 0 ;; "ps -a"*) printf 'docker\ta1\tweb\tnginx\tUp 2 hours (unhealthy)\t\ndocker\ta2\tstopped\talpine\tExited (143) 1 hour ago\t\n' ;; esac""",
        )
        stub(
            "zpool",
            """case "$*" in "list -H -o name,health") printf 'tank\tONLINE\nbackup\tDEGRADED\n' ;; "status tank") echo '  scan: scrub repaired 0B in 00:01:02 with 0 errors on Sun Oct 27 00:24:01 2024' ;; *) echo '  scan: none requested' ;; esac""",
        )
        stub("upsc", """case "$*" in "-l") printf 'ups1\nups2\n' ;; "ups1 ups.status") echo OL ;; "ups2 ups.status") echo 'OB DISCHRG' ;; esac""")
        stub("uname", "echo 6.8.12-4-pve")
        File(tmp.root, "run-systemd").mkdirs()
        File(tmp.root, "mdstat").writeText("md0 : active raid1 sdb1[1] sda1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n")
        File(tmp.root, "debian_version").writeText("12.7\n")
        File(tmp.root, "boot").mkdirs()
        listOf("6.8.12-4-pve", "6.8.12-5-pve", "6.9.1-1-generic").forEach { File(tmp.root, "boot/vmlinuz-$it").writeText("") }

        val r = HostChecks.parse(run(sh!!, bin, probeIn(tmp.root)))
        assertEquals(listOf("nginx.service"), r.failedServices)
        assertEquals(listOf("web (unhealthy)"), r.containerProblems)
        assertEquals(listOf("backup (degraded)", "md0 (degraded)"), r.arrayProblems)
        assertEquals(mapOf("tank" to 1729988641L), r.scrubbedAt)
        assertEquals(listOf("ups2"), r.upsOnBattery)
        // A newer kernel of the running flavour is installed; the other flavour does not count.
        assertEquals(true, r.rebootRequired)

        File(tmp.root, "boot/vmlinuz-6.8.12-5-pve").delete()
        assertEquals(false, HostChecks.parse(run(sh!!, bin, probeIn(tmp.root))).rebootRequired)
    }

    /** [HostChecks.PROBE] with every system path it reads moved under [root]. */
    private fun probeIn(root: File): String {
        val moves = listOf(
            "/run/systemd/system" to "${root.path}/run-systemd",
            "/proc/mdstat" to "${root.path}/mdstat",
            "/var/run/reboot-required" to "${root.path}/reboot-required",
            "/etc/debian_version" to "${root.path}/debian_version",
            "/boot/vmlinuz-" to "${root.path}/boot/vmlinuz-",
            "/etc/arch-release" to "${root.path}/arch-release",
        )
        var probe = HostChecks.PROBE
        for ((from, to) in moves) {
            assertTrue("the probe reads $from", from in probe)
            probe = probe.replace(from, to)
        }
        // Nothing else under these folders is read, so the host's own files cannot leak in.
        val rest = moves.fold(probe) { s, (_, to) -> s.replace(to, "") }
        listOf("/run/", "/proc/", "/var/", "/etc/", "/boot/").forEach { assertFalse("$it left in the probe", it in rest) }
        return probe
    }

    private fun run(sh: File, bin: File, script: String): String =
        TestShell.run(script, env = mapOf("PATH" to bin.path, "TZ" to "UTC", "LC_ALL" to "C"), clean = true, shell = sh).output
}
