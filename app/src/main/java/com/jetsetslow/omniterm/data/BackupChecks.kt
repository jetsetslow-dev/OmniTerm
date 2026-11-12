package com.jetsetslow.omniterm.data

import com.squareup.moshi.Moshi
import java.util.Locale
import kotlin.math.roundToInt

/**
 * A [HostChecks.BACKUP_AGE] rule: how many hours ago the newest backup in one repository was made,
 * read on the host with the backup tool itself. restic, Borg, Proxmox Backup Server (its client)
 * and Proxmox vzdump files are read; the reading alerts when it passes the rule's limit in hours,
 * and also when the check finds no backup, no tool, no repository, or a wrong password. A
 * repository busy with a backup reads as unknown, so a running backup never alerts.
 *
 * The rule's `target` holds the [Target], one field per line; its `secret` holds the repository
 * password, encrypted on the phone and sent on the command's standard input, so it never appears
 * in the command line, `ps`, a log or History.
 */
object BackupChecks {
    /** Repositories are read once every 15 minutes per rule and host: a listing can be slow. */
    const val INTERVAL_MS = 15 * 60_000L
    /** A listing that has not finished by then reads as unknown: a slow repository is not a missing backup. */
    const val TIMEOUT_SEC = 90
    const val DEFAULT_THRESHOLD_HOURS = 26f

    // What a reading below 0 means. Each one alerts, whatever the limit.
    const val NO_BACKUPS = -1f
    const val TOOL_MISSING = -2f
    const val REPO_MISSING = -3f
    const val AUTH_FAILED = -4f
    const val FAILED = -5f

    enum class Tool(val key: String, val label: String, val binary: String) {
        RESTIC("restic", "restic", "restic"),
        BORG("borg", "Borg", "borg"),
        PBS("pbs", "Proxmox Backup Server", "proxmox-backup-client"),
        VZDUMP("vzdump", "Proxmox vzdump files", "");

        companion object {
            fun of(key: String): Tool? = entries.find { it.key == key.trim().lowercase(Locale.ROOT) }
        }
    }

    /**
     * What a rule reads: [repository] (a restic or Borg repository, a PBS repository such as
     * `backup@pbs@pbs.lan:store`, or the folder vzdump writes to), an optional [filter] (restic: a
     * host name; Borg: an archive name pattern such as `nas-*`; PBS: a backup group such as
     * `vm/100`; vzdump: a guest ID), an optional [settingsFile] on the host to read first (for
     * example the environment file a backup job uses, with RESTIC_REPOSITORY or cloud keys), and
     * for PBS the server's certificate [fingerprint] when it is not trusted already.
     */
    data class Target(
        val tool: Tool,
        val repository: String,
        val filter: String = "",
        val settingsFile: String = "",
        val fingerprint: String = "",
    )

    fun encode(target: Target): String =
        listOf(target.tool.key, target.repository, target.filter, target.settingsFile, target.fingerprint)
            .joinToString("\n") { it.replace('\n', ' ').replace('\r', ' ').trim() }
            .trimEnd('\n')

    fun decode(target: String): Target? {
        val lines = target.split('\n')
        val tool = Tool.of(lines.firstOrNull().orEmpty()) ?: return null
        fun at(i: Int) = lines.getOrNull(i)?.trim().orEmpty()
        return Target(tool, at(1), at(2), at(3), at(4))
    }

    /** Why [target] cannot be checked, or null when it can. */
    fun problem(target: Target?): String? = when {
        target == null -> "Pick a backup tool"
        target.tool == Tool.VZDUMP && target.repository.isBlank() -> "Enter the folder vzdump writes to"
        target.tool == Tool.VZDUMP && target.filter.isNotBlank() && target.filter.toIntOrNull()?.takeIf { it > 0 } == null ->
            "A guest ID is a number, like 100"
        target.repository.isBlank() && target.settingsFile.isBlank() ->
            "Enter the repository, or a settings file on the host that names it"
        target.tool == Tool.PBS && target.fingerprint.isNotBlank() && !FINGERPRINT.matches(target.fingerprint) ->
            "A fingerprint is 32 pairs of hex digits, like ab:cd:…"
        else -> null
    }

