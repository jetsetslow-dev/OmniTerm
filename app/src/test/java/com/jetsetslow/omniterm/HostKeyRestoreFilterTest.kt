package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Backup restore on the free Play Store build skips hosts beyond the 1-host limit. Pinned host
 * keys must be imported only for hosts actually restored — never left as orphaned trust entries
 * for skipped hosts. [SshHostKeyTrust.filterEntriesForHosts] is the pure filter that enforces this.
 */
class HostKeyRestoreFilterTest {

    private fun entry(host: String, type: String = "ssh-ed25519") = "$host|$type"

    @Test
    fun keeps_only_keys_for_restored_hosts() {
        val entries = mapOf(
            entry("10.0.0.1") to "KEY_A",
            entry("10.0.0.2") to "KEY_B",
            entry("10.0.0.3") to "KEY_C",
        )
        // Only the first host was restored (the others were skipped by the limit).
        val kept = SshHostKeyTrust.filterEntriesForHosts(entries, listOf("10.0.0.1" to 22))

        assertEquals(setOf(entry("10.0.0.1")), kept.keys)
        assertEquals("KEY_A", kept[entry("10.0.0.1")])
    }

    @Test
    fun matches_port_qualified_alias_forms() {
        // Keys can be pinned under bare host, "host:port", or "[host]:port".
        val entries = mapOf(
            entry("host.example") to "BARE",
            entry("host.example:2222") to "COLON",
            entry("[host.example]:2222") to "BRACKET",
            entry("other.example") to "OTHER",
        )
        val kept = SshHostKeyTrust.filterEntriesForHosts(entries, listOf("host.example" to 2222))

        assertEquals(setOf(entry("host.example"), entry("host.example:2222"), entry("[host.example]:2222")), kept.keys)
        assertTrue("unrelated host must be dropped", entry("other.example") !in kept.keys)
    }

    @Test
    fun empty_restored_hosts_drops_everything() {
        val entries = mapOf(entry("10.0.0.1") to "KEY_A")
        assertTrue(SshHostKeyTrust.filterEntriesForHosts(entries, emptyList()).isEmpty())
    }

    @Test
    fun empty_entries_returns_empty() {
        assertTrue(SshHostKeyTrust.filterEntriesForHosts(emptyMap(), listOf("10.0.0.1" to 22)).isEmpty())
    }
}
