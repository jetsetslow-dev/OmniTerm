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
    fun storageContainerAndClusterDeletesAreFlagged() {
        assertTrue(hits("zpool destroy tank").contains("storage pool or volume destruction"))
        assertTrue(hits("zfs destroy -r tank/data").contains("storage pool or volume destruction"))
        assertTrue(hits("lvremove -f vg0/root").contains("storage pool or volume destruction"))
        assertTrue(hits("mdadm --zero-superblock /dev/sdb").contains("storage pool or volume destruction"))
        assertTrue(hits("docker system prune -af").contains("container data removal"))
        assertTrue(hits("podman volume prune").contains("container data removal"))
        assertTrue(hits("docker compose -f stack.yml down -v").contains("container data removal"))
        assertTrue(hits("docker-compose down --volumes").contains("container data removal"))
        assertTrue(hits("kubectl -n media delete pod jellyfin-0").contains("Kubernetes resource deletion"))
        assertTrue(hits("kubectl drain node2 --ignore-daemonsets").contains("Kubernetes resource deletion"))
        assertTrue(hits("helm uninstall traefik").contains("Kubernetes resource deletion"))
        assertTrue(hits("qm destroy 101 --purge").contains("Proxmox VM or container destroy/hard stop"))
        assertTrue(hits("pct stop 200").contains("Proxmox VM or container destroy/hard stop"))
        assertTrue(hits("find /var/log -name '*.gz' -delete").contains("recursive/forced delete"))
        assertTrue(hits("crontab -r").contains("deleting every cron job"))
    }

    @Test
    fun commandsThatEndSshAccessAreFlagged() {
        assertTrue(hits("sudo systemctl stop sshd").contains("may cut off SSH access"))
        assertTrue(hits("systemctl disable --now ssh.service").contains("may cut off SSH access"))
        assertTrue(hits("ufw enable").contains("may cut off SSH access"))
        assertTrue(hits("iptables -P INPUT DROP").contains("may cut off SSH access"))
    }

    @Test
    fun windowsDestructiveCommandsAreFlagged() {
        assertTrue(hits("Remove-Item C:\\Temp -Recurse -Force").contains("recursive/forced delete"))
        assertTrue(hits("rd /s /q C:\\build").contains("recursive/forced delete"))
        assertTrue(hits("Format-Volume -DriveLetter D").contains("filesystem format/wipe"))
        assertTrue(hits("Stop-Computer -Force").contains("host reboot/shutdown"))
        assertTrue(hits("Restart-Computer").contains("host reboot/shutdown"))
    }

    @Test
    fun everydayAdminCommandsStayQuiet() {
        assertTrue(hits("docker compose down").isEmpty())
        assertTrue(hits("docker compose pull && docker compose up -d").isEmpty())
        assertTrue(hits("kubectl get pods -A").isEmpty())
        assertTrue(hits("zfs list -t snapshot").isEmpty())
        assertTrue(hits("qm list").isEmpty())
        assertTrue(hits("systemctl restart sshd").isEmpty())
        assertTrue(hits("crontab -l").isEmpty())
        assertTrue(hits("Get-ChildItem -Recurse C:\\Logs").isEmpty())
        // A guest shutdown is not a host shutdown.
        assertTrue(hits("qm shutdown 101").isEmpty())
        assertTrue(hits("shutdown -h now").contains("host shutdown"))
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
