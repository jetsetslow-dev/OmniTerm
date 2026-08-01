package com.jetsetslow.omniterm.shared.data

/**
 * Platform-neutral backup interchange used to move a fleet between Android and iOS (IOS-092).
 * It carries no secret material: [BackupHost.secretRef] only records *that* a credential existed,
 * so the destination can ask for it again instead of transporting it.
 */
data class BackupHost(
    val externalId: String,
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    val hadSecret: Boolean = false,
)

data class BackupEnvelope(
    val schemaVersion: Int,
    val producedBy: String,
    val kdfIterations: Int,
    val hosts: List<BackupHost>,
    val unsupportedFeatures: List<String> = emptyList(),
)

sealed interface BackupValidation {
    data object Valid : BackupValidation
    data class Rejected(val reason: String) : BackupValidation
}

/** Bounds applied before any parsing work: a crafted backup must not be able to exhaust memory. */
const val BACKUP_MIN_SCHEMA_VERSION: Int = 1
const val BACKUP_MAX_SCHEMA_VERSION: Int = 3
const val BACKUP_MAX_HOSTS: Int = 5_000
const val BACKUP_MIN_KDF_ITERATIONS: Int = 100_000
const val BACKUP_MAX_KDF_ITERATIONS: Int = 2_000_000

fun validateBackup(envelope: BackupEnvelope): BackupValidation = when {
    envelope.schemaVersion < BACKUP_MIN_SCHEMA_VERSION ->
        BackupValidation.Rejected("Backup schema ${envelope.schemaVersion} is older than this app supports")
    envelope.schemaVersion > BACKUP_MAX_SCHEMA_VERSION ->
        BackupValidation.Rejected("Backup schema ${envelope.schemaVersion} was written by a newer OmniTerm")
    envelope.hosts.size > BACKUP_MAX_HOSTS ->
        BackupValidation.Rejected("Backup declares ${envelope.hosts.size} hosts, above the ${BACKUP_MAX_HOSTS} limit")
    // A low iteration count is a downgrade attack on the archive's own protection; a huge one is a
    // denial of service against the importing device.
    envelope.kdfIterations < BACKUP_MIN_KDF_ITERATIONS ->
        BackupValidation.Rejected("Backup key derivation is weaker than the supported minimum")
    envelope.kdfIterations > BACKUP_MAX_KDF_ITERATIONS ->
        BackupValidation.Rejected("Backup key derivation cost is above the supported maximum")
    envelope.hosts.any { it.externalId.isBlank() } ->
        BackupValidation.Rejected("Backup contains a host without a stable identifier")
    envelope.hosts.map { it.externalId }.toSet().size != envelope.hosts.size ->
        BackupValidation.Rejected("Backup contains duplicate host identifiers")
    envelope.hosts.any { it.port !in 1..65_535 } ->
        BackupValidation.Rejected("Backup contains a host with an invalid port")
    else -> BackupValidation.Valid
}

data class ImportPlan(
    val added: List<BackupHost> = emptyList(),
    val updated: List<BackupHost> = emptyList(),
    val skipped: List<BackupHost> = emptyList(),
    val unsupportedFeatures: List<String> = emptyList(),
    /** Hosts whose credential must be entered again: secrets never cross devices. */
    val credentialReentry: List<BackupHost> = emptyList(),
) {
    val isEmpty: Boolean get() = added.isEmpty() && updated.isEmpty()
}

sealed interface ImportOutcome {
    data class Applied(val hosts: List<BackupHost>, val plan: ImportPlan) : ImportOutcome
    data class Failed(val reason: String) : ImportOutcome
}

/**
 * Builds the plan without touching the destination. [selection] chooses which external IDs to
 * import; an empty selection means "everything in the envelope".
 */
fun planImport(
    existing: List<BackupHost>,
    envelope: BackupEnvelope,
    selection: Set<String> = emptySet(),
): ImportPlan {
    val byId = existing.associateBy { it.externalId }
    val chosen = envelope.hosts.filter { selection.isEmpty() || it.externalId in selection }
    val added = mutableListOf<BackupHost>()
    val updated = mutableListOf<BackupHost>()
    chosen.forEach { host ->
        val current = byId[host.externalId]
        when {
            current == null -> added += host
            // Re-importing an identical host is not an update; reporting it as one would make the
            // summary claim changes the user never made.
            current.copy(hadSecret = host.hadSecret) != host -> updated += host
        }
    }
    val touched = (added + updated).map { it.externalId }.toSet()
    return ImportPlan(
        added = added,
        updated = updated,
        skipped = envelope.hosts.filterNot { it.externalId in touched },
        unsupportedFeatures = envelope.unsupportedFeatures,
        credentialReentry = (added + updated).filter { it.hadSecret },
    )
}

/**
 * Applies a plan atomically: the merged list is built and validated in full before it is returned,
 * so a rejected envelope or a mid-merge failure leaves the caller's existing data untouched.
 */
fun applyImport(existing: List<BackupHost>, envelope: BackupEnvelope, plan: ImportPlan): ImportOutcome {
    when (val validation = validateBackup(envelope)) {
        is BackupValidation.Rejected -> return ImportOutcome.Failed(validation.reason)
        BackupValidation.Valid -> Unit
    }
    val merged = existing.toMutableList()
    plan.updated.forEach { host ->
        val index = merged.indexOfFirst { it.externalId == host.externalId }
        if (index < 0) return ImportOutcome.Failed("Host ${host.externalId} disappeared during import")
        // Credentials are re-entered on the destination, so never claim the imported row has one.
        merged[index] = host.copy(hadSecret = false)
    }
    plan.added.forEach { host ->
        if (merged.any { it.externalId == host.externalId }) {
            return ImportOutcome.Failed("Host ${host.externalId} was added twice during import")
        }
        merged += host.copy(hadSecret = false)
    }
    return ImportOutcome.Applied(merged, plan)
}
