package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession

/** Hosts that answer nothing: for ViewModel tests whose hosts only need to exist. */
internal class QuietHosts : SshTransport {
    override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

    override suspend fun execStream(
        creds: SshCredentials,
        command: String,
        stdin: String?,
        onChunk: suspend (String) -> Unit,
    ): String = ""

    override suspend fun testConnection(creds: SshCredentials): String? = null

    override suspend fun openShell(
        creds: SshCredentials,
        cols: Int,
        rows: Int,
        onPhaseChange: ((String) -> Unit)?,
    ): TerminalSession = error("No shell is opened in these tests")
}
