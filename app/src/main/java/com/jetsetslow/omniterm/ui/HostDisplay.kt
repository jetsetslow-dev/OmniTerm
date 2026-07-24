package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.ServerEntity

/**
 * App-wide "Hide sensitive info" switch: when on, saved endpoints are identified by their
 * user-given names instead of IPs/hostnames (screen-share/screenshot safe). Display-only:
 * connections always use the real host.
 *
 * A Compose-observable singleton (synced from AppViewModel's persisted setting) so deep
 * leaf composables don't all need the ViewModel threaded through for a label.
 */
object HostDisplay {
    var hideSensitiveInfo by mutableStateOf(false)

    /** Address-position text for a server: its name when sensitive info is hidden. */
    fun host(srv: ServerEntity): String =
        if (hideSensitiveInfo) srv.name.ifBlank { "host" } else srv.host

    /** Name-position text for a server (blank names fall back to the address when allowed). */
    fun name(srv: ServerEntity): String =
        srv.name.ifBlank { if (hideSensitiveInfo) "host" else srv.host }

    /** The usual "user@host" line, honouring the hide-sensitive-info mode. */
    fun userAtHost(srv: ServerEntity): String = "${srv.username}@${host(srv)}"

    /** Address-position text for a network share. */
    fun address(share: NetworkShareEntity): String =
        if (hideSensitiveInfo) share.name.ifBlank { "share" } else share.address

    /** Generic mask for sensitive values with no name to substitute (MACs, tunnel endpoints). */
    fun sensitive(value: String): String = if (hideSensitiveInfo) "•••" else value
}
