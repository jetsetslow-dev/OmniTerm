package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.PIN_LOCKOUT_MS
import com.jetsetslow.omniterm.ui.PIN_MAX_ATTEMPTS
import com.jetsetslow.omniterm.ui.decodeBackupSelection
import com.jetsetslow.omniterm.ui.hasSensitiveData
import com.jetsetslow.omniterm.ui.isPinThrottled
import com.jetsetslow.omniterm.ui.pinLockoutAfterFailure
import com.jetsetslow.omniterm.ui.verifyStoredPin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM security regression tests. PIN *hashing* (android.util.Base64) lives in
 * [PinHashRobolectricTest], which is excluded on Linux aarch64 hosts like the other
 * Robolectric classes and runs in CI.
 */
class SecuritySafeguardsTest {

    // ── No sudo password in generated command strings ──

    private val password = "s3cret&pw 'quoted'"

    @Test
    fun sudo_password_never_appears_in_command_strings() {
        val commands = listOf(
            RemoteCommands.sudoWrap("reboot", password),
            RemoteCommands.sudoShWrap("cp -f -- /tmp/a /etc/b && rm -f /tmp/a", password),
            RemoteCommands.serviceAction("nginx", "restart", password),
            RemoteCommands.reboot(password),
        )
        for (cmd in commands) {
            assertFalse("password must not be embedded: $cmd", cmd.contains(password))
            assertFalse("no printf-pipe delivery: $cmd", cmd.contains("printf"))
            assertTrue("sudo -S reads from channel stdin: $cmd", cmd.contains("sudo -S -p ''"))
        }
    }

    @Test
    fun sudo_stdin_carries_the_password_with_trailing_newline() {
        assertEquals(password + "\n", RemoteCommands.sudoStdin(password))
        assertEquals(null, RemoteCommands.sudoStdin(""))
        assertEquals(null, RemoteCommands.sudoStdin("   "))
    }

    @Test
    fun blank_password_falls_back_to_non_interactive_sudo() {
        assertTrue(RemoteCommands.sudoWrap("reboot", "").startsWith("sudo -n "))
        assertTrue(RemoteCommands.sudoShWrap("ls", "").startsWith("sudo -n sh -c "))
    }

    @Test
    fun tmux_attach_sanitizes_name_and_sets_history_limit() {
        val cmd = RemoteCommands.tmuxAttachCommand("omniterm-1;rm -rf /", 123_456)

        assertTrue(cmd.contains("tmux has-session -t omniterm-1rm-rf"))
        assertTrue(cmd.contains("history-limit 50000"))
        assertTrue(cmd.contains("exec tmux attach-session -t omniterm-1rm-rf"))
        assertFalse(cmd.contains(";rm -rf"))
    }

    // ── Backup sensitivity classification ──

    private val emptySelection = BackupSelection(
        servers = false, sshKeys = false, credentialProfiles = false, scripts = false,
        alertRules = false, activeAlerts = false, alertHistory = false, wolTargets = false,
        settings = false,
    )

    @Test
    fun default_backup_selection_is_sensitive() {
        assertTrue(BackupSelection().hasSensitiveData())
    }

    @Test
    fun truly_empty_selection_is_not_sensitive() {
        assertFalse(emptySelection.hasSensitiveData())
    }

    @Test
    fun every_individual_section_counts_as_sensitive() {
        // Scripts, jobs, settings, alerts and WoL targets can all carry hostnames, tokens or
        // commands — each one alone must force encryption, not just keys/credentials.
        val variants = listOf<Pair<String, BackupSelection>>(
            "servers" to emptySelection.copy(servers = true),
            "sshKeys" to emptySelection.copy(sshKeys = true),
            "credentialProfiles" to emptySelection.copy(credentialProfiles = true),
            "scripts" to emptySelection.copy(scripts = true),
            "alertRules" to emptySelection.copy(alertRules = true),
            "activeAlerts" to emptySelection.copy(activeAlerts = true),
            "alertHistory" to emptySelection.copy(alertHistory = true),
            "wolTargets" to emptySelection.copy(wolTargets = true),
            "settings" to emptySelection.copy(settings = true),
        )
        for ((name, selection) in variants) {
            assertTrue("$name alone must be classified sensitive", selection.hasSensitiveData())
        }
    }

    @Test
    fun decoding_ignores_unknown_sections() {
        // Persisted selections from older versions may still contain removed keys (backupJobs).
        val decoded = decodeBackupSelection("servers,sshKeys,backupJobs")
        assertTrue(decoded.servers)
        assertTrue(decoded.sshKeys)
        assertFalse(decoded.settings)
    }

    // ── PIN verification + throttling (Base64-free paths) ──

    @Test
    fun legacy_plaintext_pin_still_verifies_until_rehashed() {
        assertTrue(verifyStoredPin("1234", "1234"))
        assertFalse(verifyStoredPin("1234", "9999"))
        assertFalse(verifyStoredPin(null, "1234"))
        assertFalse(verifyStoredPin("1234", ""))
    }

    @Test
    fun pin_entry_locks_out_after_max_failed_attempts() {
        val now = 1_000_000L
        // Below the limit: no lockout deadline, input stays allowed.
        for (attempts in 1 until PIN_MAX_ATTEMPTS) {
            assertEquals(0L, pinLockoutAfterFailure(attempts, now))
        }
        assertFalse(isPinThrottled(0L, now))
        // At the limit: locked for the full window, then allowed again.
        val lockedUntil = pinLockoutAfterFailure(PIN_MAX_ATTEMPTS, now)
        assertEquals(now + PIN_LOCKOUT_MS, lockedUntil)
        assertTrue(isPinThrottled(lockedUntil, now))
        assertTrue(isPinThrottled(lockedUntil, now + PIN_LOCKOUT_MS - 1))
        assertFalse(isPinThrottled(lockedUntil, now + PIN_LOCKOUT_MS))
    }
}
