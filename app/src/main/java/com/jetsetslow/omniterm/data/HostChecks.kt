package com.jetsetslow.omniterm.data

import java.util.Locale

/**
 * Alert rules about a host's state rather than a usage figure: whether it answers at all, failed
 * services, containers in trouble, storage health, the last ZFS scrub, a UPS on battery, a
 * pending reboot, and a saved script's exit status ([ScriptChecks]). Each reading is a plain
 * number, so it fits the same incident and history rows as every other metric: a count, a number
 * of days, an exit status, or 1 for yes.
 *
 * Credit: the alert classes follow Beszel (henrygd/beszel#437 host down, #716 containers, #1813
 * systemd services) and Uptime Kuma (louislam/uptime-kuma#177, #819).
 */
object HostChecks {
    const val HOST_OFFLINE = "Host Offline"
    const val FAILED_SERVICES = "Failed Services"
    const val CONTAINER_PROBLEMS = "Container Problems"
    const val STORAGE_HEALTH = "Storage Health"
    const val SCRUB_AGE = "ZFS Scrub Age"
    const val UPS_ON_BATTERY = "UPS On Battery"
    const val REBOOT_REQUIRED = "Reboot Required"
    const val SCRIPT_CHECK = "Script Check"

    val ALL = listOf(
        HOST_OFFLINE, FAILED_SERVICES, CONTAINER_PROBLEMS, STORAGE_HEALTH, SCRUB_AGE, UPS_ON_BATTERY, REBOOT_REQUIRED,
        SCRIPT_CHECK,
    )

    fun isHostCheck(metricName: String) = metricName in ALL

    /** Checks that run a command on the host. Host Offline comes from the reachability probe itself. */
    fun runsOnHost(metricName: String) = isHostCheck(metricName) && metricName != HOST_OFFLINE

    /** Checks read with [PROBE]. A script check runs its own script ([ScriptChecks]). */
    fun needsProbe(metricName: String) = runsOnHost(metricName) && metricName != SCRIPT_CHECK

    /**
     * Yes-or-no checks: the threshold is fixed at 0, so the rule editor does not ask for one. A
     * script check alerts on any exit status but 0.
     */
    fun isYesNo(metricName: String) =
        metricName == HOST_OFFLINE || metricName == UPS_ON_BATTERY || metricName == REBOOT_REQUIRED ||
            metricName == SCRIPT_CHECK

    fun defaultThreshold(metricName: String): Float = if (metricName == SCRUB_AGE) 35f else 0f

    /** How long a reading must hold before it alerts; a pending reboot or an old scrub at once. */
    fun defaultWindow(metricName: String): String = when (metricName) {
        HOST_OFFLINE, SCRIPT_CHECK -> "2m"
        REBOOT_REQUIRED, SCRUB_AGE -> "0m"
        else -> "5m"
    }

    /** Exit statuses of a container someone stopped: 130 SIGINT, 137 SIGKILL, 143 SIGTERM. */
    private val STOPPED_EXIT_CODES = setOf(0, 130, 137, 143)

    /**
     * One round trip for every probed check. Each section prints `!OK` only when its tool ran, so
     * a host without systemd, ZFS or NUT says nothing about them instead of reporting "none".
     * POSIX sh with the [RemoteCommands.OT_HELPER] time limits, so one wedged tool cannot hang it.
     */
    val PROBE: String = buildString {
        append(RemoteCommands.OT_HELPER)
        // systemd as PID 1, not merely installed (containers often ship systemctl without it).
        append("echo '@FAILED'; if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then ")
        append("echo '!OK'; ot 10 systemctl --failed --no-legend --plain 2>/dev/null | awk '{print \$1}'; fi; ")
        // The container list Docker → Containers uses, so a row reads the same in both places.
        append("echo '@CONTAINERS'; o=\$( ( ${RemoteCommands.DOCKER_PS} ) 2>/dev/null ) && { echo '!OK'; printf '%s\\n' \"\$o\"; }; ")
        append("echo '@ZFS'; if command -v zpool >/dev/null 2>&1; then echo '!OK'; ")
        append("ot 10 zpool list -H -o name,health 2>/dev/null | while read -r p h; do ")
        append("d=\$(ot 10 zpool status \"\$p\" 2>/dev/null | sed -n 's/.*scrub repaired.* on //p' | head -1); ")
        // GNU and BusyBox date take -d; FreeBSD (TrueNAS CORE) parses the same ctime text with -j -f.
        append("e=; [ -n \"\$d\" ] && e=\$(date -d \"\$d\" +%s 2>/dev/null || date -j -f '%a %b %d %H:%M:%S %Y' \"\$d\" +%s 2>/dev/null); ")
        append("printf '%s\\t%s\\t%s\\n' \"\$p\" \"\$h\" \"\$e\"; done; fi; ")
        append("echo '@MDSTAT'; if [ -r /proc/mdstat ]; then echo '!OK'; cat /proc/mdstat; fi; ")
        append("echo '@UPS'; if command -v upsc >/dev/null 2>&1; then echo '!OK'; ")
        append("for u in \$(ot 5 upsc -l 2>/dev/null); do s=\$(ot 5 upsc \"\$u\" ups.status 2>/dev/null) && printf '%s\\t%s\\n' \"\$u\" \"\$s\"; done; fi; ")
        // Only where the host can tell, so other systems stay unknown rather than "no reboot needed".
        // Debian family: the reboot-required flag, or a newer installed kernel of the running flavour
        // (plain Debian and Proxmox never write the flag); the Red Hat family: needs-restarting exits
        // 1; Arch: the running kernel's modules are gone; FreeBSD: installed != running kernel.
        append("echo '@REBOOT'; ")
        append("if [ -f /etc/debian_version ]; then echo '!OK'; r=\$(uname -r); f=\$(printf '%s' \"\$r\" | sed 's/^[0-9.]*-[0-9]*//'); ")
        append("k=\$(ls /boot/vmlinuz-*\"\$f\" 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V 2>/dev/null | tail -n 1); ")
        append("if [ -f /var/run/reboot-required ] || { [ -n \"\$k\" ] && [ \"\$k\" != \"\$r\" ]; }; then echo yes; fi; ")
        append("elif command -v needs-restarting >/dev/null 2>&1; then echo '!OK'; ot 30 needs-restarting -r >/dev/null 2>&1; [ \$? -eq 1 ] && echo yes; ")
        append("elif [ -f /etc/arch-release ] && [ -d /usr/lib/modules ]; then echo '!OK'; [ -d \"/usr/lib/modules/\$(uname -r)\" ] || echo yes; ")
        append("elif command -v freebsd-version >/dev/null 2>&1; then echo '!OK'; [ \"\$(freebsd-version -k)\" != \"\$(freebsd-version -r)\" ] && echo yes; ")
        append("fi; true")
    }

