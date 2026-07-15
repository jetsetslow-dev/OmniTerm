package com.jetsetslow.omniterm

import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.PortForwardEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.StackRegistryEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Opt-in physical-device lab seeding. Normal connected-test and CI runs skip this test.
 * Secrets arrive only through instrumentation arguments and are encrypted by [AppRepository].
 */
@RunWith(AndroidJUnit4::class)
class E2eLabSeedTest {
    @Test
    fun seedDisposablePhysicalDeviceLab() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_seed") == "yes")

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            "E2E lab seeding is restricted to debuggable builds"
        }

        val host = requireArg(args.getString("host"), "host")
        val username = requireArg(args.getString("username"), "username")
        val password = requireArg(args.getString("password"), "password")
        val labPassword = requireArg(args.getString("lab_password"), "lab_password")
        val proxyPassword = requireArg(args.getString("proxy_password"), "proxy_password")

        val repository = AppRepository(AppDatabase.getDatabase(context))
        repository.getAllServers()
            .filter { it.name.startsWith(PREFIX) }
            .forEach { repository.deleteServerAndDependents(it.id) }
        repository.getAllNetworkShares()
            .filter { it.name.startsWith(PREFIX) }
            .forEach { repository.deleteNetworkShare(it) }

        suspend fun server(
            suffix: String,
            persistent: Boolean = false,
            proxyType: String = "none",
            proxyPort: Int = 0,
            proxyUser: String = "",
            proxySecret: String = "",
        ): Int = repository.insertServer(
            ServerEntity(
                name = "$PREFIX $suffix",
                host = host,
                username = username,
                groupName = "E2E Lab",
                authPassword = password,
                sudoPassword = password,
                notes = "Disposable physical-device test fixture",
                keepAlive = 10,
                persistentSession = persistent,
                proxyType = proxyType,
                proxyHost = if (proxyType == "none") "" else host,
                proxyPort = proxyPort,
                proxyUser = proxyUser,
                proxyPassword = proxySecret,
            )
        ).toInt()

        val directId = server("Foreground Demo")
        server("Split Persistent", persistent = true)
        server("HTTP Proxy", proxyType = "http", proxyPort = 8888, proxyUser = PROXY_USER, proxySecret = proxyPassword)
        server("SOCKS5 Proxy", proxyType = "socks5", proxyPort = 1080, proxyUser = PROXY_USER, proxySecret = proxyPassword)
        server("SSH Jump", proxyType = "ssh", proxyPort = 22, proxyUser = username, proxySecret = password)
        server("Broken Proxy", proxyType = "http", proxyPort = 65500, proxyUser = PROXY_USER, proxySecret = "deliberately-wrong")

        listOf(
            NetworkShareEntity(name = "$PREFIX SMB", protocol = "SMB", address = host, port = 445, sharePath = "omniterm-e2e", workgroup = "WORKGROUP", username = LAB_USER, password = labPassword, anonymous = false),
            NetworkShareEntity(name = "$PREFIX FTP", protocol = "FTP", address = host, port = 21, sharePath = "/", username = LAB_USER, password = labPassword, anonymous = false),
            NetworkShareEntity(name = "$PREFIX SFTP", protocol = "SFTP", address = host, port = 22, sharePath = "/", username = LAB_USER, password = labPassword, anonymous = false),
            NetworkShareEntity(name = "$PREFIX WebDAV", protocol = "WEBDAV", address = host, port = 8081, sharePath = "/dav", username = LAB_USER, password = labPassword, anonymous = false, useHttps = false),
        ).forEach { repository.insertNetworkShare(it) }

        repository.insertPortForward(PortForwardEntity(serverId = directId, name = "$PREFIX Local HTTP", kind = "local", bindPort = 19080, destHost = "127.0.0.1", destPort = 8080))
        repository.insertPortForward(PortForwardEntity(serverId = directId, name = "$PREFIX Dynamic SOCKS", kind = "dynamic", bindPort = 19081))

        val corpusRoot = "/home/$username/omniterm-e2e/corpus"
        repository.upsertStacks(
            listOf(
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-anchors", workingDir = "$corpusRoot/01-anchors-comments", configFiles = "$corpusRoot/01-anchors-comments/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-custom-build", workingDir = "$corpusRoot/02-custom-build", configFiles = "$corpusRoot/02-custom-build/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "podman", project = "omniterm-podman", workingDir = "$corpusRoot/03-podman", configFiles = "$corpusRoot/03-podman/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-top-first", workingDir = "$corpusRoot/04-top-level-first", configFiles = "$corpusRoot/04-top-level-first/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-malformed", workingDir = "$corpusRoot/05-malformed", configFiles = "$corpusRoot/05-malformed/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-edge-scalars", workingDir = "$corpusRoot/06-edge-scalars", configFiles = "$corpusRoot/06-edge-scalars/compose.yml"),
                StackRegistryEntity(serverId = directId, runtime = "docker", project = "omniterm-large-stack", workingDir = "$corpusRoot/07-large-stack", configFiles = "$corpusRoot/07-large-stack/compose.yml"),
            )
        )

        // Screen capture is needed for the sanitized Play declaration video. The normal default is
        // secure; only this explicit disposable debug seed opts out.
        repository.insertSetting("flag_secure", "false")
        repository.insertSetting("keep_screen_on", "true")
        repository.insertSetting("background_keep_alive", "true")

        assertEquals(6, repository.getAllServers().count { it.name.startsWith(PREFIX) })
        assertEquals(4, repository.getAllNetworkShares().count { it.name.startsWith(PREFIX) })
    }

    private fun requireArg(value: String?, name: String): String =
        requireNotNull(value?.takeIf { it.isNotBlank() }) { "Missing instrumentation argument: $name" }

    private companion object {
        const val PREFIX = "E2E"
        const val LAB_USER = "omnitermlab"
        const val PROXY_USER = "omnitermproxy"
    }
}
