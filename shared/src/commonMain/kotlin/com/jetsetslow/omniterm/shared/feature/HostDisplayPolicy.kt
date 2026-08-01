package com.jetsetslow.omniterm.shared.feature

/**
 * The identity fields any surface needs to label a host. Deliberately not the persistence entity:
 * shared code must not depend on either platform's row type.
 */
data class HostIdentity(
    val name: String,
    val address: String,
    val username: String = "",
)

/**
 * "Hide sensitive info" rules, ported from Android's `HostDisplay` so both platforms mask the same
 * way. When on, a saved endpoint is identified by the name its owner typed instead of its
 * IP/hostname, which is what makes a screenshot or screen share safe. Display-only: connections
 * always use the real address.
 *
 * Android's version is a Compose-observable singleton; the shared rules are pure functions that
 * take the flag, because `commonMain` may not own Compose state and iOS reads the same setting from
 * its own store.
 */
object HostDisplayPolicy {
    /** Address-position text: the host's name when sensitive info is hidden. */
    fun host(identity: HostIdentity, hideSensitiveInfo: Boolean): String =
        if (hideSensitiveInfo) identity.name.ifBlank { "host" } else identity.address

    /** Name-position text; a blank name falls back to the address only when that is allowed. */
    fun name(identity: HostIdentity, hideSensitiveInfo: Boolean): String =
        identity.name.ifBlank { if (hideSensitiveInfo) "host" else identity.address }

    /** The usual `user@host` line, honouring the hide-sensitive-info mode. */
    fun userAtHost(identity: HostIdentity, hideSensitiveInfo: Boolean): String =
        "${identity.username}@${host(identity, hideSensitiveInfo)}"

    /** Address-position text for a network share. */
    fun shareAddress(name: String, address: String, hideSensitiveInfo: Boolean): String =
        if (hideSensitiveInfo) name.ifBlank { "share" } else address

    /** Generic mask for sensitive values with no name to substitute (MACs, tunnel endpoints). */
    fun sensitive(value: String, hideSensitiveInfo: Boolean): String =
        if (hideSensitiveInfo) "•••" else value
}
