package com.jetsetslow.omniterm.shared.feature

/**
 * The session identity a foreground/ongoing notification action carries back to the app. Ported
 * verbatim from Android's `SessionNotificationPayload` so the two platforms encode the same thing.
 */
data class SessionNotificationPayload(
    val id: String,
    val name: String,
)

/** One `id\nname` record per *connected* session; background/dead sessions are not offered. */
fun encodeSessionNotificationPayloads(sessions: List<SessionNotificationPayload>): List<String> =
    sessions.map { "${it.id}\n${it.name}" }

/**
 * Rejects anything without an id before the newline. A malformed record must not become a session
 * action that resumes an arbitrary or empty target.
 */
fun decodeSessionNotificationPayload(raw: String): SessionNotificationPayload? {
    val newline = raw.indexOf('\n')
    if (newline < 1) return null
    val id = raw.substring(0, newline)
    val name = raw.substring(newline + 1)
    if (id.isBlank()) return null
    return SessionNotificationPayload(id, name)
}
