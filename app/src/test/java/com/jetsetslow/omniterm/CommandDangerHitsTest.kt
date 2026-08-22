package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.commandDangerHits
import com.jetsetslow.omniterm.ui.fleetCommandDangerWarning
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `commandDangerHits` is Fleet's last check before a command runs on every selected host at once,
 * so the multiplier is what makes a miss expensive: the same typo costs one host or forty.
 *
 * Two of its patterns only matched when the destructive flag came *first*, because `\S*` cannot
 * cross a space. `dd if=/dev/zero of=/dev/sda` — the canonical disk-destroyer, written the way every
 * tutorial writes it — was the one form that slipped through.
 */
class CommandDangerHitsTest {

    private fun hits(command: String) = commandDangerHits(command)

    @Test
    fun ddIsCaughtWhateverTheArgumentOrder() {
        // The first of these was NOT flagged before the fix.
        assertTrue(hits("dd if=/dev/zero of=/dev/sda bs=1M").contains("raw write with dd"))
        assertTrue(hits("dd of=/dev/sda if=/dev/zero").contains("raw write with dd"))
        assertTrue(hits("dd if=/dev/sda of=/backup/disk.img").contains("raw write with dd"))
        assertTrue(hits("dd bs=4M status=progress if=/dev/zero of=/dev/nvme0n1").contains("raw write with dd"))
    }

    @Test
    fun iptablesFlushIsCaughtBehindTableFlags() {
        assertTrue(hits("iptables -F").contains("firewall teardown"))
        // Not flagged before the fix: `nat` is not a flag, so the pattern stopped there.
        assertTrue(hits("iptables -t nat -F").contains("firewall teardown"))
        assertTrue(hits("iptables -t filter -F INPUT").contains("firewall teardown"))
    }

    @Test
    fun theScanStopsAtACommandBoundary() {
        // Widening the scan must not let one command's arguments arm another command's rule, or the
        // warning becomes noise and users learn to click through it.
        assertTrue(hits("dd if=/dev/zero; echo of=nothing").isEmpty())
        assertTrue(hits("echo dd | grep of=").isEmpty())
        assertTrue(hits("iptables -L && echo -F").isEmpty())
    }

    @Test
    fun harmlessUsesOfTheSameToolsAreNotFlagged() {
        assertTrue(hits("iptables -L -n").isEmpty())
        assertTrue(hits("iptables -t nat -L").isEmpty())
        assertTrue(hits("ls /dev/sda").isEmpty())
    }

    @Test
    fun theOtherPatternsStillWork() {
        assertTrue(hits("rm -rf /var/tmp/build").contains("recursive/forced delete"))
        assertTrue(hits("mkfs.ext4 /dev/sdb1").contains("filesystem format/wipe"))
        assertTrue(hits("systemctl reboot").contains("host reboot/shutdown"))
        assertTrue(hits("userdel deploy").contains("account deletion"))
        assertTrue(hits("cat /dev/zero > /dev/sda").contains("writing directly to a block device"))
    }

    @Test
    fun anOrdinaryCommandProducesNoWarning() {
        assertTrue(hits("systemctl restart nginx").isEmpty())
        assertNull(fleetCommandDangerWarning("uptime"))
    }

    @Test
    fun theWarningNamesWhatItMatched() {
        val warning = fleetCommandDangerWarning("dd if=/dev/zero of=/dev/sda")
        assertNotNull(warning)
        assertTrue(warning!!.contains("raw write with dd"))
        assertTrue(warning.contains("every host"))
    }

    @Test
    fun labelsAreNotRepeated() {
        // Two matches of the same rule should read as one reason, not two.
        assertEquals(
            1,
            hits("dd if=/dev/zero of=/dev/sda").count { it == "raw write with dd" },
        )
    }
}
