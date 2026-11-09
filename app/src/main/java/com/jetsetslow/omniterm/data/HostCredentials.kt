package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.ssh.SshCredentials

/**
 * A host's SSH credentials from its saved settings, its key or credential profile, and its proxy,
 * read straight from the database: the one place both the app's screens and its background runs
 * (automation) build them.
 */
object HostCredentials {
    /**
     * [srv]'s credentials. [posixShell] says the host is known to have a Unix shell, so the app's
     * own commands can go to `sh`; a command the user wrote goes to the login shell (false).
     */
    /** The user [srv] signs in as: its credential profile's, when it uses [profile], else its own. */
    fun loginName(srv: ServerEntity, profile: CredentialProfileEntity?): String =
        profile?.takeIf { srv.authType == "profile" && it.id == srv.authProfileId }?.username ?: srv.username

    suspend fun build(repository: AppRepository, srv: ServerEntity, posixShell: Boolean): SshCredentials {
        // Read keys and profiles from the database, never from a screen's flow: with no screen
        // collecting it, such a flow is still empty, and the private key was silently dropped,
        // which surfaced as "invalid credentials" for key and profile sign-in.
        val allKeys = repository.getAllKeys()
        val profile = if (srv.authType == "profile") repository.getAllProfiles().find { it.id == srv.authProfileId } else null
        val user = loginName(srv, profile)
        var pass: String? = srv.authPassword
        var key: SshKeyEntity? = null
        when (srv.authType) {
            "key" -> key = allKeys.find { it.alias == srv.authKeyAlias }
            "profile" -> profile?.let { p ->
                if (p.authType == "password") pass = p.password
                else key = allKeys.find { it.alias == p.keyAlias }
            }
        }
        val proxyKey = srv.proxyKeyAlias?.let { a -> allKeys.find { it.alias == a } }
        return SshCredentials(
            srv.host, srv.port, user, pass, key?.privateKey,
            proxyType = srv.proxyType,
            proxyHost = srv.proxyHost,
            proxyPort = srv.proxyPort,
            proxyUser = srv.proxyUser,
            proxyPassword = srv.proxyPassword,
            proxyKeyPem = proxyKey?.privateKey,
            certificate = key?.certificate,
            proxyCertificate = proxyKey?.certificate,
            keepAliveSeconds = srv.keepAlive,
            compression = srv.sshCompression,
            agentForwarding = srv.agentForwarding,
            posixShell = posixShell,
        )
    }
}
