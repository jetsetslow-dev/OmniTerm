package com.jetsetslow.omniterm.shared.platform

import com.jetsetslow.omniterm.shared.core.DiagnosticEvent
import com.jetsetslow.omniterm.shared.core.DiagnosticLogger
import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.LogLevel

/**
 * A handle to a secret held by the platform keystore. Domain models, database rows, widget
 * snapshots, and backups carry this reference — never the plaintext.
 */
data class SecretRef(val id: String) {
    /** Deliberately opaque: a reference printed into a log must not reveal which credential it is. */
    override fun toString(): String = "SecretRef(#)"
}

/**
 * When the platform may unlock the item. `WhenUnlockedThisDeviceOnly` is the default because
 * OmniTerm secrets are never needed while the device is locked, and `ThisDeviceOnly` keeps them out
 * of encrypted backups and cross-device sync.
 */
enum class SecretAccessibility {
    WhenUnlockedThisDeviceOnly,
    AfterFirstUnlockThisDeviceOnly,
}

/** Overwrites key material in place once it is no longer needed. */
fun ByteArray.wipe() {
    for (index in indices) this[index] = 0
}

/**
 * Portable secret handling (IOS-060). It owns namespacing, the authentication gate, typed failures,
 * and the guarantee that no secret value or key name reaches a log. The platform half — Android
 * Keystore and Apple Keychain, including [SecretAccessibility] mapping — is implemented behind
 * [SecretStorage].
 */
class SecretVault(
    private val storage: SecretStorage,
    private val ids: IdGenerator,
    private val logger: DiagnosticLogger = DiagnosticLogger { },
    private val authenticator: BiometricAuthenticator? = null,
) {
    /** Stores or rotates a secret. Passing [existing] keeps the reference stable across a rotation. */
    suspend fun store(secret: ByteArray, existing: SecretRef? = null): CapabilityResult<SecretRef> {
        if (secret.isEmpty()) return CapabilityResult.Failed(PlatformError.Protocol("empty-secret"))
        val ref = existing ?: SecretRef(ids.nextId())
        return when (val result = storage.store(storageKey(ref), secret)) {
            is CapabilityResult.Available -> {
                logger.log(DiagnosticEvent("secret.stored", mapOf("rotated" to (existing != null).toString())))
                CapabilityResult.Available(ref)
            }
            is CapabilityResult.Unsupported -> result
            is CapabilityResult.Failed -> result
        }
    }

    /**
     * Reveals a secret. With [requireAuthentication] the read only happens after the user passes
     * device authentication: a cancelled or failed prompt must never fall through to the storage.
     */
    suspend fun reveal(
        ref: SecretRef,
        requireAuthentication: Boolean = false,
        reason: AuthenticationReason = AuthenticationReason.RevealSecret,
    ): CapabilityResult<ByteArray> {
        if (requireAuthentication) {
            val auth = authenticator
                ?: return CapabilityResult.Unsupported("Device authentication is unavailable")
            when (val outcome = auth.authenticate(reason)) {
                is CapabilityResult.Available -> Unit
                is CapabilityResult.Unsupported -> return outcome
                is CapabilityResult.Failed -> return outcome
            }
        }
        return when (val result = storage.read(storageKey(ref))) {
            is CapabilityResult.Available ->
                // A missing item is a failure, not an empty success: callers that treat null as
                // "no password" would silently try an unauthenticated connection.
                result.value?.let { CapabilityResult.Available(it) }
                    ?: CapabilityResult.Failed(PlatformError.NotFound)
            is CapabilityResult.Unsupported -> result
            is CapabilityResult.Failed -> result
        }
    }

    suspend fun remove(ref: SecretRef): CapabilityResult<Unit> {
        val result = storage.remove(storageKey(ref))
        if (result is CapabilityResult.Available) {
            logger.log(DiagnosticEvent("secret.removed", level = LogLevel.Info))
        }
        return result
    }

    /** Deletes every secret no domain object references any more. */
    suspend fun removeOrphans(referenced: Set<SecretRef>, known: Set<SecretRef>): Int {
        var removed = 0
        (known - referenced).forEach { if (remove(it) is CapabilityResult.Available) removed++ }
        return removed
    }

    private fun storageKey(ref: SecretRef): String = "$KEY_PREFIX${ref.id}"

    private companion object {
        /** Namespaced so an OmniTerm item can never collide with another app's or a legacy key. */
        const val KEY_PREFIX = "com.jetsetslow.omniterm.secret."
    }
}
