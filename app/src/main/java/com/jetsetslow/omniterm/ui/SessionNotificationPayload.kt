package com.jetsetslow.omniterm.ui

data class SessionNotificationPayload(
    val id: String,
    val name: String,
)

fun encodeSessionNotificationPayload(sessions: List<ShellSession>): ArrayList<String> =
    ArrayList(
        sessions
            .filter { it.isConnected }
            .map { "${it.id}\n${it.serverName}" }
    )

fun decodeSessionNotificationPayload(raw: String): SessionNotificationPayload? {
    val newline = raw.indexOf('\n')
    if (newline < 1) return null
    val id = raw.substring(0, newline)
    val name = raw.substring(newline + 1)
    if (id.isBlank()) return null
    return SessionNotificationPayload(id, name)
}
