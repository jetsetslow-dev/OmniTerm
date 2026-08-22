package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `inferLevel` classifies every journald line shown in Monitor → Logs and in Fleet broadcast output.
 *
 * Its patterns are word *stems*, and a trailing `\b` disabled all of them: `fail` could not match
 * "failure", `error` could not match "errors", and `deprecat` could only ever match the literal
 * string "deprecat". Real errors were rendered as ordinary INFO lines — exactly backwards for
 * triage, and invisible unless you read the regex.
 *
 * `inferLevel` is private, so these go through `parseJournal`, which is how the app reaches it.
 */
class LogSeverityStemsTest {

    private fun levelOf(message: String): String {
        val line = "Aug 04 10:00:00 host unit[1]: $message"
        val logs = RemoteParsers.parseJournal(line)
        assertEquals("expected exactly one parsed line for: $message", 1, logs.size)
        return logs[0].level
    }

    @Test
    fun inflectedErrorStemsAreErrors() {
        // Every one of these was INFO before the fix.
        assertEquals("ERROR", levelOf("connection failure"))
        assertEquals("ERROR", levelOf("disk errors detected"))
        assertEquals("ERROR", levelOf("task is failing"))
        assertEquals("ERROR", levelOf("segfaulted while starting"))
        assertEquals("ERROR", levelOf("request was denied repeatedly"))
    }

    @Test
    fun exactErrorWordsStillMatch() {
        assertEquals("ERROR", levelOf("error opening socket"))
        assertEquals("ERROR", levelOf("fatal: cannot continue"))
        assertEquals("ERROR", levelOf("connection refused"))
    }

    @Test
    fun inflectedWarnStemsAreWarnings() {
        assertEquals("WARN", levelOf("deprecated option in use"))
        assertEquals("WARN", levelOf("deprecation notice"))
        assertEquals("WARN", levelOf("warned twice"))
        assertEquals("WARN", levelOf("retrying now"))
        assertEquals("WARN", levelOf("timeouts observed"))
    }

    @Test
    fun exactWarnWordsStillMatch() {
        assertEquals("WARN", levelOf("warning: low disk"))
        assertEquals("WARN", levelOf("timeout waiting for lock"))
    }

    @Test
    fun errorOutranksWarn() {
        assertEquals("ERROR", levelOf("warning: connection failure"))
    }

    @Test
    fun stemsStillCannotMatchMidWord() {
        // The leading \b is deliberately kept. Without it "shutdown" contains "down"-adjacent
        // noise and, more to the point, any word ending in a stem would be miscounted as an error.
        assertEquals("INFO", levelOf("shutdown complete"))
        assertEquals("INFO", levelOf("prefailover check ok"))
        assertEquals("INFO", levelOf("nonerror path taken"))
    }

    @Test
    fun ordinaryLinesStayInfo() {
        assertEquals("INFO", levelOf("started nginx"))
        assertEquals("INFO", levelOf("listening on port 443"))
    }
}
