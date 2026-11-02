package com.jetsetslow.omniterm.data.ssh

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * What [SshTransport.execStream] returns after "SSH Error: " when the connection dropped before the
 * command finished. The command may still be running on the host.
 */
const val SSH_CONNECTION_LOST = "connection lost before the command finished"

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

    /** [testConnection], asking [interactiveAuth] the host's sign-in questions; see [InteractiveAuth]. */
    suspend fun testConnection(creds: SshCredentials, interactiveAuth: InteractiveAuth?): String? = testConnection(creds)

    /**
     * Signs in to [creds]'s host for one-shot commands, asking [interactiveAuth] any question the host
     * has beyond the saved password (a one-time code), so the commands and terminals that follow
     * reuse that sign-in instead of asking again. Null on success, else what went wrong. A host
     * with no such question needs none of this; its commands sign in on their own.
     */
    suspend fun signIn(creds: SshCredentials, interactiveAuth: InteractiveAuth): String? = null

    /**
     * Open a persistent interactive shell backed by a PTY. The returned [TerminalSession]
     * streams raw bytes from the remote and accepts raw keystrokes — this is what makes
     * `cd`, env state, tab-completion, arrow-key history and full-screen apps work.
     * [onPhaseChange] is called with human-readable progress strings during connection setup.
     */
    suspend fun openShell(creds: SshCredentials, cols: Int, rows: Int, onPhaseChange: ((String) -> Unit)? = null): TerminalSession

    /**
     * [openShell], asking [interactiveAuth] the host's sign-in questions beyond the saved password,
     * for terminals the user opened; see [InteractiveAuth].
     */
    suspend fun openShell(
        creds: SshCredentials,
        cols: Int,
        rows: Int,
        interactiveAuth: InteractiveAuth?,
        onPhaseChange: ((String) -> Unit)? = null,
    ): TerminalSession = openShell(creds, cols, rows, onPhaseChange)

    /** Release any pooled/cached connections held by the transport. Idempotent; default no-op. */
    fun shutdown() {}

    /** Forget cached authenticated transport state for one credential set. */
    fun forgetCredentials(creds: SshCredentials) {}
}

/** A live interactive shell channel. */
interface TerminalSession {
    /** Raw bytes received from the remote PTY. Completes when the session closes. */
    val output: Flow<ByteArray>

    /** `true` once the channel/session has been torn down (by either side). */
    val closed: StateFlow<Boolean>

    /**
     * Remote shell exit status when known. Normal shell exits are usually `0`; a transport drop
     * commonly leaves this as `-1`, which lets callers decide whether reconnect is appropriate.
     */
    val exitStatus: StateFlow<Int?>

    /**
     * `true` only when the remote deliberately ended the channel — i.e. the remote shell ran to
     * completion (`exit`) and the server sent a genuine SSH channel-EOF. A network/transport drop
     * (socket death, WiFi off) NEVER sets this: the remote never gets to send EOF. This is the
     * unambiguous "the shell really exited" signal callers use to decide tear-down vs. reconnect,
     * independent of the exit-status number (which can lag or be missing on a clean exit).
     */
    val remoteExited: StateFlow<Boolean>

    /**
     * Send raw bytes to the remote PTY. Return only after the transport write and flush complete;
     * throw on a closed channel, write failure or cancellation. Failure can follow partial
     * delivery. A successful return acknowledges transport acceptance, not remote execution.
     */
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
    /** SSH protocol keepalive interval. Zero disables protocol keepalives. */
    val keepAliveSeconds: Int = 30,
    /** Negotiate delayed zlib compression for bandwidth-constrained links. */
    val compression: Boolean = false,
    /**
     * Forward the SSH authentication agent to the remote (OpenSSH `ForwardAgent yes` / `ssh -A`),
     * so onward SSH hops from the remote can authenticate with the key we connected with — without
     * copying the private key onto the server. Off by default (it grants the remote use of the key
     * for the session's lifetime).
     */
    val agentForwarding: Boolean = false,
    /**
     * Run each exec command in `sh` rather than the login shell
     * ([com.jetsetslow.omniterm.data.RemoteCommands.inPosixShell]).
     * Set for hosts known to be Unix, whose app commands are all POSIX sh while the user's login
     * shell may be csh, fish or zsh. Off for Windows hosts, for hosts not yet probed, and for
     * commands the user typed, which belong to the user's own shell.
     */
    val posixShell: Boolean = false,
)

/** Connection failed before/while establishing the shell or exec channel. */
class SshConnectException(message: String, cause: Throwable? = null) : Exception(message, cause)