    private val FINGERPRINT = Regex("""^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){31}$""")

    private fun q(s: String) = RemoteCommands.shellQuote(s)

    /**
     * The POSIX sh command that reads [target]'s newest backup. The first line of its standard
     * input is the repository password; it is exported only to the backup tool's own variable.
     * The tool runs with no terminal and no input, so a prompt fails instead of waiting.
     */
    fun command(target: Target): String = buildString {
        append(RemoteCommands.OT_HELPER)
        append("IFS= read -r p || p=; ")
        if (target.settingsFile.isNotBlank()) {
            val f = q(target.settingsFile)
            append("if [ ! -r $f ]; then echo '@BACKUP'; echo '!SETTINGS'; exit 0; fi; set -a; . $f; set +a; ")
        }
        append("echo '@BACKUP'; ")
        val tool = target.tool
        if (tool == Tool.VZDUMP) {
            append(vzdumpListing(target))
            return@buildString
        }
        append("if ! command -v ${tool.binary} >/dev/null 2>&1; then echo '!TOOL'; exit 0; fi; ")
        append("e=\$(mktemp 2>/dev/null || echo \"/tmp/omniterm-backup.\$\$\"); ")
        when (tool) {
            Tool.RESTIC -> {
                append("[ -n \"\$p\" ] && export RESTIC_PASSWORD=\"\$p\"; ")
                append("ot $TIMEOUT_SEC restic")
                if (target.repository.isNotBlank()) append(" -r ${q(target.repository)}")
                // --no-lock: reading never waits on, or blocks, a backup that is running.
                append(" snapshots --json --no-lock --latest 1")
                if (target.filter.isNotBlank()) append(" --host ${q(target.filter)}")
            }
            Tool.BORG -> {
                append("[ -n \"\$p\" ] && export BORG_PASSPHRASE=\"\$p\"; ")
                // UTC times in the listing; a moved or unknown repository fails rather than asks.
                append("TZ=UTC0 BORG_EXIT_CODES=modern BORG_RELOCATED_REPO_ACCESS_IS_OK=no BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes ")
                append("ot $TIMEOUT_SEC borg list --json --last 1 --bypass-lock")
                if (target.filter.isNotBlank()) append(" -a ${q(target.filter)}")
                if (target.repository.isNotBlank()) append(" ${q(target.repository)}")
            }
            Tool.PBS -> {
                append("[ -n \"\$p\" ] && export PBS_PASSWORD=\"\$p\"; ")
                if (target.fingerprint.isNotBlank()) append("export PBS_FINGERPRINT=${q(target.fingerprint)}; ")
                append("ot $TIMEOUT_SEC proxmox-backup-client snapshot list")
                if (target.filter.isNotBlank()) append(" ${q(target.filter)}")
                if (target.repository.isNotBlank()) append(" --repository ${q(target.repository)}")
                append(" --output-format json")
            }
            Tool.VZDUMP -> Unit
        }
        append(" </dev/null 2>\"\$e\"; c=\$?; echo; echo \"!RC \$c\"; echo '@ERR'; tail -c 2000 \"\$e\" 2>/dev/null; rm -f \"\$e\"")
    }

    /**
     * vzdump's own file names carry the time a dump started, in the host's time zone, as Proxmox
     * reads them; the newest dump file (not its log or notes) is converted on the host, so its time
     * zone and daylight saving are the host's.
     */
    private fun vzdumpListing(target: Target): String {
        val dir = q(target.repository)
        // Only digits reach the pattern; anything else matches no guest (problem() refuses it).
        val id = target.filter.trim().let { f -> if (f.isEmpty()) "[0-9]+" else f.takeIf { it.all(Char::isDigit) } ?: "x" }
        return "if [ ! -d $dir ]; then echo '!MISSING'; exit 0; fi; " +
            "n=\$(ls -1 $dir 2>/dev/null | grep -E '^vzdump-(qemu|lxc|openvz)-$id-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\\.' " +
            "| grep -vE '\\.(log|notes)\$' | awk -F- '{print \$4\"-\"\$5\" \"\$0}' | sort | tail -n 1 | cut -d' ' -f2); " +
            "[ -n \"\$n\" ] || exit 0; " +
            "t=\$(printf '%s' \"\$n\" | sed -E 's/^vzdump-[a-z]+-[0-9]+-([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2}).*/\\1-\\2-\\3 \\4:\\5:\\6/'); " +
            "s=\$(date -d \"\$t\" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' \"\$t\" +%s 2>/dev/null); " +
            "printf '!AT %s %s\\n' \"\$s\" \"\$n\""
    }