    /** What [PROBE] found; a null field is a check the host could not answer. */
    data class Reading(
        val failedServices: List<String>? = null,
        /** Each as "name (why)". */
        val containerProblems: List<String>? = null,
        /** ZFS pools not ONLINE and degraded or inactive md arrays, each as "name (state)". */
        val arrayProblems: List<String>? = null,
        /** Pool name to the epoch second of its last finished scrub. */
        val scrubbedAt: Map<String, Long>? = null,
        /** UPS units on battery or low battery. */
        val upsOnBattery: List<String>? = null,
        val rebootRequired: Boolean? = null,
    )

    fun parse(raw: String): Reading {
        val sections = RemoteParsers.splitSections(raw)
        fun known(name: String): List<String>? {
            val lines = sections[name]?.lineSequence()?.map { it.trimEnd() }?.filter { it.isNotBlank() }?.toList() ?: return null
            if (lines.firstOrNull()?.startsWith("!OK") != true) return null
            return lines.drop(1)
        }
        val zfs = known("ZFS")?.map { it.split('\t') }
        val pools = zfs?.mapNotNull { cells -> cells.getOrNull(0)?.takeIf { it.isNotBlank() }?.let { it to cells } }
        val poolProblems = pools?.filter { (_, cells) -> !cells.getOrElse(1) { "" }.equals("ONLINE", ignoreCase = true) }
            ?.map { (name, cells) -> "$name (${cells.getOrElse(1) { "unknown" }.trim().lowercase(Locale.ROOT)})" }
        val mdProblems = known("MDSTAT")?.let(::mdArrayProblems)
        return Reading(
            failedServices = known("FAILED")?.map { it.trim() },
            containerProblems = known("CONTAINERS")?.let { rows -> containerProblems(rows.joinToString("\n")) },
            arrayProblems = if (poolProblems == null && mdProblems == null) null else poolProblems.orEmpty() + mdProblems.orEmpty(),
            scrubbedAt = pools?.mapNotNull { (name, cells) -> cells.getOrNull(2)?.trim()?.toLongOrNull()?.let { name to it } }?.toMap(),
            upsOnBattery = known("UPS")?.mapNotNull { line ->
                val name = line.substringBefore('\t').trim()
                val status = line.substringAfter('\t', "").split(' ').map { it.trim().uppercase(Locale.ROOT) }
                name.takeIf { it.isNotEmpty() && ("OB" in status || "LB" in status) }
            },
            rebootRequired = known("REBOOT")?.any { it.trim() == "yes" },
        )
    }

    /** Containers that are unhealthy, restarting, or exited with an error (not a stop). */
    fun containerProblems(dockerPs: String): List<String> =
        RemoteParsers.parseDockerPs(dockerPs).mapNotNull { c ->
            when {
                c.health == "unhealthy" -> "${c.name} (unhealthy)"
                c.status == "restarting" -> "${c.name} (restarting)"
                c.status == "exited" && c.exitCode != null && c.exitCode !in STOPPED_EXIT_CODES -> "${c.name} (exited ${c.exitCode})"
                else -> null
            }
        }

