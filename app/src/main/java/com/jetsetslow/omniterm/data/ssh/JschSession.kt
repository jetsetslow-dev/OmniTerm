package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSch
import com.jcraft.jsch.ProxyHTTP
import com.jcraft.jsch.ProxySOCKS5
import com.jcraft.jsch.Session
import java.util.Properties

/**
 * Register a pasted private key with [jsch].
 *
 * Old JSch throws `JSchException("invalid privatekey: " + byte[])` on a key it can't parse —
 * the byte[] renders as `[B@1a2b3c`, which is what leaked into the UI. We normalise the key,
 * catch the parse failure, and rethrow a human-readable message instead.
 */
internal fun addPrivateKeyIdentity(jsch: JSch, name: String, privateKey: String, passphrase: String?) {
    val trimmed = privateKey.trim()

    // Wrong half of the pair: a public key was pasted into the private-key field.
    if (trimmed.startsWith("ssh-rsa ") || trimmed.startsWith("ssh-ed25519 ") ||
        trimmed.startsWith("ecdsa-sha2-") || trimmed.startsWith("ssh-dss ")
    ) {
        throw IllegalArgumentException(
            "That looks like a public key. Paste the matching PRIVATE key — the file without " +
                "the .pub extension, starting with \"-----BEGIN ... PRIVATE KEY-----\".",
        )
    }

    if (!trimmed.contains("PRIVATE KEY")) {
        throw IllegalArgumentException(
            "That doesn't look like a private key. Paste the full key including the " +
                "\"-----BEGIN ... PRIVATE KEY-----\" and \"-----END ... PRIVATE KEY-----\" lines.",
        )
    }

    // Unify line endings and guarantee a trailing newline (PEM parsers are picky about it, and
    // pasting on Android often introduces CRLF or strips the final newline).
    val normalized = (trimmed.replace("\r\n", "\n").replace("\r", "\n") + "\n")
        .toByteArray(Charsets.UTF_8)
    try {
        jsch.addIdentity(
            name,
            normalized,
            null,
            passphrase?.takeIf { it.isNotBlank() }?.toByteArray(Charsets.UTF_8),
        )
    } catch (e: Exception) {
        // Never leak JSch's raw "invalid privatekey: [B@…" byte-array dump to the UI.
        val detail = e.message?.takeUnless { it.contains("[B@") }
        throw IllegalArgumentException(
            detail?.let { "Invalid private key: $it" }
                ?: "Invalid private key. If it has a passphrase, enter it; otherwise re-copy the full key.",
            e,
        )
    }
}

/** Shared JSch [Session] factory used by both the shell transport and the SFTP client. */
internal fun buildJschSession(creds: SshCredentials): Session {
    val jsch = JSch().apply {
        setHostKeyRepository(SshHostKeyTrust.repository())
    }
    if (!creds.privateKeyPem.isNullOrBlank()) {
        addPrivateKeyIdentity(
            jsch,
            "key_${creds.host}_${creds.username}",
            creds.privateKeyPem,
            creds.passphrase,
        )
    }
    val session = jsch.getSession(creds.username, creds.host, creds.port)
    if (!creds.password.isNullOrEmpty()) session.setPassword(creds.password)
    applyProxy(session, creds)
    session.setConfig(Properties().apply {
        put("StrictHostKeyChecking", "yes")
        put(
            "PreferredAuthentications",
            if (!creds.privateKeyPem.isNullOrBlank()) {
                "publickey,keyboard-interactive,password"
            } else {
                "keyboard-interactive,password"
            },
        )
        put(
            "compression.s2c",
            if (creds.compression) "zlib@openssh.com,zlib,none" else "none",
        )
        put(
            "compression.c2s",
            if (creds.compression) "zlib@openssh.com,zlib,none" else "none",
        )
    })
    // Heartbeat so a dead link (e.g. WiFi turned off mid-session) is detected and the session
    // disconnects — which unblocks the shell reader so the app can auto-reconnect. On mobile,
    // networks drop often, so probe fairly aggressively: ~10s × 3 ≈ 30s to notice a dead link
    // rather than the previous ~90s.
    val keepAliveMs = creds.keepAliveSeconds.coerceIn(0, 3_600)
        .let { seconds -> seconds * 1_000 }
    session.serverAliveInterval = keepAliveMs
    session.serverAliveCountMax = if (keepAliveMs > 0) 3 else 0
    session.setConfig("TCPKeepAlive", "yes")
    return session
}

/**
 * Apply an HTTP or SOCKS5 proxy to [session] before it connects. This is transparent to the
 * session pool: the proxy is just part of how the connection is dialled, so pooled exec/stream
 * calls reuse the proxied connection like any other.
 *
 * SSH jump hosts ("ssh") are NOT handled here — they require a separate live jump session and a
 * local port-forward (see [buildJumpedJschSession]).
 */
