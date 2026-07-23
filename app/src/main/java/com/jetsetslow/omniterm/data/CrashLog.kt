package com.jetsetslow.omniterm.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * On-device crash history. The global uncaught-exception handler appends every crash here so users
 * can review past crashes from About → Crash history and send them to GitHub long after the fact —
 * not only when the app happens to crash again at startup.
 *
 * Stored as a small JSON array in private SharedPreferences (no network, no third party). Capped at
 * [MAX_ENTRIES] newest-first so it can never grow unbounded, and entries older than [TTL_MS] are
 * dropped on read. Release stack traces are obfuscated; each report is prefixed with the build
 * version/device so it can be matched to the right `mapping.txt` for deobfuscation.
 */
object CrashLog {
    private const val PREFS = "crash_history"
    private const val KEY = "entries"
    private const val MAX_ENTRIES = 20
    private const val TTL_MS = 30L * 24 * 60 * 60 * 1000 // 30 days

    data class Entry(val timeMs: Long, val report: String) {
        /** First non-blank line that isn't an environment/thread/frame line — the exception itself. */
        val headline: String
            get() = report.lineSequence()
                .map { it.trim() }
                .firstOrNull { it.isNotEmpty() && !it.startsWith("at ") && !it.startsWith("App version") && !it.startsWith("Device:") && !it.startsWith("ABI:") && !it.startsWith("Thread:") }
                ?.take(200)
                ?: "Crash"
    }

    // record() runs on the crashing thread (any thread) while merge()/all() run on IO/main. They all
    // read-modify-write the same prefs key, so guard every mutation to avoid lost updates.
    private val lock = Any()

