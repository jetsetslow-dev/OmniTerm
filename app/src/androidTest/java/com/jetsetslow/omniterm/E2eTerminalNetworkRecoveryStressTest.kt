package com.jetsetslow.omniterm

import android.app.Application
import android.app.NotificationManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Network loss and recovery over a persistent (tmux) session plus HTTP, SOCKS5 and SSH-jump
 * interactive sessions. The suite saves its own four hosts on the repository's fixtures, all at
 * `network_host`, the address the phone's own network reaches them at (10.0.2.2 from the emulator),
 * so that losing the network really takes every route away: the lab host (tmux), and internal-a,
 * which only the fixtures' proxy and bastion reach. Run with
 * `./scripts/test-hosts.sh suite E2eTerminalNetworkRecoveryStressTest
 * omniterm_e2e_terminal_network=yes network_host port user pass`.
 */
@RunWith(AndroidJUnit4::class)
class E2eTerminalNetworkRecoveryStressTest {
    @Test
    fun mixedProxyAndTmuxSessionsRecoverAfterRealNetworkLoss() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(E2eArgs.on("omniterm_e2e_terminal_network"))
        val app = instrumentation.targetContext.applicationContext as Application
        val vm = AppViewModel(app)
        val network = E2eArgs.require("network_host")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        var offline: PhoneOffline? = null
        TerminalSessionManager.clearAll()

        // Keep-alive every ten seconds, as a user who wants dead links noticed sets it.
        fun host(name: String, address: String, port: Int, persistent: Boolean = false, proxyType: String = "none", proxyPort: Int = 0) = ServerEntity(
            name = name, host = address, port = port, username = user, authPassword = pass, keepAlive = 10,
            persistentSession = persistent, notes = NOTE,
            proxyType = proxyType, proxyHost = if (proxyType == "none") "" else network, proxyPort = proxyPort,
            proxyUser = if (proxyType == "ssh") user else "", proxyPassword = if (proxyType == "ssh") pass else "",
        )
        val hosts = listOf(
            host(PERSISTENT, network, E2eArgs.get("port")?.toIntOrNull() ?: 2205, persistent = true),
            host(HTTP, INTERNAL, INTERNAL_PORT, proxyType = "http", proxyPort = 8888),
            host("E2E net SOCKS5 Proxy", INTERNAL, INTERNAL_PORT, proxyType = "socks5", proxyPort = 1080),
            host("E2E net SSH Jump", INTERNAL, INTERNAL_PORT, proxyType = "ssh", proxyPort = 2203),
        ).map { E2eLabHosts.save(vm, it).also { saved -> E2eLabHosts.connectOnce(vm, saved) } }

        try {
            vm.navigateTo(Screen.Shell)
            for (host in hosts) {
                vm.selectedServerId = host.id
                vm.connectTerminal()
                await("${host.name} connect", 30_000) {
                    !vm.isTerminalConnecting && vm.activeSessions.any { it.serverId == host.id }
                }
                check(vm.terminalConnectError.isNullOrBlank()) {
                    "${host.name} failed: ${vm.terminalConnectError}"
                }
                val session = requireNotNull(vm.activeSessions.find { it.serverId == host.id })
                vm.attachSession(session.id)
                // Each marker is printed from a format, so the shell's echo of the command never has it.
                vm.pasteText("printf 'BEFORE-%s\\n' ${host.id}\n")
                await("${host.name} initial command", 10_000) {
                    vm.terminalBufferTextFor(session, full = true).contains("BEFORE-${host.id}")
                }
            }

            val persistentHost = hosts.first { it.name == PERSISTENT }
            val persistent = requireNotNull(vm.activeSessions.find { it.serverId == persistentHost.id })
            assertTrue(persistent.persistent)
            vm.attachSession(persistent.id)
            vm.pasteText(
                "printf 'NET-TMUX-%s\\n' START; " +
                    "(i=1; while [ \$i -le 35 ]; do printf 'NET-TMUX-%02d\\n' \"\$i\"; " +
                    "i=\$((i+1)); sleep 1; done; printf 'NET-TMUX-%s\\n' END) &\n",
            )
            await("tmux stream started", 15_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("NET-TMUX-START")
            }

            val ordinary = vm.activeSessions.first { it.serverId == hosts.first { host -> host.name == HTTP }.id }
            vm.enterMultiSsh()
            vm.assignMultiSshPane(1, ordinary.id)
            vm.assignMultiSshPane(2, persistent.id)
            val paneOrder = listOf(vm.multiSshSessionId1, vm.multiSshSessionId2)

            offline = PhoneOffline()
            delay(12_000) // Exceeds the ten-second SSH keepalive interval.
            // Offline, no route can come back: a session that is connected now never lost its network.
            val stillUp = vm.activeSessions.filter { it.isConnected && !it.reconnecting }.map { it.serverId }
            assertTrue(
                "Still connected with the phone offline: ${hosts.filter { it.id in stillUp }.map { it.name }}",
                stillUp.isEmpty(),
            )
            offline?.close()
            offline = null

            // Sessions retain their identity and pane attachment while their transports recover.
            await("all terminal transports recovered", 120_000) {
                vm.activeSessions.size == hosts.size &&
                    vm.activeSessions.all { it.isConnected && !it.reconnecting }
            }
            assertEquals(paneOrder, listOf(vm.multiSshSessionId1, vm.multiSshSessionId2))
            assertTrue(
                "No transport observed the real network interruption",
                vm.activeSessions.any {
                    vm.terminalBufferTextFor(it, full = true).contains("-- reconnected --")
                },
            )

            // Every direct/proxied route must accept fresh input after recovery. Reuse the same
            // ShellSession objects so this also rejects silent replacement or duplicate sessions.
            vm.exitMultiSsh()
            for (host in hosts) {
                val session = requireNotNull(vm.activeSessions.find { it.serverId == host.id })
                vm.attachSession(session.id)
                vm.pasteText("printf 'AFTER-%s\\n' ${host.id}\n")
                await("${host.name} post-recovery command", 15_000) {
                    vm.terminalBufferTextFor(session, full = true).contains("AFTER-${host.id}")
                }
            }
            await("tmux output survived the network loss", 45_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("NET-TMUX-END")
            }

            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal network cleanup", 30_000) { vm.activeSessions.isEmpty() }
            await("terminal notification cleanup", 15_000) { activeTerminalNotifications() == 0 }
        } finally {
            offline?.close()
            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal network cleanup", 30_000) { vm.activeSessions.isEmpty() }
            TerminalSessionManager.clearAll()
            hosts.forEach { E2eLabHosts.remove(vm, it.name) }
        }
    }

    private fun activeTerminalNotifications(): Int {
        val manager = InstrumentationRegistry.getInstrumentation().targetContext
            .getSystemService(NotificationManager::class.java)
        return manager.activeNotifications.count {
            it.notification.channelId == SessionService.CHANNEL_ID
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

    private companion object {
        const val HTTP = "E2E net HTTP Proxy"
        const val PERSISTENT = "E2E net Persistent"
        const val NOTE = "E2E terminal network recovery"
        // Reachable only through the fixtures' proxy (HTTP :8888, SOCKS5 :1080) and bastion (:2203).
        const val INTERNAL = "omniterm-test-internal-a"
        const val INTERNAL_PORT = 2222
    }
}