    /** One reading: hours since the newest backup or a code below 0, and what it was (a snapshot, an error line). */
    data class Outcome(val value: Float?, val detail: String)

    /**
     * The reading from what the SSH transport returned for [command]. Null when the command never
     * ran (no connection), which says nothing about the backups. A null [Outcome.value] is
     * unknown: the repository was busy, or the listing timed out.
     */
    fun parse(target: Target, raw: String, nowEpochSec: Long): Outcome? {
        if (raw.startsWith("SSH Error") && !raw.startsWith("SSH Error: command failed")) return null
        val sections = RemoteParsers.splitSections(raw)
        val body = sections["BACKUP"] ?: return null
        val lines = body.lines().map { it.trim() }
        if ("!SETTINGS" in lines) return Outcome(FAILED, "Cannot read ${target.settingsFile}")
        if ("!TOOL" in lines) return Outcome(TOOL_MISSING, "${target.tool.binary} is not installed")
        if (target.tool == Tool.VZDUMP) {
            if ("!MISSING" in lines) return Outcome(REPO_MISSING, "No folder ${target.repository}")
            val at = lines.firstOrNull { it.startsWith("!AT ") } ?: return Outcome(NO_BACKUPS, "No vzdump files")
            val parts = at.removePrefix("!AT ").trim().split(' ', limit = 2)
            val epoch = parts.getOrNull(0)?.toLongOrNull() ?: return Outcome(FAILED, "The host could not read the dump's time")
            return Outcome(hoursSince(epoch, nowEpochSec), parts.getOrNull(1).orEmpty())
        }
        val rc = lines.lastOrNull { it.startsWith("!RC ") }?.removePrefix("!RC ")?.trim()?.toIntOrNull()
            ?: return Outcome(FAILED, "The check did not finish")
        val json = lines.filterNot { it.startsWith("!RC ") }.joinToString("\n").trim()
        val err = errorLine(target.tool, sections["ERR"].orEmpty())
        // timeout(1) ends a listing with 124, or 143 when it had to send SIGTERM.
        if (rc == 124 || rc == 143) return Outcome(null, "The listing did not finish within $TIMEOUT_SEC seconds")
        return when (target.tool) {
            Tool.RESTIC -> restic(rc, json, err, nowEpochSec)
            Tool.BORG -> borg(rc, json, err, nowEpochSec)
            Tool.PBS -> pbs(rc, json, err, nowEpochSec)
            Tool.VZDUMP -> null
        }
    }

    private fun restic(rc: Int, json: String, err: String, now: Long): Outcome {
        // restic 0.17+: 10 no repository, 11 locked, 12 wrong password; older ones exit 1 with the reason.
        val e = err.lowercase(Locale.ROOT)
        return when {
            rc == 10 || (rc != 0 && ("repository does not exist" in e || "unable to open config file" in e || "is there a repository" in e)) ->
                Outcome(REPO_MISSING, err)
            rc == 12 || (rc != 0 && ("wrong password" in e || "empty password" in e || "no password" in e)) -> Outcome(AUTH_FAILED, err)
            rc == 11 || (rc != 0 && ("unable to create lock" in e || "repository is already locked" in e)) ->
                Outcome(null, err.ifBlank { "The repository is locked" })
            rc != 0 -> Outcome(FAILED, err.ifBlank { "restic exited with $rc" })
            else -> newest(
                list(json)?.mapNotNull { item ->
                    val snapshot = item as? Map<*, *> ?: return@mapNotNull null
                    val at = (snapshot["time"] as? String)?.let(::epochOf) ?: return@mapNotNull null
                    at to "snapshot ${snapshot["short_id"] ?: snapshot["id"]?.toString()?.take(8) ?: ""}".trim()
                },
                now,
                "restic printed no snapshot list",
            )
        }
    }

