package com.jetsetslow.omniterm.data

/**
 * A [HostChecks.SCRIPT_CHECK] rule: a saved script run on the host at most once a minute, whose
 * exit status is the reading. 0 passes; anything else is a failure, named with the first line the
 * script printed. The rule's `target` holds the script's id.
 *
 * Only a script that reads can be a check: it runs again and again without anyone confirming it,
 * so one the danger list flags (see `commandDangerHits`) is refused, and so is one with a
 * `{{value}}` that has no default, since nobody is there to type it.
 *
 * Credit: script checks were among the alert kinds the Nov 8 review of Uptime Kuma and Beszel
 * found missing (see the README's acknowledgements).
 */
object ScriptChecks {
    /** A check that has not finished by then counts as failed, with timeout(1)'s status. */
    const val TIMEOUT_MS = 60_000L
    const val TIMED_OUT = 124f

    /** The id of the script [rule] runs, or null when it names none. */
    fun scriptId(rule: AlertRuleEntity): Int? = rule.target.trim().toIntOrNull()?.takeIf { it > 0 }

    /** Why [script] cannot be a check, or null when it can. [dangerHits] are what the danger list found in it. */
    fun problem(script: QuickScriptEntity?, dangerHits: List<String>): String? =
        UnattendedScripts.problem(script, dangerHits, UnattendedScripts.Runner.CHECK)

    /**
     * The reading from what the SSH transport returned for one run: the exit status and the first
     * line of output. Null when the script never ran (no connection, sign-in failed), which says
     * nothing about the check, so an open incident stays as it is.
     */
    fun outcome(result: String): Pair<Float, String>? {
        val failed = FAILED.find(result)
        return when {
            failed != null -> failed.groupValues[1].toFloat() to firstLine(result.substring(failed.range.last + 1))
            result.startsWith("SSH Error") -> null
            else -> 0f to firstLine(result)
        }
    }

    private val FAILED = Regex("""^SSH Error: command failed \((\d+)\): ?""")

    /** The first line worth showing, at most 160 characters; not the transport's own "exited with status" filler. */
    private fun firstLine(output: String): String =
        output.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
            ?.takeUnless { it.startsWith("Command exited with status ") }
            ?.let { if (it.length > 160) it.take(159) + "…" else it }
            .orEmpty()
}
