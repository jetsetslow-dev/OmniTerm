package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.WolTargetEntity
import com.jetsetslow.omniterm.ui.HostSort
import com.jetsetslow.omniterm.ui.sortHosts
import com.jetsetslow.omniterm.ui.sshCommandFor
import com.jetsetslow.omniterm.ui.wolTargetFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Hosts tab's sorting, copied SSH command and Wake-on-LAN match. */
class HostListTest {

    private fun host(id: Int, name: String, status: String = "online", latency: Int = 10, host: String = "$name.lan") =
        ServerEntity(id = id, name = name, host = host, username = "admin", status = status, lastLatency = latency)

    // Loaded by name, as the database returns them.
    private val hosts = listOf(
        host(1, "alpha", status = "offline"),
        host(2, "bravo", latency = 40),
        host(3, "charlie", status = "connecting"),
        host(4, "delta", latency = 5),
    )
    private val health = mapOf(1 to -1, 2 to 80, 3 to 30, 4 to 95)

    private fun order(sort: HostSort) = sortHosts(hosts, sort) { health.getValue(it.id) }.map { it.name }

    @Test
    fun `name keeps the loaded order`() {
        assertEquals(listOf("alpha", "bravo", "charlie", "delta"), order(HostSort.Name))
    }

    @Test
    fun `status puts online hosts first and keeps names in order within each`() {
        assertEquals(listOf("bravo", "delta", "charlie", "alpha"), order(HostSort.Status))
    }

    @Test
    fun `health puts the lowest score first and unscored hosts last`() {
        assertEquals(listOf("charlie", "bravo", "delta", "alpha"), order(HostSort.Health))
    }

    @Test
    fun `latency is fastest first with hosts that are not online last`() {
        assertEquals(listOf("delta", "bravo", "alpha", "charlie"), order(HostSort.Latency))
    }

    @Test
    fun `an unknown saved sort falls back to name`() {
        assertEquals(HostSort.Name, HostSort.fromSetting("bogus"))
        assertEquals(HostSort.Health, HostSort.fromSetting("health"))
    }

    @Test
    fun `the ssh command names the port only when it is not 22`() {
        assertEquals("ssh admin@nas.lan", sshCommandFor(host(1, "nas"), "admin"))
        assertEquals("ssh -p 2222 root@nas.lan", sshCommandFor(host(1, "nas").copy(port = 2222), "root"))
    }

    @Test
    fun `the ssh command goes through the jump host or proxy`() {
        val jump = host(1, "db").copy(proxyType = "ssh", proxyHost = "bastion", proxyPort = 2200, proxyUser = "ops")
        assertEquals("ssh -J ops@bastion:2200 admin@db.lan", sshCommandFor(jump, "admin"))
        val socks = host(1, "db").copy(proxyType = "socks5", proxyHost = "fe80::1", proxyPort = 1080)
        assertEquals("ssh -o 'ProxyCommand=nc -X 5 -x [fe80::1]:1080 %h %p' admin@db.lan", sshCommandFor(socks, "admin"))
    }

    @Test
    fun `a wake target matches the host by address only`() {
        val targets = listOf(
            WolTargetEntity(id = 1, name = "nas", macAddress = "00:11:22:33:44:55", ipAddress = ""),
            WolTargetEntity(id = 2, name = "desk", macAddress = "00:11:22:33:44:66", ipAddress = " 192.168.1.20 "),
        )
        assertEquals(2, wolTargetFor(host(1, "desk", host = "192.168.1.20"), targets)?.id)
        // A target without an address never matches, even by name.
        assertNull(wolTargetFor(host(1, "nas", host = "nas.lan"), targets))
    }
}