    private fun borg(rc: Int, json: String, err: String, now: Long): Outcome {
        // Borg 1.4 with BORG_EXIT_CODES=modern: 13 no repository, 15 not a repository, 52 wrong
        // passphrase; 1.2 exits 2 with the reason. 1 is a warning with a listing.
        val e = err.lowercase(Locale.ROOT)
        return when {
            rc == 13 || rc == 15 || (rc >= 2 && ("does not exist" in e || "is not a valid repository" in e)) -> Outcome(REPO_MISSING, err)
            rc == 52 || (rc >= 2 && "passphrase" in e) -> Outcome(AUTH_FAILED, err)
            rc >= 2 && ("failed to create/acquire the lock" in e || "lock timeout" in e) -> Outcome(null, err)
            rc >= 2 -> Outcome(FAILED, err.ifBlank { "borg exited with $rc" })
            else -> {
                val root = parseJson(json) as? Map<*, *> ?: return Outcome(FAILED, err.ifBlank { "borg printed no archive list" })
                val archives = root["archives"] as? List<*>
                newest(
                    archives?.mapNotNull { item ->
                        val archive = item as? Map<*, *> ?: return@mapNotNull null
                        // TZ=UTC0 above makes these UTC; they carry no offset of their own.
                        val at = (archive["time"] as? String ?: archive["start"] as? String)?.let { epochOf(it, assumeUtc = true) }
                            ?: return@mapNotNull null
                        at to "archive ${archive["name"] ?: archive["archive"] ?: ""}".trim()
                    },
                    now,
                    "borg printed no archive list",
                )
            }
        }
    }

    private fun pbs(rc: Int, json: String, err: String, now: Long): Outcome {
        val e = err.lowercase(Locale.ROOT)
        return when {
            rc != 0 && ("authentication failed" in e || "permission check failed" in e || "401" in e || "no password" in e || "password is required" in e) ->
                Outcome(AUTH_FAILED, err)
            rc != 0 && ("fingerprint" in e) -> Outcome(FAILED, "The server's certificate is not trusted: add its fingerprint to the rule")
            rc != 0 && ("does not exist" in e || "no such datastore" in e || "not found" in e || "unable to get (default) repository" in e) ->
                Outcome(REPO_MISSING, err)
            rc != 0 -> Outcome(FAILED, err.ifBlank { "proxmox-backup-client exited with $rc" })
            else -> newest(
                list(json)?.mapNotNull { item ->
                    val snapshot = item as? Map<*, *> ?: return@mapNotNull null
                    val at = (snapshot["backup-time"] as? Number)?.toLong() ?: return@mapNotNull null
                    at to "${snapshot["backup-type"] ?: ""}/${snapshot["backup-id"] ?: ""}".trim('/')
                },
                now,
                "proxmox-backup-client printed no snapshot list",
            )
        }
    }

    private fun newest(found: List<Pair<Long, String>>?, now: Long, unreadable: String): Outcome {
        found ?: return Outcome(FAILED, unreadable)
        val latest = found.maxByOrNull { it.first } ?: return Outcome(NO_BACKUPS, "No backups yet")
        return Outcome(hoursSince(latest.first, now), latest.second)
    }

    private fun hoursSince(epochSec: Long, nowEpochSec: Long): Float = (nowEpochSec - epochSec).coerceAtLeast(0) / 3600f

    /** The error worth showing: restic's JSON message, else the last line that says something. */
    private fun errorLine(tool: Tool, err: String): String {
        val text = err.trim()
        if (text.isEmpty()) return ""
        if (tool == Tool.RESTIC) {
            text.lines().asReversed().firstNotNullOfOrNull { line ->
                (parseJson(line.trim()) as? Map<*, *>)?.get("message") as? String
            }?.let { return clip(it.lineSequence().first().trim()) }
        }
        val line = text.lines().map { it.trim() }.lastOrNull { it.isNotEmpty() && !it.startsWith("{") } ?: return ""
        return clip(line.removePrefix("Error: ").removePrefix("error: "))
    }

