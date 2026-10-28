package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.ServerEntity

/** A tmux session that lives on a saved host's server, open here or only saved for recovery. */
internal data class HostTmuxSession(val serverId: Int, val tmuxName: String)

/**
 * Every tmux session on the servers of [serverIds]: the persistent sessions open here plus the
 * saved ones that are not. Deleting a host offers to end exactly these, because once the host is
 * gone nothing in the app points at them any more.
 */
internal fun hostTmuxSessions(
    serverIds: Set<Int>,
    openPersistent: List<HostTmuxSession>,
    saved: List<PersistentSessionEntity>,
): List<HostTmuxSession> =
    (openPersistent + saved.map { HostTmuxSession(it.serverId, it.tmuxName) })
        .filter { it.serverId in serverIds }
        .distinctBy { it.tmuxName }

/** How an attempt to end a tmux session on its server turned out. */
internal sealed interface TmuxEndResult {
    data object Ended : TmuxEndResult

    /** The server could not be reached (or refused the login); [reason] is the transport's reply. */
    data class Unreachable(val reason: String) : TmuxEndResult

    /** The server answered, but tmux did not confirm the session is gone. */
    data object NotConfirmed : TmuxEndResult
}

/**
 * Runs [kill], then asks tmux whether the session still exists. Only a confirmed absence counts
 * as ended: a kill that seemed to work but cannot be checked leaves the session saved, so nothing
 * still running on a server is ever forgotten by accident.
 */
internal suspend fun endRemoteTmux(
    kill: suspend () -> String,
    stillExists: suspend () -> Boolean?,
): TmuxEndResult {
    val reply = kill().trim()
    if (reply.startsWith("SSH Error")) return TmuxEndResult.Unreachable(reply)
    return if (stillExists() == false) TmuxEndResult.Ended else TmuxEndResult.NotConfirmed
}

/**
 * Whether a deleted host's trusted SSH keys must stay because another saved host uses the same
 * address. Keys are stored under the bare host name as well as host:port (JSch's form for port
 * 22), so removing one host's keys would also drop those of a second host on the same machine,
 * even on another port, and its next connection would ask to trust the machine again.
 */
internal fun keepTrustedHostKeys(deletedHost: String, remaining: List<ServerEntity>): Boolean =
    remaining.any { it.host == deletedHost }
