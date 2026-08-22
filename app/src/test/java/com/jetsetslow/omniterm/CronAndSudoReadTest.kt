package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Two reads that used to lose information silently: a crontab that could not be read, and a
 * sudo-elevated file read that carried sudo's own output into the file.
 *
 * Both were found while reimplementing this code in Dart -- neither crashes, neither logs, and in
 * both cases the screen looks like it is working.
 */
class CronAndSudoReadTest {

    private val marker = RemoteCommands.CRON_EXIT_MARKER

    @Test
    fun `a crontab that was read comes back intact`() {
        val read = RemoteParsers.parseCrontabRead("0 2 * * * /bin/true\n${marker}0\n")

        assertTrue(read.readable)
        assertEquals("0 2 * * * /bin/true", read.text)
    }

    @Test
    fun `no crontab for this user is empty, not a failure`() {
        // Every implementation prints this on stderr and exits non-zero. Treating it as a failure
        // would leave a first-time user unable to add their first entry.
        val read = RemoteParsers.parseCrontabRead("no crontab for omniterm\n${marker}1\n")

        assertTrue(read.readable)
        assertEquals("", read.text)
    }

    @Test
    fun `a refusal is not an empty crontab`() {
        // The defect: `crontab -l 2>/dev/null || true` returned "" here, the CRON tab then offered
        // Add, and a save rewrites the whole file -- so a crontab the user was never allowed to
        // read would be replaced by a single line.
        val read = RemoteParsers.parseCrontabRead(
            "You (omniterm) are not allowed to use this program\n${marker}1\n",
        )

        assertFalse(read.readable)
        assertTrue(read.error.contains("not allowed"))
    }

    @Test
    fun `a host with no cron at all is reported rather than treated as empty`() {
        val read = RemoteParsers.parseCrontabRead("sh: crontab: not found\n${marker}127\n")

        assertFalse(read.readable)
        assertTrue(read.error.contains("not found"))
    }

    @Test
    fun `a truncated reply is a failure, because it is not an answer`() {
        assertFalse(RemoteParsers.parseCrontabRead("").readable)
        assertFalse(RemoteParsers.parseCrontabRead("0 2 * * * /bin/true\n").readable)
    }

    @Test
    fun `the read command keeps stderr and the exit status`() {
        assertTrue(RemoteCommands.CRON_READ_COMMAND.contains("2>&1"))
        assertTrue(RemoteCommands.CRON_READ_COMMAND.contains(marker))
        assertFalse(
            "the point of the fix is that stderr is no longer discarded",
            RemoteCommands.CRON_READ_COMMAND.contains("2>/dev/null"),
        )
    }

    // ── sudo reads ──────────────────────────────────────────────────────────────

    /** Real output shape: sudo prints this to stderr on its first use in a session. */
    private val lecture =
        "\nWe trust you have received the usual lecture from the local System\n" +
            "Administrator. It usually boils down to these three things:\n\n" +
            "    #1) Respect the privacy of others.\n" +
            "    #2) Think before you type.\n\n"

    @Test
    fun `the marker separates sudo's chatter from the file`() {
        // Without it the lecture is prepended to the file, shown in the editor, and written back on
        // save -- corrupting a root-owned config the user opened to read.
        val output = lecture + RemoteCommands.SUDO_OUTPUT_MARKER + "\nlisten 8080\nmode strict\n"

        assertEquals("listen 8080\nmode strict\n", RemoteParsers.parseSudoRead(output))
    }

    @Test
    fun `an empty file is not confused with a refusal`() {
        // Empty content and "sudo said no" have to stay distinguishable, or an unreadable file
        // opens as blank and saving it truncates the original.
        assertEquals("", RemoteParsers.parseSudoRead(RemoteCommands.SUDO_OUTPUT_MARKER + "\n"))
        assertNull(RemoteParsers.parseSudoRead("sudo: a password is required\n"))
        assertNull(RemoteParsers.parseSudoRead(""))
    }

    @Test
    fun `the file keeps its own leading blank lines`() {
        val output = RemoteCommands.SUDO_OUTPUT_MARKER + "\n\n\n# comment\n"
        assertEquals("\n\n# comment\n", RemoteParsers.parseSudoRead(output))
    }

    @Test
    fun `the read command quotes the path`() {
        val command = RemoteCommands.sudoReadCommand("/etc/; rm -rf ~", "pw")

        assertTrue(command.contains("sudo -S"))
        assertFalse("a path is not this app's text", command.contains("cat -- /etc/; rm"))
    }
}