    private fun clip(s: String) = if (s.length > 160) s.take(159) + "…" else s

    private val json = Moshi.Builder().build().adapter(Any::class.java).lenient()

    private fun parseJson(text: String): Any? = if (text.isBlank()) null else runCatching { json.fromJson(text) }.getOrNull()

    private fun list(text: String): List<*>? = parseJson(text) as? List<*>

    /**
     * An RFC 3339 time (restic's, with its offset), or one without an offset (Borg's), taken as
     * UTC when [assumeUtc]. Parsed by hand: java.time needs Android 8.0.
     */
    internal fun epochOf(text: String, assumeUtc: Boolean = false): Long? {
        val m = ISO_TIME.matchEntire(text.trim()) ?: return null
        val (y, mo, d, h, mi, s) = m.destructured
        val zone = m.groupValues[8]
        val offsetSec = when {
            zone.isEmpty() -> if (assumeUtc) 0 else return null
            zone == "Z" || zone == "z" -> 0
            else -> {
                val digits = zone.substring(1).replace(":", "")
                val sign = if (zone[0] == '-') -1 else 1
                sign * (digits.take(2).toInt() * 3600 + digits.drop(2).toInt() * 60)
            }
        }
        val days = daysFromCivil(y.toInt(), mo.toInt(), d.toInt())
        return days * 86_400L + h.toInt() * 3600 + mi.toInt() * 60 + s.toInt() - offsetSec
    }

    private val ISO_TIME = Regex("""^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|z|[+-]\d{2}:?\d{2})?$""")

    /** Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil). */
    private fun daysFromCivil(year: Int, month: Int, day: Int): Long {
        val y = (if (month <= 2) year - 1 else year).toLong()
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (if (month > 2) month - 3 else month + 9) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    fun breached(value: Float, thresholdHours: Float): Boolean = value < 0f || value > thresholdHours

    /** An age as people say it: hours up to two days, then days. */
    fun age(hours: Float): String {
        val h = hours.roundToInt()
        return if (h < 48) "$h h" else "${(hours / 24f).roundToInt()} days"
    }

    /** A reading as the rule list and history show it. */
    fun describe(value: Float): String = when {
        value == NO_BACKUPS -> "no backups"
        value == TOOL_MISSING -> "tool not installed"
        value == REPO_MISSING -> "repository not found"
        value == AUTH_FAILED -> "wrong password"
        value < 0f -> "check failed"
        else -> age(value) + " old"
    }

    /** The last reading as the rule list shows it: the age and which backup, or the error. */
    fun summary(value: Float, detail: String): String = when {
        value >= 0f -> "Newest backup ${age(value)} old" + if (detail.isNotBlank()) " ($detail)" else ""
        detail.isNotBlank() -> describe(value).replaceFirstChar { it.uppercase(Locale.ROOT) } + ": $detail"
        else -> describe(value).replaceFirstChar { it.uppercase(Locale.ROOT) }
    }

    /** The notification line for an alert. */
    fun alertText(target: Target?, value: Float, thresholdHours: Float, detail: String): String {
        val tool = target?.tool?.label ?: "backup"
        val where = target?.repository?.takeIf { it.isNotBlank() }?.let { " $it" } ?: target?.settingsFile?.let { " from $it" }.orEmpty()
        return when {
            value >= 0f -> "Newest $tool backup is ${age(value)} old (limit ${age(thresholdHours)})" + if (detail.isNotBlank()) ": $detail" else ""
            value == NO_BACKUPS -> "No $tool backups in$where"
            value == TOOL_MISSING -> "${target?.tool?.binary ?: "The backup tool"} is not installed on this host"
            value == REPO_MISSING -> "$tool repository not found:$where" + if (detail.isNotBlank() && target?.tool != Tool.VZDUMP) " ($detail)" else ""
            value == AUTH_FAILED -> "$tool refused the password for$where"
            else -> "$tool check failed" + if (detail.isNotBlank()) ": $detail" else ""
        }
    }
}
