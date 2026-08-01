package com.jetsetslow.omniterm.shared.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

private fun host(id: String, name: String = id, port: Int = 22, secret: Boolean = false) =
    BackupHost(externalId = id, name = name, host = "$id.example", port = port, username = "root", hadSecret = secret)

private fun envelope(
    hosts: List<BackupHost>,
    version: Int = BACKUP_SCHEMA_VERSION,
    iterations: Int = 210_000,
    unsupported: List<String> = emptyList(),
    format: String = BACKUP_FORMAT,
) = BackupEnvelope(format, version, "android", iterations, hosts, unsupported)

class BackupTransferTest {
    @Test
    fun boundsRejectHostileOrUnsupportedEnvelopes() {
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(emptyList(), version = 0)))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(emptyList(), version = BACKUP_SCHEMA_VERSION + 1)))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(emptyList(), format = "other-backup")))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(emptyList(), iterations = 1_000)))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(emptyList(), iterations = BACKUP_MAX_KDF_ITERATIONS + 1)))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(listOf(host("a"), host("a")))))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(listOf(host("a", port = 0)))))
        assertIs<BackupValidation.Rejected>(validateBackup(envelope(listOf(host("")))))
        assertEquals(BackupValidation.Valid, validateBackup(envelope(listOf(host("a")))))
    }

    @Test
    fun planSeparatesAddedUpdatedAndUnchanged() {
        val existing = listOf(host("a", name = "Alpha"), host("b", name = "Bravo"))
        val incoming = envelope(listOf(host("a", name = "Alpha"), host("b", name = "Bravo 2"), host("c")))

        val plan = planImport(existing, incoming)

        assertEquals(listOf("c"), plan.added.map { it.externalId })
        assertEquals(listOf("b"), plan.updated.map { it.externalId })
        assertEquals(listOf("a"), plan.skipped.map { it.externalId }, "an identical host is not an update")
    }

    @Test
    fun partialSelectionImportsOnlyTheChosenHosts() {
        val incoming = envelope(listOf(host("a"), host("b"), host("c")))

        val plan = planImport(emptyList(), incoming, selection = setOf("b"))

        assertEquals(listOf("b"), plan.added.map { it.externalId })
        assertEquals(listOf("a", "c"), plan.skipped.map { it.externalId })
    }

    @Test
    fun secretsAreNeverTransportedAndAreFlaggedForReentry() {
        val incoming = envelope(listOf(host("a", secret = true), host("b")))
        val plan = planImport(emptyList(), incoming)

        assertEquals(listOf("a"), plan.credentialReentry.map { it.externalId })

        val applied = assertIs<ImportOutcome.Applied>(applyImport(emptyList(), incoming, plan))
        assertTrue(applied.hosts.none { it.hadSecret }, "an imported row must not claim it has a credential")
    }

    @Test
    fun rejectedEnvelopeLeavesTheDestinationUnchanged() {
        val existing = listOf(host("a", name = "Alpha"))
        val hostile = envelope(listOf(host("b")), iterations = 10)
        val plan = planImport(existing, hostile)

        val outcome = assertIs<ImportOutcome.Failed>(applyImport(existing, hostile, plan))

        assertTrue(outcome.reason.isNotBlank())
        assertEquals(listOf(host("a", name = "Alpha")), existing, "the source list must not be mutated")
    }

    @Test
    fun unsupportedFeaturesAreReportedRatherThanSilentlyDropped() {
        val incoming = envelope(listOf(host("a")), unsupported = listOf("smb-shares", "android-widgets"))
        val plan = planImport(emptyList(), incoming)
        assertEquals(listOf("smb-shares", "android-widgets"), plan.unsupportedFeatures)
    }

    @Test
    fun idRemappingUpdatesInPlaceWithoutDuplicating() {
        val existing = listOf(host("a", name = "Old"), host("b"))
        val incoming = envelope(listOf(host("a", name = "New")))
        val plan = planImport(existing, incoming)

        val applied = assertIs<ImportOutcome.Applied>(applyImport(existing, incoming, plan))

        assertEquals(listOf("a", "b"), applied.hosts.map { it.externalId })
        assertEquals("New", applied.hosts.first { it.externalId == "a" }.name)
    }
}
