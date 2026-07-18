package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Broad physical smoke/soak over every screen, subtab, theme, refresh, and core remote loader. */
class E2eAppSurfaceStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun everyScreenSubtabThemeAndRemoteLoaderSurvivesNavigationAndRotation() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_surfaces") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        await("seeded direct host", 15_000) { vm.servers.value.any { it.name == HOST } }
        val host = requireNotNull(vm.servers.value.find { it.name == HOST })
        composeRule.runOnUiThread { vm.selectedServerId = host.id }

        val originalDark = vm.isDarkModeEnabled
        val originalAmoled = vm.isAmoledEnabled
        val originalTerminalTheme = vm.terminalTheme
        try {
            // Every route, including non-bottom-nav tool routes, must compose without a stale-state
            // crash. Alternate orientation halfway through to exercise compact and wide layouts.
            Screen.entries.forEachIndexed { index, screen ->
                if (screen == Screen.Shell) return@forEachIndexed // terminal has dedicated physical soaks
                if (index == Screen.entries.size / 2) {
                    composeRule.runOnUiThread {
                        composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                }
                composeRule.runOnUiThread { vm.navigateTo(screen) }
                composeRule.waitUntil(15_000) { vm.currentScreen == screen }
                composeRule.waitForIdle()
                composeRule.runOnUiThread { assertFalse(composeRule.activity.isFinishing) }
            }

            // Render every nested tab; this catches tab-specific LaunchedEffect, empty/error state,
            // and compact-layout crashes without duplicating the dedicated network/compose suites.
            renderSubtabs(vm, Screen.Fleet, 3) { vm.fleetTabIndex = it }
            renderSubtabs(vm, Screen.Monitor, 6) { vm.activeMonitorTab = it }
            renderSubtabs(vm, Screen.SFTP, 4) { vm.activeSftpTab = it }
            renderSubtabs(vm, Screen.Infra, 5) { vm.activeInfraTab = it }
            renderSubtabs(vm, Screen.Network, 9) { vm.activeNetworkTab = it }
            renderSubtabs(vm, Screen.Alerts, 3) { vm.activeAlertsTab = it }
            renderSubtabs(vm, Screen.QuickScripts, 2) { vm.activeScriptsTab = it }

            // App themes plus all terminal palettes. State and UI must settle for every variant.
            listOf<Boolean?>(null, false, true).forEach { dark ->
                vm.saveDarkModeToggle(dark)
                await("dark theme $dark", 5_000) { vm.isDarkModeEnabled == dark }
                composeRule.waitForIdle()
            }
            vm.saveAmoledToggle(true)
            await("AMOLED theme", 5_000) { vm.isAmoledEnabled }
            vm.saveAmoledToggle(false)
            for (theme in listOf("system", "omni_dark", "solarized_dark", "matrix", "light")) {
                vm.saveTerminalTheme(theme)
                assertEquals(theme, vm.terminalTheme)
            }

            // Real read-only remote feature paths against the disposable RPi.
            composeRule.runOnUiThread { vm.selectedServerId = host.id }
            vm.loadProcesses()
            awaitLoader("process loader", 20_000) { vm.processesLoading }
            vm.loadServices()
            awaitLoader("service loader", 20_000) { vm.servicesLoading }
            vm.loadLogs("ALL")
            awaitLoader("log loader", 20_000) { vm.logsLoading }
            vm.loadCron()
            awaitLoader("cron loader", 20_000) { vm.cronLoading }
            vm.loadDocker()
            awaitLoader("container loader", 30_000) { vm.dockerLoading }
            // The disposable lab username is supplied at seed time. Never couple the broad suite
            // to one developer's local account name; doing so turns a valid lab into a false SFTP
            // failure as soon as the runtime fixture uses another user.
            // Await the load's OUTCOME rather than the loading-flag start edge: with a warm pooled
            // SFTP session a LAN listing completes faster than one poll interval, so the
            // true-then-false pulse can be missed entirely and the start await times out.
            vm.loadSftp("/home/${host.username}")
            await("SFTP listing applied", 20_000) {
                vm.sftpPath == "/home/${host.username}" && !vm.sftpLoading
            }
            assertTrue("SFTP loader failed: ${vm.sftpError}", vm.sftpError.isNullOrBlank())

            vm.runFleetBroadcast("printf 'FLEET-SURFACE-OK\\n'", resolvedIds = listOf(host.id))
            await("Fleet broadcast", 30_000) { !vm.isBroadcastExecuting && vm.broadcastResults.isNotEmpty() }
            assertTrue(vm.broadcastResults.single().output.contains("FLEET-SURFACE-OK"))

            // Non-vanilla navigation paths: Settings dirty guard and swipe carry-over at subtab edges.
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Settings)
                vm.settingsDirty = true
                vm.navigateTo(Screen.About)
            }
            assertEquals(Screen.Settings, vm.currentScreen)
            assertTrue(vm.showSettingsDiscardDialog)
            composeRule.runOnUiThread { vm.discardSettingsAndLeave() }
            assertEquals(Screen.About, vm.currentScreen)

            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Monitor)
                vm.activeMonitorTab = 5
                vm.swipeNavigate(forward = true)
            }
            assertEquals(Screen.Shell, vm.currentScreen)
            composeRule.runOnUiThread { vm.swipeNavigate(forward = true) }
            assertEquals(Screen.SFTP, vm.currentScreen)
            assertEquals(0, vm.activeSftpTab)

            composeRule.runOnUiThread {
                composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
            composeRule.waitForIdle()
            assertEquals(Screen.SFTP, vm.currentScreen)
        } finally {
            vm.saveDarkModeToggle(originalDark)
            vm.saveAmoledToggle(originalAmoled)
            vm.saveTerminalTheme(originalTerminalTheme)
            vm.settingsDirty = false
        }
    }

    private suspend fun renderSubtabs(
        vm: AppViewModel,
        screen: Screen,
        count: Int,
        select: (Int) -> Unit,
    ) {
        repeat(count) { tab ->
            composeRule.runOnUiThread {
                vm.navigateTo(screen)
                select(tab)
            }
            composeRule.waitUntil(15_000) { vm.currentScreen == screen }
            composeRule.waitForIdle()
            delay(100)
        }
    }

    private suspend fun await(label: String, timeoutMs: Long, pollMs: Long = 100, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                while (!predicate()) delay(pollMs)
            }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", timeout)
        }
    }

    /**
     * ViewModel loaders launch on Main and set their loading flag inside the new coroutine. Waiting
     * only for `!loading` can therefore succeed before the work starts and accidentally assert on
     * stale state from an earlier screen. Observe both edges so this suite covers the remote call.
     * The start edge is polled at millisecond granularity: on a warm pooled SSH session a LAN
     * loader's true-then-false pulse is shorter than the default poll interval and was missed.
     */
    private suspend fun awaitLoader(label: String, timeoutMs: Long, isLoading: () -> Boolean) {
        await("$label start", 5_000, pollMs = 1, predicate = isLoading)
        await("$label finish", timeoutMs) { !isLoading() }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
    }
}