private fun applyProxy(session: Session, creds: SshCredentials) {
    val host = creds.proxyHost.trim()
    if (host.isEmpty() || creds.proxyPort <= 0) return
    when (creds.proxyType) {
        "http" -> session.setProxy(ProxyHTTP(host, creds.proxyPort).apply {
            if (creds.proxyUser.isNotEmpty()) setUserPasswd(creds.proxyUser, creds.proxyPassword)
        })
        "socks5" -> session.setProxy(ProxySOCKS5(host, creds.proxyPort).apply {
            if (creds.proxyUser.isNotEmpty()) setUserPasswd(creds.proxyUser, creds.proxyPassword)
        })
    }
}

/** A target [Session] reached via an SSH jump host, paired with the jump [Session] that tunnels it. */
internal class JumpedSession(val target: Session, private val jump: Session) {
    /** Tear down the target then the jump session — order matters so the forward isn't left dangling. */
    fun disconnect() {
        runCatching { target.disconnect() }
        runCatching { jump.disconnect() }
    }
}

/**
 * JSch normally verifies a host key against the socket endpoint. A jump-host target is dialled
 * through an ephemeral localhost forward, so that endpoint is unstable and must never become the
 * trust identity. Match JSch's direct-session naming instead: the bare host on port 22 and the
 * bracketed host/port form for non-standard ports.
 */
internal fun logicalHostKeyAlias(host: String, port: Int): String =
    if (port == 22) host else "[$host]:$port"

internal fun pinJumpTargetToLogicalHost(session: Session, host: String, port: Int) {
    session.setHostKeyAlias(logicalHostKeyAlias(host, port))
}

/**
 * Build (but do not connect) a target [Session] that reaches [creds.host]:[creds.port] through an
 * already-connected SSH jump host. The returned [JumpedSession] owns the jump session and MUST be
 * disconnected via [JumpedSession.disconnect] when the target session is torn down, otherwise the
 * tunnel leaks.
 *
 * Limitation: jump-host sessions are deliberately NOT pooled. The pool keys on the target creds and
 * has no place to store/close the paired jump session, so wiring it in cleanly would be invasive.
 * Interactive shells and SFTP (which already build un-pooled sessions) get full jump support; the
 * pooled one-shot exec/stream path falls back to a direct connection for jump hosts (see
 * JschSshTransport.execOnce / execStreamOnce comments). HTTP/SOCKS5 proxies work everywhere.
 */
internal fun buildJumpedJschSession(creds: SshCredentials, connectTimeoutMs: Int): JumpedSession {
    val jumpJsch = JSch().apply {
        setHostKeyRepository(SshHostKeyTrust.repository())
    }
    val jumpUser = creds.proxyUser.ifEmpty { creds.username }
    if (!creds.proxyKeyPem.isNullOrBlank()) {
        addPrivateKeyIdentity(
            jumpJsch,
            "jump_${creds.proxyHost.trim()}_$jumpUser",
            creds.proxyKeyPem,
            null,
        )
    }
    val jump = jumpJsch.getSession(jumpUser, creds.proxyHost.trim(), creds.proxyPort)
    if (creds.proxyPassword.isNotEmpty()) jump.setPassword(creds.proxyPassword)
    jump.setConfig(Properties().apply {
        put("StrictHostKeyChecking", "yes")
        put(
            "PreferredAuthentications",
            // Keyed off the JUMP host's key, not the target's — only identities added to
            // jumpJsch above can satisfy publickey here.
            if (!creds.proxyKeyPem.isNullOrBlank()) {
                "publickey,keyboard-interactive,password"
            } else {
                "keyboard-interactive,password"
            },
        )
    })
    val jumpKeepAliveMs = creds.keepAliveSeconds.coerceIn(0, 3_600) * 1_000
    jump.serverAliveInterval = jumpKeepAliveMs
    jump.serverAliveCountMax = if (jumpKeepAliveMs > 0) 3 else 0
    jump.setConfig("TCPKeepAlive", "yes")
    jump.connect(connectTimeoutMs)

    // Forward a local ephemeral port to the real target through the jump host, then connect the
    // target session to that local endpoint.
    val lport = try {
        jump.setPortForwardingL(0, creds.host, creds.port)
    } catch (e: Throwable) {
        runCatching { jump.disconnect() }
        throw e
    }

    return try {
        val targetCreds = creds.copy(
            host = "127.0.0.1",
            port = lport,
            proxyType = "none",
        )
        val target = buildJschSession(targetCreds)
        // Session.setHostKeyAlias is the JSch API that checkHost() actually reads. Setting a
        // config entry named HostKeyAlias leaves the alias null and pins 127.0.0.1:<random-port>.
        pinJumpTargetToLogicalHost(target, creds.host, creds.port)
        JumpedSession(target, jump)
    } catch (e: Throwable) {
        runCatching { jump.delPortForwardingL(lport) }
        runCatching { jump.disconnect() }
        throw e
    }
}