    fun record(context: Context, report: String) = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val entries = read(prefs).toMutableList()
        entries.add(0, Entry(System.currentTimeMillis(), redactSensitive(report)))
        // commit (not apply): the process is usually dying right after a crash, so the write must
        // flush synchronously or the very crash we're recording could be lost.
        write(prefs, entries.take(MAX_ENTRIES), durable = true)
    }

    fun all(context: Context): List<Entry> = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val stored = read(prefs)
        val fresh = stored.filter { now - it.timeMs < TTL_MS }
        // Persist the pruned list so stale entries don't linger after the first read past TTL.
        if (fresh.size != stored.size) write(prefs, fresh)
        fresh
    }

    fun clear(context: Context) = synchronized(lock) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY).apply()
    }

    /**
     * Merge [incoming] crash entries (e.g. from a restored backup) into the on-device history,
     * deduplicating by timestamp so re-importing the same backup doesn't pile up duplicates.
     *
     * On-device logs are NEVER evicted by a restore: existing entries are always kept, and restored
     * entries only fill the slots remaining up to [MAX_ENTRIES] (newest restored first). So if the
     * device is already at the cap, a restore adds nothing rather than discarding local history.
     *
     * Returns how many restored entries were actually added (i.e. fit within the remaining slots).
     */
    fun merge(context: Context, incoming: List<Entry>): Int = synchronized(lock) {
        if (incoming.isEmpty()) return@synchronized 0
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = read(prefs)
        val existingTimes = existing.mapTo(HashSet()) { it.timeMs }
        val freeSlots = (MAX_ENTRIES - existing.size).coerceAtLeast(0)
        if (freeSlots == 0) return@synchronized 0
        val toAdd = incoming
            .filter { it.timeMs !in existingTimes && it.report.isNotBlank() }
            .sortedByDescending { it.timeMs }
            .take(freeSlots)
        if (toAdd.isEmpty()) return@synchronized 0
        // Keep the whole list newest-first for display; existing entries are all retained.
        val combined = (existing + toAdd).sortedByDescending { it.timeMs }
        write(prefs, combined)
        toAdd.size
    }

    /** Replace the crash-history snapshot when compensating a failed backup restore. */
    fun replace(context: Context, entries: List<Entry>) = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        write(prefs, entries.take(MAX_ENTRIES), durable = true)
    }

    private const val ISSUES_URL = "https://github.com/jetsetslow-dev/OmniTerm/issues/new"

    /**
     * Open a prefilled GitHub "new issue" form for [report]. Nothing is submitted automatically — the
     * user lands on GitHub's editor and can review/redact before posting. GitHub's URL form can't
     * carry attachments, so the body keeps a short headline; the full trace goes via [shareReport].
     * Returns false if no app can open the link (caller can fall back to copying).
     */
    fun openGitHubIssue(context: Context, report: String): Boolean {
        val headline = report.lineSequence().firstOrNull { it.isNotBlank() }?.take(160).orEmpty()
        val body = buildString {
            append("**Describe what you were doing when this happened:**\n\n\n")
            append("---\n")
            append("Crash:\n```\n").append(headline).append("\n```\n\n")
            append("_Attach the full report via \"Share\" on the crash history screen._\n")
        }
        val uri = Uri.parse(ISSUES_URL).buildUpon()
            .appendQueryParameter("title", "Crash: ${headline.take(120)}")
            .appendQueryParameter("body", body)
            .build()
        val intent = Intent(Intent.ACTION_VIEW, uri)
        return if (intent.resolveActivity(context.packageManager) != null) {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
        } else false
    }

    /**
     * Write [report] to a private cache file and open the Android share sheet with it attached, so
     * the complete trace can go to a GitHub issue, email, or Drive without truncation. The user picks
     * the destination — nothing is sent automatically. Exposed only through the app's FileProvider.
     */
    fun shareReport(context: Context, report: String) {
        // Defense in depth: callers normally pass an already-sanitized stored report, but this is
        // the final clipboard/file/IPC boundary and must never trust that invariant.
        val full = sharePayload(report)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "OmniTerm crash report")
            // Always include the FULL report as text: many share targets show/keep EXTRA_TEXT and
            // drop the attached file, so without this they'd receive an empty body. The file
            // attachment (below) is added best-effort for targets that prefer attachments.
            putExtra(Intent.EXTRA_TEXT, full)
        }
        runCatching {
            val dir = File(context.cacheDir, "crash-reports").apply { mkdirs() }
            val file = File(dir, "omniterm-crash-report.txt")
            file.writeText(full)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            send.putExtra(Intent.EXTRA_STREAM, uri)
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(
            Intent.createChooser(send, "Share crash report").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    internal fun sharePayload(report: String): String =
        "OmniTerm crash report\n\n${redactSensitive(report)}"

    fun formatThrowable(t: Throwable): String {
        val writer = StringWriter()
        t.printStackTrace(PrintWriter(writer))
        return writer.toString()
    }

    /** Sanitize reports before persistence, display, clipboard, backup, or share boundaries. */
    fun redactSensitive(report: String): String {
        var safe = report
        safe = safe.replace(
            Regex("-----BEGIN [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----[\\s\\S]*?-----END [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----", RegexOption.IGNORE_CASE),
            "<redacted-private-key>",
        )
        safe = safe.replace(
            Regex("(?i)(\\b(?:authorization|proxy-authorization)\\s*[:=]\\s*)(?:bearer|basic)?\\s*\\S+"),
            "$1<redacted>",
        )
        safe = safe.replace(
            Regex("(?i)(\\b(?:password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key)\\b\\s*[:=]\\s*)([^\\s,;]+)"),
            "$1<redacted>",
        )
        safe = safe.replace(Regex("(?i)([a-z][a-z0-9+.-]*://)[^/@\\s:]+(?::[^/@\\s]*)?@"), "$1<redacted>@")
        safe = safe.replace(Regex("(?<![A-Za-z0-9_])(?:\\d{1,3}\\.){3}\\d{1,3}(?![A-Za-z0-9_])"), "<redacted-ip>")
        safe = safe.replace(Regex("/(?:home|Users)/[^/\\s]+"), "/home/<redacted>")
        safe = safe.replace(Regex("/data/(?:user/\\d+|data)/[^/\\s]+"), "/data/user/<redacted>")
        return safe
    }

    private fun read(prefs: android.content.SharedPreferences): List<Entry> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                Entry(o.optLong("t"), o.optString("r"))
            }
        }.getOrDefault(emptyList())
    }

    @android.annotation.SuppressLint("ApplySharedPref") // durable crash-path writes must finish before process death
    private fun write(prefs: android.content.SharedPreferences, entries: List<Entry>, durable: Boolean = false) {
        val arr = JSONArray()
        entries.forEach { arr.put(JSONObject().put("t", it.timeMs).put("r", it.report)) }
        val editor = prefs.edit().putString(KEY, arr.toString())
        if (durable) editor.commit() else editor.apply()
    }
}