    /** md arrays with a missing member (`[U_]`) or not running, from /proc/mdstat. */
    fun mdArrayProblems(lines: List<String>): List<String> {
        val problems = mutableListOf<String>()
        var array: String? = null
        for (line in lines) {
            val head = Regex("""^(md\S+)\s*:\s*(\S+)""").find(line)
            if (head != null) {
                array = head.groupValues[1]
                if (head.groupValues[2] == "inactive") problems += "$array (inactive)"
                continue
            }
            val members = Regex("""\[\d+/\d+]\s*\[([U_]+)]""").find(line)?.groupValues?.get(1) ?: continue
            if ('_' in members && array != null) problems += "$array (degraded)"
        }
        return problems.distinct()
    }

    /**
     * The value [metricName] reads from [reading] (and a failing-disk list from the metrics
     * probe), with the names behind it; null when the host could not tell.
     */
    fun valueOf(metricName: String, reading: Reading, disks: List<DiskUsage>, nowEpochSec: Long): Pair<Float, List<String>>? =
        when (metricName) {
            FAILED_SERVICES -> reading.failedServices?.let { it.size.toFloat() to it }
            CONTAINER_PROBLEMS -> reading.containerProblems?.let { it.size.toFloat() to it }
            STORAGE_HEALTH -> {
                val failing = disks.filter { it.health.isNotBlank() && !it.health.equals("PASSED", true) && !it.health.equals("OK", true) }
                    .map { "${it.filesystem} (SMART ${it.health})" }.distinct()
                if (reading.arrayProblems == null && failing.isEmpty() && disks.none { it.health.isNotBlank() }) null
                else (reading.arrayProblems.orEmpty() + failing).let { it.size.toFloat() to it }
            }
            SCRUB_AGE -> reading.scrubbedAt?.takeIf { it.isNotEmpty() }?.let { pools ->
                val (pool, at) = pools.minBy { it.value }
                ((nowEpochSec - at).coerceAtLeast(0) / 86_400f) to listOf(pool)
            }
            UPS_ON_BATTERY -> reading.upsOnBattery?.let { (if (it.isEmpty()) 0f else 1f) to it }
            REBOOT_REQUIRED -> reading.rebootRequired?.let { (if (it) 1f else 0f) to emptyList() }
            else -> null
        }

    /** A reading as the rule list and notifications show it. */
    fun describe(metricName: String, value: Float): String = when (metricName) {
        HOST_OFFLINE -> if (value > 0f) "offline" else "online"
        UPS_ON_BATTERY -> if (value > 0f) "on battery" else "on mains"
        REBOOT_REQUIRED -> if (value > 0f) "reboot required" else "no reboot needed"
        SCRUB_AGE -> "${value.toInt()} days"
        FAILED_SERVICES -> plural(value.toInt(), "failed service")
        CONTAINER_PROBLEMS -> plural(value.toInt(), "container in trouble", "containers in trouble")
        STORAGE_HEALTH -> plural(value.toInt(), "storage problem")
        SCRIPT_CHECK -> if (value > 0f) "exit ${value.toInt()}" else "passed"
        else -> value.toString()
    }

    /**
     * The notification line for an alert, naming up to five of the items behind it. For a script
     * check, [names] is the script's name and then the first line it printed, if any.
     */
    fun alertText(metricName: String, value: Float, threshold: Float, names: List<String>): String {
        if (metricName == SCRIPT_CHECK) {
            val script = names.firstOrNull()?.takeIf { it.isNotBlank() } ?: "The check script"
            return "$script failed (${describe(SCRIPT_CHECK, value)})" + (names.getOrNull(1)?.takeIf { it.isNotBlank() }?.let { ": $it" } ?: "")
        }
        val listed = names.take(5).joinToString(", ") + if (names.size > 5) " and ${names.size - 5} more" else ""
        return when (metricName) {
            HOST_OFFLINE -> "Not reachable over SSH"
            SCRUB_AGE -> (if (listed.isEmpty()) "Last scrub" else "Pool $listed last scrubbed") +
                " ${value.toInt()} days ago (limit ${threshold.toInt()})"
            REBOOT_REQUIRED -> "Updates need a reboot"
            UPS_ON_BATTERY -> if (listed.isEmpty()) "A UPS is on battery" else "On battery: $listed"
            else -> describe(metricName, value) + if (listed.isNotEmpty()) ": $listed" else ""
        }
    }

    /** The last reading as the rule list shows it, naming up to three items. */
    fun summary(metricName: String, value: Float, names: List<String>): String {
        val listed = names.take(3).joinToString(", ") + if (names.size > 3) " and ${names.size - 3} more" else ""
        return when {
            metricName == SCRIPT_CHECK -> describe(SCRIPT_CHECK, value) + (names.getOrNull(1)?.takeIf { it.isNotBlank() }?.let { ": $it" } ?: "")
            metricName == SCRUB_AGE -> "Last scrub ${value.toInt()} days ago" + if (listed.isNotEmpty()) " ($listed)" else ""
            value > 0f && listed.isNotEmpty() -> describe(metricName, value) + ": $listed"
            else -> describe(metricName, value)
        }
    }

    private fun plural(n: Int, one: String, many: String = one + "s") = "$n ${if (n == 1) one else many}"
}
