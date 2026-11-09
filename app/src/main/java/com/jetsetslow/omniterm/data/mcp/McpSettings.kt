package com.jetsetslow.omniterm.data.mcp

/**
 * The MCP server's settings. All of them stay on this phone and never travel in a backup, so
 * restoring one never opens the phone to an assistant the user did not allow here.
 */
object McpSettings {
    /** Whether the server runs; off unless the user turns it on. */
    const val ENABLED = "mcp_enabled"
    /** The bearer token's SHA-256; the token itself is shown once and never kept. */
    const val TOKEN_HASH = "mcp_token_hash"
    /** The ids of the hosts assistants may see, comma separated; none until the user picks some. */
    const val HOSTS = "mcp_hosts"
    /** Whether `run_command` is offered; saved scripts only unless the user allows it. */
    const val ANY_COMMAND = "mcp_any_command"
    /** The loopback port on this phone. */
    const val PORT = "mcp_port"
    /** The saved host a computer reaches the server through, by id; empty for none. */
    const val TUNNEL_HOST = "mcp_tunnel_host"
    /** The port that host listens on, on its own loopback address. */
    const val TUNNEL_PORT = "mcp_tunnel_port"

    val ALL = setOf(ENABLED, TOKEN_HASH, HOSTS, ANY_COMMAND, PORT, TUNNEL_HOST, TUNNEL_PORT)

    const val DEFAULT_PORT = 47821
    /** Calls kept in the record. */
    const val KEEP_CALLS = 200
    /** How long a run waits for the user's answer on the phone before it is refused. */
    const val APPROVAL_TIMEOUT_MS = 120_000L
    /** A run stops waiting for its hosts after this; clients give up on a silent call well before Tasker would. */
    const val RUN_TIMEOUT_MS = 5 * 60_000L

    /** A port the user typed, or null when it is not one a phone app may listen on. */
    fun port(text: String?): Int? = text?.trim()?.toIntOrNull()?.takeIf { it in 1024..65535 }
}
