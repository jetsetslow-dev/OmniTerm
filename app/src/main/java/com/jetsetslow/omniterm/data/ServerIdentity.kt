package com.jetsetslow.omniterm.data

import java.util.Locale

/**
 * A display name and stored secret are not connection identity. SSH usernames are case-sensitive.
 * The [route] is: one machine may be saved once directly and once through a VPN tunnel (or through
 * two tunnels), and those are different hosts.
 */
data class ServerIdentity(
    val host: String,
    val port: Int,
    val username: String,
    val authType: String,
    val route: String = DIRECT_ROUTE,
)

const val DIRECT_ROUTE = "direct"

/** How a host is reached: directly, or through tunnel [tunnelId] at [tunnelHost] inside it. */
fun serverRoute(tunnelId: Int?, tunnelHost: String): String =
    tunnelId?.let { "tunnel:$it@${tunnelHost.trim().lowercase(Locale.ROOT)}" } ?: DIRECT_ROUTE

fun serverIdentity(server: ServerEntity, profiles: List<CredentialProfileEntity>): ServerIdentity? {
    val profile = if (server.authType == "profile") {
        profiles.firstOrNull { it.id == server.authProfileId } ?: return null
    } else null
    return ServerIdentity(
        server.host.trim().lowercase(Locale.ROOT), server.port,
        profile?.username ?: server.username, profile?.authType ?: server.authType,
        serverRoute(server.tunnelId, server.tunnelHost),
    )
}

/** Why a host was not saved: [existingName] already has the same login over the same route. */
fun duplicateServerMessage(existingName: String?): String =
    "The same host, port, SSH user, authentication method and VPN tunnel already exist as \"$existingName\". " +
        "Existing server unchanged."

/** Existing duplicate pairs do not block a name/password change; only newly colliding logins do. */
fun profileServerConflicts(
    servers: List<ServerEntity>,
    profiles: List<CredentialProfileEntity>,
    candidate: CredentialProfileEntity,
): List<Pair<String, String>> {
    val after = profiles.filterNot { it.id == candidate.id } + candidate
    val beforeIdentities = servers.map { serverIdentity(it, profiles) }
    val afterIdentities = servers.map { serverIdentity(it, after) }
    return buildList {
        for (i in servers.indices) {
            if (afterIdentities[i] == null) continue
            for (j in i + 1 until servers.size) {
                if (afterIdentities[i] != afterIdentities[j]) continue
                if (beforeIdentities[i] != null && beforeIdentities[i] == beforeIdentities[j]) continue
                add(servers[i].name to servers[j].name)
            }
        }
    }
}

class ProfileServerConflictException(conflicts: List<Pair<String, String>>) : IllegalArgumentException(
    "Profile not saved. These servers would have the same host, port, SSH user, authentication method and VPN tunnel:\n" +
        conflicts.joinToString("\n") { (first, second) -> "\"$first\" and \"$second\"" } +
        "\nProfile and servers unchanged."
)
