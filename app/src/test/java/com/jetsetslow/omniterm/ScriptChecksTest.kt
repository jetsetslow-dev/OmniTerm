package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ScriptChecks
import com.jetsetslow.omniterm.ui.commandDangerHits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScriptChecksTest {
    private fun script(command: String) = QuickScriptEntity(id = 7, emoji = "LIN", name = "Backups fresh", command = command, color = "cyan", longRunning = false)

    private fun problem(command: String) = script(command).let { ScriptChecks.problem(it, commandDangerHits(it.command)) }

    @Test
    fun theExitStatusIsTheReadingAndTheFirstLineSaysWhy() {
        assertEquals(0f to "all 3 backups are fresh", ScriptChecks.outcome("\n  all 3 backups are fresh\nchecked /srv\n"))
        assertEquals(2f to "nas is 3 days old", ScriptChecks.outcome("SSH Error: command failed (2): nas is 3 days old\nmore"))
        // The transport's own filler when the script printed nothing is not a reason.
        assertEquals(1f to "", ScriptChecks.outcome("SSH Error: command failed (1): Command exited with status 1"))
        assertEquals(0f to "", ScriptChecks.outcome(""))
        val long = "x".repeat(400)
        assertEquals(160, ScriptChecks.outcome(long)!!.second.length)
    }

    @Test
    fun aScriptThatNeverRanSaysNothing() {
        assertNull(ScriptChecks.outcome("SSH Error: connect timed out"))
        assertNull(ScriptChecks.outcome("SSH Error: Auth fail"))
        assertNull(ScriptChecks.outcome("SSH Error: command timed out"))
    }

    @Test
    fun onlyAScriptThatReadsAndNeedsNoAnswersCanBeACheck() {
        assertNull(problem("test \"\$(find /srv/backup -mtime -1 | wc -l)\" -gt 0"))
        assertNull(problem("df -h {{mount=/}}"))
        assertEquals("Pick a saved script", ScriptChecks.problem(null, emptyList()))
        assertEquals("That script has no command", problem("  "))
        assertTrue(problem("rm -rf /srv/backup/old")!!.contains("looks destructive (recursive/forced delete)"))
        assertTrue(problem("du -sh {{path}}")!!.contains("a check has nobody to ask"))
    }

    @Test
    fun aRuleNamesItsScriptById() {
        val rule = AlertRuleEntity(serverId = 1, metricName = HostChecks.SCRIPT_CHECK, thresholdValue = 0f, severity = "WARNING")
        assertEquals(7, ScriptChecks.scriptId(rule.copy(target = " 7 ")))
        assertNull(ScriptChecks.scriptId(rule))
        assertNull(ScriptChecks.scriptId(rule.copy(target = "0")))
        assertNull(ScriptChecks.scriptId(rule.copy(target = "backup.sh")))
    }

    @Test
    fun aScriptCheckRunsItsOwnScriptAndAlertsOnAnyFailure() {
        assertTrue(HostChecks.runsOnHost(HostChecks.SCRIPT_CHECK))
        assertFalse(HostChecks.needsProbe(HostChecks.SCRIPT_CHECK))
        assertFalse(HostChecks.runsOnHost(HostChecks.HOST_OFFLINE))
        assertTrue(HostChecks.isYesNo(HostChecks.SCRIPT_CHECK))
        assertEquals(0f, HostChecks.defaultThreshold(HostChecks.SCRIPT_CHECK))
        assertEquals("2m", HostChecks.defaultWindow(HostChecks.SCRIPT_CHECK))

        val names = listOf("Backups fresh", "nas is 3 days old")
        assertEquals("Backups fresh failed (exit 2): nas is 3 days old", HostChecks.alertText(HostChecks.SCRIPT_CHECK, 2f, 0f, names))
        assertEquals("Backups fresh failed (exit 2)", HostChecks.alertText(HostChecks.SCRIPT_CHECK, 2f, 0f, listOf("Backups fresh", "")))
        // Re-posted after a mute, without the names.
        assertEquals("The check script failed (exit 2)", HostChecks.alertText(HostChecks.SCRIPT_CHECK, 2f, 0f, emptyList()))
        assertEquals("exit 2: nas is 3 days old", HostChecks.summary(HostChecks.SCRIPT_CHECK, 2f, names))
        assertEquals("passed", HostChecks.summary(HostChecks.SCRIPT_CHECK, 0f, listOf("Backups fresh", "")))
        assertEquals("passed: all fresh", HostChecks.summary(HostChecks.SCRIPT_CHECK, 0f, listOf("Backups fresh", "all fresh")))
    }
}
