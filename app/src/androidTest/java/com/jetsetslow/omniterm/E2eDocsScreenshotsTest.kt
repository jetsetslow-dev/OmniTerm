package com.jetsetslow.omniterm

import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Opt-in tool that captures the screenshots on the documentation site (`docs/assets/`).
 *
 * It uses only the repository's disposable Docker fleet: the Docker-runtime host (port 2205), which
 * [E2eLabHostProvisioner] seeds as `E2E Foreground Demo`, plus two more rows for the other fixture
 * ports. The rows are renamed for the shots and restored afterwards. Run it with the fleet up and
 * its ports reversed to the emulator, a compose project running on the Docker-runtime host, and
 * the same `-e user` / `-e pass` arguments as the provisioner:
 *
 * ```
 * adb shell am instrument -w -e omniterm_e2e_docs_screenshots yes -e user <name> -e pass '<password>' \
 *   -e class com.jetsetslow.omniterm.E2eDocsScreenshotsTest \
 *   com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
 * ```
 *
 * PNGs land in the app's external files dir under `docs-screenshots/` for `adb pull`; nothing is
 * committed from the device. FLAG_SECURE is turned off for the run and restored in cleanup.
 */
class E2eDocsScreenshotsTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun captureDocumentationScreenshots() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_docs_screenshots") == "yes")
        val user = requireNotNull(args.getString("user")) { "-e user <name> is required" }
        val pass = requireNotNull(args.getString("pass")) { "-e pass <password> is required" }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val outDir = File(context.getExternalFilesDir(null), "docs-screenshots").apply { mkdirs() }

        await("lab host row") { vm.servers.value.any { it.name == LAB_HOST } }
        val original = vm.servers.value.single { it.name == LAB_HOST }
        val settings = listOf("flag_secure", "dark_mode", "background_keep_alive")
            .associateWith { repository.getSetting(it) }
        val extraNames = listOf("lab-podman", "lab-direct")
        try {
            composeRule.runOnUiThread { vm.isAppLocked = false }
            repository.insertSetting("flag_secure", "false")
            repository.insertSetting("dark_mode", "true")
            repository.insertSetting("background_keep_alive", "false")
            repository.updateServer(original.copy(name = "lab-docker", groupName = "Lab"))
            vm.servers.value.filter { it.name in extraNames }.forEach { repository.deleteServerAndDependents(it.id) }
            addHost(vm, "lab-podman", 2206, user, pass)
            addHost(vm, "lab-direct", 2201, user, pass)
            await("renamed rows") { extraNames.all { n -> vm.servers.value.any { it.name == n } } }
            val docker = vm.servers.value.single { it.name == "lab-docker" }
            val podman = vm.servers.value.single { it.name == "lab-podman" }

            // Fleet Broadcast first: it also trusts both host keys for the rest of the run.
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Fleet)
                vm.fleetTabIndex = 1
                vm.broadcastTargetMode = FleetTargetMode.Servers
                vm.broadcastTargetServerIds.clear()
                vm.broadcastTargetServerIds.addAll(listOf(docker.id, podman.id))
                vm.broadcastCommandText = "uname -sr; uptime"
                vm.runFleetBroadcast("uname -sr; uptime", listOf(docker.id, podman.id))
            }
            await("broadcast settles", 90_000) {
                approveHostKey(vm)
                !vm.isBroadcastExecuting && vm.broadcastResults.size == 2
            }
            composeRule.onNodeWithText("lab-docker").performClick()
            composeRule.onNodeWithText("lab-podman").performClick()
            awaitFrame()
            capture(instrumentation, outDir, "fleet-broadcast")

            // Host list.
            await("hosts online", 40_000, soft = true) {
                vm.servers.value.filter { it.id == docker.id || it.id == podman.id }.all { it.status == "online" }
            }
            composeRule.runOnUiThread { vm.navigateTo(Screen.Servers) }
            awaitFrame()
            capture(instrumentation, outDir, "host-list")

            // Terminal.
            TerminalSessionManager.clearAll()
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = docker.id
                vm.connectTerminal()
            }
            await("terminal session", 40_000) {
                approveHostKey(vm)
                if (vm.offlineConnectPromptServer != null) composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                !vm.isTerminalConnecting && vm.currentSession != null
            }
            val session = requireNotNull(vm.currentSession)
            await("prompt", 15_000) { vm.terminalBufferTextFor(session, full = true).isNotBlank() }
            vm.pasteText("uname -srm; uptime\n")
            await("command output", 15_000) { vm.terminalBufferTextFor(session, full = true).contains("load average") }
            hideIme(instrumentation)
            androidx.core.app.NotificationManagerCompat.from(context).cancelAll()
            awaitFrame()
            capture(instrumentation, outDir, "terminal")

            // Files: the fixture folder on the Docker-runtime host.
            composeRule.runOnUiThread {
                vm.selectedServerId = docker.id
                vm.activeSftpTab = 1
                vm.navigateTo(Screen.SFTP)
            }
            composeRule.waitForIdle()
            if (vm.showDisconnectTerminalDialog) composeRule.runOnUiThread { vm.completeTerminalNavigation(disconnect = false) }
            composeRule.runOnUiThread { vm.loadSftp("/home/$user/omniterm-e2e") }
            await("files listing", 30_000) {
                vm.sftpPath == "/home/$user/omniterm-e2e" && !vm.sftpLoading && vm.sftpEntries.isNotEmpty()
            }
            awaitFrame()
            capture(instrumentation, outDir, "files")

            // Monitor.
            composeRule.runOnUiThread {
                vm.selectedServerId = docker.id
                vm.activeMonitorTab = 0
                vm.navigateTo(Screen.Monitor)
            }
            delay(15_000)
            awaitFrame()
            capture(instrumentation, outDir, "monitor")

            // Containers (the compose project running on the Docker-runtime host).
            composeRule.runOnUiThread {
                vm.selectedServerId = docker.id
                vm.activeInfraTab = 0
                vm.navigateTo(Screen.Infra)
                vm.loadDocker()
            }
            await("containers listed", 30_000) { vm.dockerContainers.isNotEmpty() }
            awaitFrame()
            capture(instrumentation, outDir, "containers")
        } finally {
            runCatching { vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) } }
            runCatching {
                vm.servers.value.filter { it.name in extraNames }.forEach { repository.deleteServerAndDependents(it.id) }
                repository.updateServer(original)
                settings.forEach { (key, value) ->
                    if (value == null) repository.deleteSetting(key) else repository.insertSetting(key, value)
                }
            }
            TerminalSessionManager.clearAll()
        }
    }

    private fun addHost(vm: AppViewModel, name: String, port: Int, user: String, pass: String) {
        composeRule.runOnUiThread {
            vm.addServer(
                name = name, host = "127.0.0.1", port = port, username = user, group = "Lab",
                authType = "password", notes = "", keepAlive = 0, compression = false, proxy = "",
                password = pass,
            ) { error -> assertTrue("addServer reported: $error", error == null) }
        }
    }

    private fun approveHostKey(vm: AppViewModel) {
        composeRule.runOnUiThread { if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true) }
    }

    /** The terminal asks for the keyboard; Back closes just the keyboard while it is showing. */
    private suspend fun hideIme(instrumentation: android.app.Instrumentation) {
        repeat(3) {
            val state = android.os.ParcelFileDescriptor.AutoCloseInputStream(
                instrumentation.uiAutomation.executeShellCommand("dumpsys input_method"),
            ).bufferedReader().use { it.readText() }
            if (!state.contains("mInputShown=true")) return
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
            delay(800)
        }
    }

    private suspend fun awaitFrame() {
        composeRule.waitForIdle()
        delay(800)
    }

    private fun capture(instrumentation: android.app.Instrumentation, dir: File, name: String) {
        val shot: Bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "screenshot failed: $name" }
        FileOutputStream(File(dir, "$name.png")).use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
        assertTrue(File(dir, "$name.png").length() > 0)
    }

    private suspend fun await(label: String, timeoutMs: Long = 10_000, soft: Boolean = false, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(150) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            if (!soft) throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private companion object { const val LAB_HOST = "E2E Foreground Demo" }
}
