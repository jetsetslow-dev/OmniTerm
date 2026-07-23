package com.jetsetslow.omniterm.data.ssh

import com.google.common.truth.Truth.assertThat
import com.jcraft.jsch.JSch
import com.jcraft.jsch.ProxyHTTP
import com.jcraft.jsch.ProxySOCKS5
import com.jcraft.jsch.Session
import org.junit.Test

class SshProxyConfigurationTest {
    @Test
    fun httpConnectCredentialsAreAppliedToSessionRoute() {
        val session = sessionWithProxy(credentials("http"))
        val proxy = proxyOf(session)

        assertThat(proxy).isInstanceOf(ProxyHTTP::class.java)
        assertThat(field(proxy, "proxy_host")).isEqualTo("proxy.example")
        assertThat(field(proxy, "proxy_port")).isEqualTo(3128)
        assertThat(field(proxy, "user")).isEqualTo("proxy-user")
        assertThat(field(proxy, "passwd")).isEqualTo("proxy-pass")
    }

    @Test
    fun socks5CredentialsAreAppliedToSessionRoute() {
        val session = sessionWithProxy(credentials("socks5"))
        val proxy = proxyOf(session)

        assertThat(proxy).isInstanceOf(ProxySOCKS5::class.java)
        assertThat(field(proxy, "proxy_host")).isEqualTo("proxy.example")
        assertThat(field(proxy, "proxy_port")).isEqualTo(3128)
        assertThat(field(proxy, "user")).isEqualTo("proxy-user")
        assertThat(field(proxy, "passwd")).isEqualTo("proxy-pass")
    }

    @Test
    fun invalidOrDirectProxySettingsNeverInstallAProxy() {
        assertThat(proxyOf(sessionWithProxy(credentials("none")))).isNull()
        assertThat(proxyOf(sessionWithProxy(credentials("http").copy(proxyHost = "")))).isNull()
        assertThat(proxyOf(sessionWithProxy(credentials("socks5").copy(proxyPort = 0)))).isNull()
    }

    private fun credentials(type: String) = SshCredentials(
        host = "target.example",
        port = 22,
        username = "target-user",
        proxyType = type,
        proxyHost = " proxy.example ",
        proxyPort = 3128,
        proxyUser = "proxy-user",
        proxyPassword = "proxy-pass",
    )

    private fun proxyOf(session: Session): Any? = field(session, "proxy")

    private fun sessionWithProxy(creds: SshCredentials): Session =
        JSch().getSession(creds.username, creds.host, creds.port).also { applyProxy(it, creds) }

    private fun field(instance: Any?, name: String): Any? {
        requireNotNull(instance)
        var type: Class<*>? = instance.javaClass
        while (type != null) {
            val current = type
            val declared = runCatching { current.getDeclaredField(name) }.getOrNull()
            if (declared != null) return declared.apply { isAccessible = true }.get(instance)
            type = current.superclass
        }
        error("${instance.javaClass.name} does not declare field $name")
    }
}
