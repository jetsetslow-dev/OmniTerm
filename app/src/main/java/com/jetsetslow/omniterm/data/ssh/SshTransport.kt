package com.jetsetslow.omniterm.data.ssh

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * Platform-agnostic SSH abstraction.
 *
 * This interface is intentionally free of JSch (or any JVM-only) types so that, when the
 * project moves to Compose Multiplatform, it becomes an `expect`/`actual` boundary:
 * the Android `actual` keeps the JSch implementation in [JschSshTransport], while an iOS
 * `actual` can wrap NMSSH / Swift-NIO-SSH. Everything above this line (view-model, UI,
 * terminal emulator) is already pure Kotlin and moves to `commonMain` unchanged.
 */
interface SshTransport {
    /**
     * Run a single command on a throwaway exec channel and return its combined output.
     * [stdin] is written to the remote command's standard input and never appears in the
     * command string itself — used to feed `sudo -S` its password without the password
     * landing in `ps` output, shell audit logs, or sshd debug logs.
     */
    suspend fun exec(creds: SshCredentials, command: String, stdin: String? = null): String

    /**
     * Run a command and stream its output incrementally (stdout + stderr merged) by invoking
     * [onChunk] for each read burst until the channel closes. Useful for long-running docker
     * commands (pull, update) where the caller wants to show progress in real-time.
     * The full combined output is also returned for convenience once the command finishes.
     * [stdin] behaves as in [exec].
     */
    suspend fun execStream(creds: SshCredentials, command: String, stdin: String? = null, onChunk: suspend (String) -> Unit): String

    /**
     * Actually authenticate against the host: open a session and connect with the given
     * credentials, then tear it down. Returns null on success, or a human-readable error
     * (e.g. "Auth fail", "Connection refused") on failure. This is a *real* connectivity
     * + credential test, not a TCP ping.
     */
    suspend fun testConnection(creds: SshCredentials): String?

    /**
     * Open a persistent interactive shell backed by a PTY. The returned [TerminalSession]
     * streams raw bytes from the remote and accepts raw keystrokes — this is what makes
     * `cd`, env state, tab-completion, arrow-key history and full-screen apps work.
     * [onPhaseChange] is called with human-readable progress strings during connection setup.
     */
    suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)? = null): TerminalSession

    /** Release any pooled/cached connections held by the transport. Idempotent; default no-op. */
    fun shutdown() {}
}

/** A live interactive shell channel. */
interface TerminalSession {
    /** Raw bytes received from the remote PTY. Completes when the session closes. */
    val output: Flow<ByteArray>

    /** `true` once the channel/session has been torn down (by either side). */
    val closed: StateFlow<Boolean>

    /** Send raw bytes (keystrokes / escape sequences) to the remote PTY. */
    suspend fun write(bytes: ByteArray)

    /** Inform the remote of a new terminal window size (SIGWINCH). */
    suspend fun resize(cols: Int, rows: Int)

    /** Close the channel and underlying session. Idempotent. */
    fun close()
}

/**
 * Resolved connection credentials. The view-model flattens a `ServerEntity` (plus any
 * referenced key/profile rows) into this so the transport never touches the database layer.
 */
data class SshCredentials(
    val host: String,
    val port: Int,
    val username: String,
    val password: String? = null,
    /** OpenSSH/PEM private key contents, when authenticating by key. */
    val privateKeyPem: String? = null,
    val passphrase: String? = null,
    /** Proxy used to reach [host]: one of "none", "http", "socks5", "ssh" (jump host). */
    val proxyType: String = "none",
    val proxyHost: String = "",
    val proxyPort: Int = 0,
    val proxyUser: String = "",
    val proxyPassword: String = "",
    /** OpenSSH/PEM private key contents for the jump host, when proxyType == "ssh". */
    val proxyKeyPem: String? = null,
)

/** Connection failed before/while establishing the shell or exec channel. */
class SshConnectException(message: String, cause: Throwable? = null) : Exception(message, cause)
