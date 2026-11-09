package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.ssh.sshCommandExit
import com.jetsetslow.omniterm.data.ssh.sshCommandOutput
import kotlin.io.encoding.Base64

/**
 * A saved key's public half put on a host, as `ssh-copy-id` does (ConnectBot #428, #666): added
 * once to the login user's `~/.ssh/authorized_keys`, never twice, with `.ssh` and the file made
 * private when they are new. The line goes to the host on stdin, so nothing in it is ever shell.
 */
object KeyInstall {
    /** Key types an OpenSSH `authorized_keys` line can name, as OmniTerm makes and imports them. */
    val TYPES = setOf(
        "ssh-ed25519",
        "ssh-rsa",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
    )

    const val ADDED = "omniterm-key-added"
    const val PRESENT = "omniterm-key-present"

    /** Hosts a key is installed on at once. */
    const val PARALLEL_HOSTS = 4
    private const val MAX_COMMENT = 64
    private val BLOB = Regex("[A-Za-z0-9+/]+={0,2}")
    private val SPACE = Regex("\\s+")

    /**
     * POSIX `sh`, with the line on stdin. In the login user's home it makes `.ssh` (private when
     * new) and appends the line, after a line break when the file's last line has none, unless the
     * key is already there, with any comment or options. It changes nothing that already exists.
     */
    val COMMAND = listOf(
        "k=\$(cat) || exit 1",
        "cd || exit 1",
        "umask 077",
        "mkdir -p .ssh || exit 1",
        "f=.ssh/authorized_keys",
        "b=\${k#* }",
        "b=\${b%% *}",
        // An empty key would be found in any file.
        "[ -n \"\$b\" ] || exit 2",
        "if [ -f \"\$f\" ] && grep -qF -- \"\$b\" \"\$f\"; then echo $PRESENT; exit 0; fi",
        "if [ -s \"\$f\" ] && [ -n \"\$(tail -c 1 \"\$f\")\" ]; then echo >> \"\$f\" || exit 1; fi",
        "printf '%s\\n' \"\$k\" >> \"\$f\" || exit 1",
        "echo $ADDED",
    ).joinToString("; ")

    /**
     * [key]'s line for `authorized_keys`: its type, its key and a plain comment (its own, else its
     * name in OmniTerm). Null when [key] holds no public key OmniTerm can vouch for: an unknown type,
     * a key that is not Base64, or one whose contents name another type.
     */
    fun line(key: SshKeyEntity): String? = line(key.publicKey, key.alias)

    fun line(publicKey: String, name: String): String? {
        val parts = publicKey.trim().split(SPACE)
        val type = parts.getOrNull(0) ?: return null
        val blob = parts.getOrNull(1) ?: return null
        if (type !in TYPES || !BLOB.matches(blob)) return null
        val decoded = runCatching { Base64.decode(blob) }.getOrNull() ?: return null
        if (namedType(decoded) != type) return null
        val comment = plain(parts.drop(2).joinToString(" ")).ifEmpty { plain(name) }
        return listOfNotNull(type, blob, comment.ifEmpty { null }).joinToString(" ")
    }

    /** A key on a security key: signing in with it needs a touch, so it is not tried unattended. */
    fun onSecurityKey(key: SshKeyEntity): Boolean = key.keyType.endsWith("-SK", ignoreCase = true)

    sealed interface Outcome {
        /** The line was added. */
        data object Added : Outcome
        /** The key was already in the file; nothing changed. */
        data object AlreadyThere : Outcome
        /** The host ran the command and it failed, with the last thing it printed. */
        data class Failed(val reason: String) : Outcome
        /** The command never ran: the connection or sign-in failed. */
        data class NotReached(val reason: String) : Outcome
    }

    /** What [raw], [COMMAND]'s result as `SshTransport.exec` returns it, says happened. */
    fun outcome(raw: String): Outcome {
        val exit = sshCommandExit(raw) ?: return Outcome.NotReached(raw.removePrefix("SSH Error:").trim())
        val output = sshCommandOutput(raw).trim()
        val last = output.lines().lastOrNull { it.isNotBlank() }?.trim().orEmpty()
        return when {
            exit == 0 && last == ADDED -> Outcome.Added
            exit == 0 && last == PRESENT -> Outcome.AlreadyThere
            else -> Outcome.Failed(last.ifEmpty { "exit $exit" })
        }
    }

    /** The type a key's contents name first: a 32-bit length, then that many bytes. */
    private fun namedType(blob: ByteArray): String? {
        if (blob.size < 4) return null
        val n = ((blob[0].toInt() and 0xff) shl 24) or ((blob[1].toInt() and 0xff) shl 16) or
            ((blob[2].toInt() and 0xff) shl 8) or (blob[3].toInt() and 0xff)
        if (n <= 0 || n > blob.size - 4) return null
        return blob.decodeToString(4, 4 + n)
    }

    /** Letters, digits and `@._+-`, spaces as `-`, at most [MAX_COMMENT]: a comment any file keeps. */
    private fun plain(s: String): String =
        s.trim().replace(SPACE, "-")
            .filter { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "@._+-" }
            .take(MAX_COMMENT)
}
