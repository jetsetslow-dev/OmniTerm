package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.Identity
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
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
    if (looksLikePublicKey(trimmed)) {
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

    val normalized = normalizedKey(trimmed)
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

/** True when [text] is a public key line (any type, security keys and certificates included). */
internal fun looksLikePublicKey(text: String): Boolean =
    PUBLIC_KEY_PREFIXES.any { text.startsWith(it) } && !text.contains("PRIVATE KEY")

private val PUBLIC_KEY_PREFIXES = listOf("ssh-rsa", "ssh-ed25519", "ssh-dss", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-", "rsa-sha2-")

/**
 * [key] with unified line endings and a trailing newline: PEM parsers are picky about it, and
 * pasting on Android often introduces CRLF or strips the final newline.
 */
private fun normalizedKey(key: String): ByteArray =
    (key.trim().replace("\r\n", "\n").replace("\r", "\n") + "\n").toByteArray(Charsets.UTF_8)

/**
 * Register a saved key with [jsch]: a key file, or a key on a security key, and its [certificate]
 * when it has one. Returns the public key algorithms beyond JSch's defaults the session must offer.
 *
 * A security key signs only when [ask] can have the user touch it; [signIn] records when nobody
 * could. A certificate goes beside the bare key, which still signs in where the key itself is in
 * `authorized_keys`.
 */
internal fun addKeyIdentities(
    jsch: JSch,
    name: String,
    privateKey: String,
    passphrase: String?,
    certificate: String?,
    destination: String,
    ask: InteractiveAuth?,
    signIn: KeyboardInteractiveUserInfo,
): List<String> {
    val trimmed = privateKey.trim()
    val securityKeyType = OpenSshKeyFile.keyType(trimmed)?.let(SkKeyType::of)
    val cert = certificate?.takeIf { it.isNotBlank() }?.let { runCatching { SshCertificate.parse(it) }.getOrNull() }
    val algorithms = mutableListOf<String>()
    val inner: Identity = if (securityKeyType != null) {
        val key = try {
            SkKey.fromFile(OpenSshKeyFile.read(trimmed, passphrase))
        } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException("Invalid security key file: ${e.message}", e)
        }
        SecurityKeyIdentity(key, name, destination, ask, signIn).also {
            jsch.addIdentity(it, null)
            algorithms += securityKeyType.sshName
        }
    } else {
        addPrivateKeyIdentity(jsch, name, trimmed, passphrase)
        if (cert == null) return algorithms
        val keyPair = KeyPair.load(jsch, normalizedKey(trimmed), null)
        if (keyPair.isEncrypted && !keyPair.decrypt(passphrase?.toByteArray(Charsets.UTF_8))) return algorithms
        KeyPairIdentity(keyPair, name)
    }
    if (cert != null && SshCertificate.mismatch(cert, inner.publicKeyBlob) == null) {
        val identity = CertificateIdentity(inner, cert)
        jsch.addIdentity(identity, null)
        algorithms += identity.algName
    }
    return algorithms
}

/** [extra] offered before JSch's own public key algorithms, for certificates and security keys. */
private fun acceptedAlgorithms(extra: List<String>): String =
    (extra + JSch.getConfig("PubkeyAcceptedAlgorithms").split(",")).distinct().joinToString(",")

/**
 * Shared JSch [Session] factory used by both the shell transport and the SFTP client.
 *
 * [interactiveAuth] answers the host's sign-in questions beyond the saved password (a one-time
 * code); null for background work, which must never ask. See [KeyboardInteractiveUserInfo].
 * [hostKeys] is the app's pinned store; only the live sign-in test passes its own.
 */
internal fun buildJschSession(
    creds: SshCredentials,
    interactiveAuth: InteractiveAuth? = null,
    hostKeys: HostKeyRepository = SshHostKeyTrust.repository(),
): Session {
    val jsch = JSch().apply {
        setHostKeyRepository(hostKeys)
    }
    val signIn = KeyboardInteractiveUserInfo(creds.password, interactiveAuth)
    val algorithms = if (!creds.privateKeyPem.isNullOrBlank()) {
        addKeyIdentities(
            jsch,
            "key_${creds.host}_${creds.username}",
            creds.privateKeyPem,
            creds.passphrase,
            creds.certificate,
            "${creds.username}@${creds.host}",
            interactiveAuth,
            signIn,
        )
    } else {
        emptyList()
    }
    val session = jsch.getSession(creds.username, creds.host, creds.port)
    if (!creds.password.isNullOrEmpty()) session.setPassword(creds.password)
    session.userInfo = signIn
    applyProxy(session, creds)
    session.setConfig(Properties().apply {
        put("StrictHostKeyChecking", "yes")
        if (algorithms.isNotEmpty()) put("PubkeyAcceptedAlgorithms", acceptedAlgorithms(algorithms))
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
internal fun applyProxy(session: Session, creds: SshCredentials) {
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
internal fun buildJumpedJschSession(
    creds: SshCredentials,
    connectTimeoutMs: Int,
    interactiveAuth: InteractiveAuth? = null,
): JumpedSession {
    val jumpJsch = JSch().apply {
        setHostKeyRepository(SshHostKeyTrust.repository())
    }
    val jumpUser = creds.proxyUser.ifEmpty { creds.username }
    // A bastion may ask for its own one-time code, or its own security key's touch.
    val jumpSignIn = KeyboardInteractiveUserInfo(creds.proxyPassword, interactiveAuth)
    val jumpAlgorithms = if (!creds.proxyKeyPem.isNullOrBlank()) {
        addKeyIdentities(
            jumpJsch,
            "jump_${creds.proxyHost.trim()}_$jumpUser",
            creds.proxyKeyPem,
            null,
            creds.proxyCertificate,
            "$jumpUser@${creds.proxyHost.trim()}",
            interactiveAuth,
            jumpSignIn,
        )
    } else {
        emptyList()
    }
    val jump = jumpJsch.getSession(jumpUser, creds.proxyHost.trim(), creds.proxyPort)
    if (creds.proxyPassword.isNotEmpty()) jump.setPassword(creds.proxyPassword)
    jump.userInfo = jumpSignIn
    jump.setConfig(Properties().apply {
        put("StrictHostKeyChecking", "yes")
        if (jumpAlgorithms.isNotEmpty()) put("PubkeyAcceptedAlgorithms", acceptedAlgorithms(jumpAlgorithms))
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
        val target = buildJschSession(targetCreds, interactiveAuth)
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
