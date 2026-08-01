package com.jetsetslow.omniterm.shared.platform

/**
 * Outcome of comparing a presented host key against stored trust. `Unknown` and `Changed` both
 * require an explicit user decision; neither may be auto-approved by any adapter.
 */
sealed interface HostKeyDecision {
    data object Trusted : HostKeyDecision
    data object Unknown : HostKeyDecision
    data class Changed(val previous: HostKey) : HostKeyDecision
    data class Malformed(val reason: String) : HostKeyDecision
}

/**
 * Persistent known-hosts storage. Keys are aliases from [hostKeyAlias], never bare hostnames: two
 * ports on one host are two different trust records.
 */
interface KnownHostsStore {
    suspend fun find(alias: String): HostKey?
    suspend fun put(alias: String, key: HostKey)
    suspend fun remove(alias: String)
}

/**
 * The alias a host key is stored under. Lower-cased because DNS is case-insensitive while string
 * comparison is not — otherwise `Host.example` and `host.example` would each get their own trust
 * record and a changed key could hide behind the spelling.
 */
fun hostKeyAlias(endpoint: SshEndpoint): String = "${endpoint.host.lowercase()}:${endpoint.port}"

/**
 * Rejects key material that cannot be a real fingerprint before it is ever stored or shown for
 * approval. A malformed value must never be persisted: it would silently match nothing later and
 * turn every subsequent connection into a fresh "unknown host" prompt.
 */
internal fun hostKeyProblem(key: HostKey): String? {
    if (key.algorithm.isBlank()) return "missing algorithm"
    if (key.algorithm.any { it.isWhitespace() }) return "algorithm contains whitespace"
    val fingerprint = key.fingerprint
    if (fingerprint.isBlank()) return "missing fingerprint"
    if (fingerprint.any { it.isWhitespace() }) return "fingerprint contains whitespace"
    val digest = when {
        fingerprint.startsWith("SHA256:") -> fingerprint.removePrefix("SHA256:")
        fingerprint.startsWith("MD5:") -> return "MD5 fingerprints are not accepted"
        else -> return "unrecognized fingerprint format"
    }
    // Unpadded base64 of a 32-byte digest is 43 characters.
    if (digest.length != 43) return "fingerprint is not a SHA-256 digest"
    if (!digest.all { it.isLetterOrDigit() || it == '+' || it == '/' }) return "fingerprint is not base64"
    return null
}

/**
 * Strict known-hosts policy shared by every platform (IOS-052). It never decides to trust: it
 * reports what the stored record says and only writes after [trust] is called with an approval that
 * came from the user.
 */
class HostKeyTrust(private val store: KnownHostsStore) {
    suspend fun evaluate(endpoint: SshEndpoint, presented: HostKey): HostKeyDecision {
        hostKeyProblem(presented)?.let { return HostKeyDecision.Malformed(it) }
        val known = store.find(hostKeyAlias(endpoint)) ?: return HostKeyDecision.Unknown
        // Algorithm is part of identity: an ed25519 key presented where an RSA key was trusted is a
        // change, not a match.
        return if (known.algorithm == presented.algorithm && known.fingerprint == presented.fingerprint) {
            HostKeyDecision.Trusted
        } else {
            HostKeyDecision.Changed(known)
        }
    }

    /** Records an approval. Malformed material is refused even here. */
    suspend fun trust(endpoint: SshEndpoint, key: HostKey): CapabilityResult<Unit> {
        hostKeyProblem(key)?.let { return CapabilityResult.Failed(PlatformError.HostKeyRejected) }
        store.put(hostKeyAlias(endpoint), key)
        return CapabilityResult.Available(Unit)
    }

    suspend fun forget(endpoint: SshEndpoint) {
        store.remove(hostKeyAlias(endpoint))
    }
}
