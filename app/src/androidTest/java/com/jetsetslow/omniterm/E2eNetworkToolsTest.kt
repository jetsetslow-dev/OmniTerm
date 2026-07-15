package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in physical-device integration checks for every executable Network Tools path. */
@RunWith(AndroidJUnit4::class)
class E2eNetworkToolsTest {
    @Test
    fun exerciseEveryNetworkToolAgainstDisposableLab() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_network") == "yes")
        val host = requireNotNull(args.getString("host")?.takeIf(String::isNotBlank))
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val vm = AppViewModel(app)

        vm.startPing(host, 2)
        await("ping", 15_000) { !vm.pingRunning }
        assertTrue(vm.pingLines.joinToString("\n"), vm.pingLines.any { it.contains("bytes from", true) })

        vm.startTraceroute(host)
        await("traceroute", 75_000) { !vm.tracerouteRunning }
        assertTrue(vm.tracerouteLines.joinToString("\n"), vm.tracerouteLines.isNotEmpty())

        vm.portScannerTarget = host
        vm.portScannerRange = "21,22,445,1080,8080,8081,8888,65500,not-a-port,22"
        vm.runPortScanner()
        await("port scan", 20_000) { !vm.isPortScannerScanning && vm.portScannerResults.isNotEmpty() }
        val ports = vm.portScannerResults.toMap()
        listOf(21, 22, 445, 1080, 8080, 8081, 8888).forEach { port ->
            assertTrue("$port was ${ports[port]}", ports[port]?.contains("Open") == true)
        }
        assertEquals("Closed", ports[65500])
        assertEquals(8, ports.size)

        vm.dnsLookupTarget = "example.com"
        vm.dnsLookupType = "A"
        vm.runDnsLookup()
        await("DNS", 20_000) { !vm.isDnsLookupRunning }
        assertTrue(vm.dnsLookupError.orEmpty(), vm.dnsLookupResults.isNotEmpty())

        vm.whoisTarget = "example.com"
        vm.runWhois()
        await("WHOIS", 25_000) { !vm.isWhoisRunning }
        assertTrue(
            "WHOIS produced neither data nor an actionable error",
            vm.whoisResult.isNotBlank() || vm.whoisError?.contains("failed", true) == true,
        )

        vm.speedTestUrl = "https://speed.cloudflare.com/__down?bytes=1048576"
        vm.runSpeedTest()
        await("speed test", 30_000) { !vm.isSpeedTestRunning }
        assertTrue(vm.speedTestError.orEmpty(), vm.speedTestBytes > 0)
        assertNotNull(vm.speedTestMbps)
        assertNotNull(vm.speedTestLatencyMs)

        vm.refreshLanScan(force = true)
        assertTrue("LAN scan did not find $host", vm.hostScanResults.any { it.ip == host && it.isOnline })

        val repository = AppRepository(AppDatabase.getDatabase(app))
        val tunnels = repository.getAllPortForwards().filter { it.name.startsWith("E2E") }
        assertEquals(2, tunnels.size)
        try {
            tunnels.forEach { tunnel ->
                vm.startTunnel(tunnel)
                await("tunnel ${tunnel.kind}", 20_000) { !vm.isTunnelBusy(tunnel.id) }
                assertTrue(vm.tunnelErrors[tunnel.id].orEmpty(), vm.isTunnelActive(tunnel.id))
                val response = if (tunnel.kind == "dynamic") {
                    httpThroughSocks5(tunnel.bindPort)
                } else {
                    httpThroughLocalForward(tunnel.bindPort)
                }
                assertTrue(response, response.startsWith("HTTP/1.1 200") || response.startsWith("HTTP/1.0 200"))
            }
        } finally {
            tunnels.forEach { vm.stopTunnel(it.id) }
            vm.stopPing()
            vm.stopTraceroute()
            vm.cancelSpeedTest()
        }
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                while (!predicate()) delay(100)
            }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", timeout)
        }
    }

    private fun httpThroughLocalForward(port: Int): String =
        java.net.Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 10_000
            socket.getOutputStream().write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".toByteArray())
            socket.getInputStream().bufferedReader().readLine().orEmpty()
        }

    private fun httpThroughSocks5(port: Int): String =
        java.net.Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 10_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            output.write(byteArrayOf(5, 1, 0))
            output.flush()
            assertEquals(5, input.read())
            assertEquals(0, input.read())
            output.write(byteArrayOf(5, 1, 0, 1, 127, 0, 0, 1, 0x1f, 0x90.toByte()))
            output.flush()
            val reply = ByteArray(10)
            var offset = 0
            while (offset < reply.size) {
                val read = input.read(reply, offset, reply.size - offset)
                check(read > 0) { "SOCKS proxy closed during CONNECT" }
                offset += read
            }
            assertEquals("SOCKS CONNECT failed", 0, reply[1].toInt())
            output.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".toByteArray())
            output.flush()
            input.bufferedReader().readLine().orEmpty()
        }
}
