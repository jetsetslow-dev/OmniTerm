package com.jetsetslow.omniterm

import android.app.Application
import android.app.NotificationManager
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
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

/** Wi-Fi loss/recovery over direct tmux plus HTTP, SOCKS5, and SSH-jump interactive sessions. */
@RunWith(AndroidJUnit4::class)
class E2eTerminalNetworkRecoveryStressTest {
    @Test
    fun mixedProxyAndTmuxSessionsRecoverAfterRealWifiLoss() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(
            InstrumentationRegistry.getArguments().getString("omniterm_e2e_terminal_network") == "yes",
        )
        val app = instrumentation.targetContext.applicationContext as Application
        val vm = AppViewModel(app)
        val originalWifi = shellOutput("settings get global wifi_on").trim()
        TerminalSessionManager.clearAll()

        await("seeded proxy terminal profiles", 15_000) {
            HOSTS.all { name -> vm.servers.value.any { it.name == name } }
        }
        val hosts = HOSTS.map { name -> requireNotNull(vm.servers.value.find { it.name == name }) }

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
                vm.pasteText("printf 'BEFORE-${host.id}\\n'\n")
                await("${host.name} initial command", 10_000) {
                    vm.terminalBufferTextFor(session, full = true).contains("BEFORE-${host.id}")
                }
            }

            val persistentHost = hosts.first { it.name == PERSISTENT }
            val persistent = requireNotNull(vm.activeSessions.find { it.serverId == persistentHost.id })
            assertTrue(persistent.persistent)
            vm.attachSession(persistent.id)
            vm.pasteText(
                "printf 'WIFI-TMUX-START\\n'; " +
                    "(i=1; while [ \$i -le 35 ]; do printf 'WIFI-TMUX-%02d\\n' \"\$i\"; " +
                    "i=\$((i+1)); sleep 1; done; printf 'WIFI-TMUX-END\\n') &\n",
            )
            await("tmux stream started", 15_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("WIFI-TMUX-START")
            }

            val ordinary = vm.activeSessions.first { it.serverId == hosts.first { host -> host.name == HTTP }.id }
            vm.enterMultiSsh()
            vm.assignMultiSshPane(1, ordinary.id)
            vm.assignMultiSshPane(2, persistent.id)
            val paneOrder = listOf(vm.multiSshSessionId1, vm.multiSshSessionId2)

            instrumentation.uiAutomation.executeShellCommand("svc wifi disable").close()
            await("Wi-Fi disabled", 10_000) { shellOutput("settings get global wifi_on").trim() == "0" }
            delay(12_000) // Exceeds the seeded ten-second SSH keepalive interval.
            instrumentation.uiAutomation.executeShellCommand("svc wifi enable").close()
            await("Wi-Fi enabled", 20_000) { shellOutput("settings get global wifi_on").trim() == "1" }

            // Sessions retain their identity and pane attachment while their transports recover.
            await("all terminal transports recovered", 120_000) {
                vm.activeSessions.size == hosts.size &&
                    vm.activeSessions.all { it.isConnected && !it.reconnecting }
            }
            assertEquals(paneOrder, listOf(vm.multiSshSessionId1, vm.multiSshSessionId2))
            assertTrue(
                "No transport observed the real Wi-Fi interruption",
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
                vm.pasteText("printf 'AFTER-${host.id}\\n'\n")
                await("${host.name} post-recovery command", 15_000) {
                    vm.terminalBufferTextFor(session, full = true).contains("AFTER-${host.id}")
                }
            }
            await("tmux output survived Wi-Fi loss", 45_000) {
                vm.terminalBufferTextFor(persistent, full = true).contains("WIFI-TMUX-END")
            }

            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal network cleanup", 30_000) { vm.activeSessions.isEmpty() }
            await("terminal notification cleanup", 15_000) { activeTerminalNotifications() == 0 }
        } finally {
            vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) }
            await("terminal network cleanup", 30_000) { vm.activeSessions.isEmpty() }
            TerminalSessionManager.clearAll()
            if (originalWifi == "0") {
                instrumentation.uiAutomation.executeShellCommand("svc wifi disable").close()
            } else {
                instrumentation.uiAutomation.executeShellCommand("svc wifi enable").close()
            }
        }
    }

    private fun shellOutput(command: String): String {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
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
        const val HTTP = "E2E HTTP Proxy"
        const val PERSISTENT = "E2E Split Persistent"
        val HOSTS = listOf(PERSISTENT, HTTP, "E2E SOCKS5 Proxy", "E2E SSH Jump")
    }
}
