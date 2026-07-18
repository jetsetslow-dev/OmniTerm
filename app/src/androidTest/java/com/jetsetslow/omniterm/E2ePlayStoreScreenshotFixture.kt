package com.jetsetslow.omniterm

import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Opt-in Play Store screenshot fixture. Every visible value is synthetic: fictional host names on
 * documentation addresses (RFC 5737), a demo SSH container with hostname `atlas-prod` and user
 * `demo` created on the disposable lab for the terminal/files shots, an entirely fictional
 * Compose stack, and generated alert data. The E2E lab rows' real addresses are temporarily
 * rewritten to documentation addresses while the dashboard is captured and restored afterwards.
 *
 * Captures land in the app's external files dir under `play-screenshots/` for adb pull; nothing
 * is committed. FLAG_SECURE is disabled for the fixture and restored in cleanup.
 */
class E2ePlayStoreScreenshotFixture {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun captureSyntheticStoreScreenshots() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_screenshots") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val outDir = File(context.getExternalFilesDir(null), "play-screenshots").apply { mkdirs() }

        val originalFlagSecure = repository.getSetting("flag_secure")
        val originalDark = repository.getSetting("dark_mode")
        val originalKeepAlive = repository.getSetting("background_keep_alive")
        val demoNames = listOf("atlas-prod", "web-frontend", "db-primary", "staging-01", "backup-nas")
        val originalServers = repository.getAllServers()
        val e2eOriginals = originalServers.filter { it.name.startsWith("E2E") }
        val labHost = e2eOriginals.firstOrNull { it.name == "E2E Foreground Demo" }
        var demoShellId: Int? = null

        try {
            repository.insertSetting("flag_secure", "false")
            repository.insertSetting("dark_mode", "true")
            // No keep-alive service during captures: its permission disclosure dialog and the
            // session notifications would otherwise sit in every terminal shot.
            repository.insertSetting("background_keep_alive", "false")

            // ---- Fictional dashboard fleet (documentation addresses only). ----
            repository.getAllServers().filter { it.name in demoNames }
                .forEach { repository.deleteServerAndDependents(it.id) }
            val atlasId = repository.insertServer(
                ServerEntity(
                    name = "atlas-prod", host = "192.0.2.10", username = "ops",
                    groupName = "Production", status = "online", notes = "Primary application host",
                    lastLatency = 12,
                ),
            ).toInt()
            repository.insertServer(ServerEntity(name = "web-frontend", host = "192.0.2.11", username = "ops", groupName = "Production", status = "online", lastLatency = 9))
            repository.insertServer(ServerEntity(name = "db-primary", host = "192.0.2.12", username = "ops", groupName = "Production", status = "online", lastLatency = 14, healthScore = 92))
            repository.insertServer(ServerEntity(name = "staging-01", host = "198.51.100.20", username = "deploy", groupName = "Staging", status = "online", lastLatency = 21))
            repository.insertServer(ServerEntity(name = "backup-nas", host = "198.51.100.30", username = "backup", groupName = "Home Lab", status = "offline"))

            // Hide the real lab identities while the dashboard is on screen, and mark the rows
            // online so the fleet counters read like a healthy fleet; the Production group filter
            // keeps the E2E rows out of frame entirely.
            e2eOriginals.forEach {
                repository.updateServer(
                    it.copy(
                        host = "203.0.113.5",
                        username = "ops",
                        status = "online",
                        proxyHost = if (it.proxyHost.isBlank()) "" else "203.0.113.5",
                    ),
                )
            }

            composeRule.runOnUiThread { vm.navigateTo(Screen.Servers) }
            composeRule.waitForIdle()
            composeRule.onNodeWithText("Production").performClick()
            awaitFrame()
            capture(instrumentation, outDir, "04-server-dashboard")
            // Real lab rows are needed again as soon as anything dials the lab.
            e2eOriginals.forEach { repository.updateServer(it) }

            // ---- Fictional alert overview. ----
            repository.insertRule(
                AlertRuleEntity(serverId = atlasId, metricName = "CPU Usage", thresholdValue = 90f, severity = "CRITICAL", notes = "Page the on-call rotation"),
            )
            val ruleId = repository.getRulesForServer(atlasId).first { it.metricName == "CPU Usage" }.id
            repository.insertRule(AlertRuleEntity(serverId = atlasId, metricName = "Disk Usage", mountPoint = "/srv", thresholdValue = 85f, severity = "WARNING"))
            repository.insertAlert(
                ActiveAlertEntity(ruleId = ruleId, serverId = atlasId, metricName = "CPU Usage", currentValue = 96.4f, thresholdValue = 90f, severity = "CRITICAL", triggeredTime = System.currentTimeMillis() - 4 * 60 * 1000),
            )
            composeRule.runOnUiThread { vm.navigateTo(Screen.Alerts) }
            awaitFrame()
            capture(instrumentation, outDir, "07-alerts-overview")

            // ---- Fictional Compose stack in the visual builder. ----
            composeRule.runOnUiThread {
                vm.selectedServerId = atlasId
                vm.beginComposeDraft(
                    parseDockerComposeYaml(FICTIONAL_STACK, projectName = "shop-platform"),
                )
                vm.activeInfraTab = 1
                vm.navigateTo(Screen.Infra)
            }
            awaitFrame()
            capture(instrumentation, outDir, "06-compose-builder")

            // ---- Demo SSH container on the disposable lab for terminal + files shots. ----
            assumeTrue("lab host with credentials required", labHost != null)
            TerminalSessionManager.clearAll()
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.Shell)
                vm.selectedServerId = labHost!!.id
                vm.connectTerminal()
            }
            await("lab setup shell", 30_000) {
                if (vm.offlineConnectPromptServer != null) {
                    composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                }
                !vm.isTerminalConnecting && vm.currentSession != null
            }
            assertNull(vm.terminalConnectError)
            val setup = requireNotNull(vm.currentSession)
            await("setup prompt", 10_000) { vm.terminalBufferTextFor(setup, full = true).isNotBlank() }
            vm.pasteText(
                "docker rm -f omniterm-demo >/dev/null 2>&1; " +
                    "docker run -d --name omniterm-demo --hostname atlas-prod -p 2299:22 alpine:latest " +
                    "sh -c 'apk add --no-cache openssh >/dev/null 2>&1 && ssh-keygen -A && " +
                    "adduser -D demo && echo demo:omni-demo-pass | chpasswd && " +
                    "mkdir -p /srv/app/releases /srv/app/config /srv/app/logs && " +
                    "printf \"web:\\n  image: registry.example.com/shop/web:2.4.1\\n\" > /srv/app/config/app.yml && " +
                    "printf \"v2.4.0\\nv2.4.1\\n\" > /srv/app/releases/MANIFEST && " +
                    "chown -R demo /srv/app && " +
                    "exec /usr/sbin/sshd -D' " +
                    "&& printf '%s%s\\n' 'DEMO-' 'STARTED'\n",
            )
            await("demo container started", 120_000) {
                vm.terminalBufferTextFor(setup, full = true).contains("DEMO-STARTED")
            }
            vm.pasteText(
                "i=0; until docker exec omniterm-demo pgrep -x sshd >/dev/null 2>&1; " +
                    "do i=\$((i+1)); [ \$i -gt 90 ] && break; sleep 1; done; printf '%s%s\\n' 'DEMO-' 'READY'\n",
            )
            await("demo sshd ready", 120_000) {
                vm.terminalBufferTextFor(setup, full = true).contains("DEMO-READY")
            }

            demoShellId = repository.insertServer(
                ServerEntity(
                    name = "atlas-prod", host = labHost!!.host, port = 2299, username = "demo",
                    authPassword = "omni-demo-pass", groupName = "Production", status = "online",
                ),
            ).toInt()
            await("demo host visible", 10_000) { vm.servers.value.any { it.id == demoShellId } }

            // Each demo container generates fresh host keys; drop any entry a previous fixture
            // run stored for the same lab endpoint so the connect can't hit the changed-key gate.
            composeRule.runOnUiThread { vm.removeKnownHost("${labHost!!.host}:2299") }
            composeRule.runOnUiThread {
                vm.selectedServerId = demoShellId
                vm.connectTerminal()
            }
            try {
            await(
                {
                    "demo shell 1 (err=${vm.terminalConnectError}, connecting=${vm.isTerminalConnecting}, " +
                        "hostKey=${vm.pendingHostKeyApproval != null}, offline=${vm.offlineConnectPromptServer != null}, " +
                        "sessions=${vm.activeSessions.map { it.serverId }}, want=$demoShellId, sel=${vm.selectedServerId})"
                },
                45_000,
            ) {
                if (vm.offlineConnectPromptServer != null) {
                    composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                }
                // First contact with the demo container's brand-new host key: approve it.
                if (vm.pendingHostKeyApproval != null) {
                    composeRule.runOnUiThread { vm.approveHostKey(true) }
                }
                !vm.isTerminalConnecting && vm.activeSessions.any { it.serverId == demoShellId }
            }
            } catch (first: AssertionError) {
                // Pull the container's sshd log through the setup shell for the failure report;
                // strip anything that looks like an address before it lands in an assertion.
                vm.attachSession(setup.id)
                vm.pasteText("docker logs --tail 8 omniterm-demo 2>&1 | sed 's/[0-9]\\{1,3\\}\\(\\.[0-9]\\{1,3\\}\\)\\{3\\}/x.x.x.x/g'; printf '%s%s\\n' 'LOG-' 'DUMPED'\n")
                runCatching {
                    await("sshd log dump", 20_000) {
                        vm.terminalBufferTextFor(setup, full = true).contains("LOG-DUMPED")
                    }
                }
                val tail = vm.terminalBufferTextFor(setup, full = true)
                    .substringAfterLast("docker logs").take(700)
                    .replace(Regex("\\d{1,3}(\\.\\d{1,3}){3}"), "x.x.x.x")
                throw AssertionError(first.message + "\nsshd log tail: " + tail, first)
            }
            assertNull(vm.terminalConnectError)
            val shell1 = requireNotNull(vm.activeSessions.find { it.serverId == demoShellId })
            await("demo prompt", 15_000) { vm.terminalBufferTextFor(shell1, full = true).contains("atlas-prod") }
            vm.pasteText(DEMO_STATUS_SCRIPT)
            await("demo status output", 15_000) { vm.terminalBufferTextFor(shell1, full = true).contains("deploy complete") }

            // Second pane: live log stream for the split-terminal shot.
            composeRule.runOnUiThread {
                vm.selectedServerId = demoShellId
                vm.connectTerminal()
            }
            await("demo shell 2", 30_000) { vm.activeSessions.count { it.serverId == demoShellId } == 2 }
            val shell2 = requireNotNull(vm.activeSessions.filter { it.serverId == demoShellId }.last())
            await("second prompt", 15_000) { vm.terminalBufferTextFor(shell2, full = true).contains("atlas-prod") }
            vm.pasteText(DEMO_LOG_SCRIPT)
            await("demo log output", 15_000) { vm.terminalBufferTextFor(shell2, full = true).contains("healthy") }
            composeRule.runOnUiThread {
                vm.attachSession(shell1.id)
                vm.enterMultiSsh()
                vm.assignMultiSshPane(1, shell1.id)
                vm.assignMultiSshPane(2, shell2.id)
                vm.navigateTo(Screen.Shell)
            }
            // The pane headers render user@host live from the server row: swap the host for a
            // documentation address while the frame is captured. The established SSH sockets
            // are unaffected, and the real row is restored right after.
            val demoRow = repository.getAllServers().first { it.id == demoShellId }
            repository.updateServer(demoRow.copy(host = "192.0.2.10"))
            // Let the split resize settle (debounced remote resize + repaint), then re-publish
            // both panes' snapshots, drop the soft keyboard, and clear session notifications so
            // the capture shows the terminal, not the IME.
            delay(2_500)
            TerminalSessionManager.publishTerminalSnapshot(shell1)
            TerminalSessionManager.publishTerminalSnapshot(shell2)
            hideIme()
            androidx.core.app.NotificationManagerCompat.from(context).cancelAll()
            awaitFrame()
            capture(instrumentation, outDir, "05-split-terminal")
            repository.updateServer(demoRow)

            // ---- Remote file manager on the demo container. ----
            composeRule.runOnUiThread {
                vm.exitMultiSsh()
                vm.selectedServerId = demoShellId
                vm.activeSftpTab = 1
                vm.navigateTo(Screen.SFTP)
            }
            composeRule.waitForIdle()
            if (vm.showDisconnectTerminalDialog) {
                composeRule.runOnUiThread { vm.completeTerminalNavigation(disconnect = false) }
            }
            composeRule.runOnUiThread { vm.loadSftp("/srv/app") }
            await("demo sftp listing", 30_000) {
                vm.sftpPath == "/srv/app" && !vm.sftpLoading && vm.sftpEntries.isNotEmpty()
            }
            // Same capture-time host swap for the SFTP host selector bar.
            repository.updateServer(demoRow.copy(host = "192.0.2.10"))
            androidx.core.app.NotificationManagerCompat.from(context).cancelAll()
            awaitFrame()
            capture(instrumentation, outDir, "08-remote-files")
            repository.updateServer(demoRow)
        } finally {
            runCatching {
                vm.activeSessions.toList().forEach { s ->
                    if (s.serverId == demoShellId) vm.disconnectSession(s.id)
                }
            }
            // Tear down the demo container through the setup shell, then close it too.
            runCatching {
                val setup = vm.activeSessions.firstOrNull { it.serverId == labHost?.id }
                if (setup != null) {
                    vm.attachSession(setup.id)
                    vm.pasteText("docker rm -f omniterm-demo >/dev/null 2>&1; printf '%s%s\\n' 'DEMO-' 'GONE'\n")
                    await("demo container removed", 60_000) {
                        vm.terminalBufferTextFor(setup, full = true).contains("DEMO-GONE")
                    }
                }
            }
            runCatching { vm.activeSessions.toList().forEach { vm.disconnectSession(it.id) } }
            runCatching { await("sessions closed", 20_000) { vm.activeSessions.isEmpty() } }

            // Remove every synthetic row and restore the real lab entries + settings.
            runCatching {
                repository.getAllServers().filter { it.name in demoNames || it.name == "atlas-prod · shell" }
                    .forEach { repository.deleteServerAndDependents(it.id) }
            }
            runCatching { e2eOriginals.forEach { repository.updateServer(it) } }
            runCatching {
                if (originalFlagSecure == null) repository.deleteSetting("flag_secure")
                else repository.insertSetting("flag_secure", originalFlagSecure)
                if (originalDark == null) repository.deleteSetting("dark_mode")
                else repository.insertSetting("dark_mode", originalDark)
                if (originalKeepAlive == null) repository.deleteSetting("background_keep_alive")
                else repository.insertSetting("background_keep_alive", originalKeepAlive)
            }
            TerminalSessionManager.clearAll()
        }
    }

    private fun hideIme() {
        composeRule.runOnUiThread {
            val activity = composeRule.activity
            val imm = activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
            activity.currentFocus?.let { imm?.hideSoftInputFromWindow(it.windowToken, 0) }
            activity.currentFocus?.clearFocus()
        }
    }

    private suspend fun awaitFrame() {
        composeRule.waitForIdle()
        delay(700)
    }

    private fun capture(
        instrumentation: android.app.Instrumentation,
        dir: File,
        name: String,
    ) {
        // Saved as-is; the local export step normalizes to 24-bit PNG at Play's dimensions.
        val shot: Bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "screenshot failed: $name" }
        FileOutputStream(File(dir, "$name.png")).use { out ->
            shot.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        assertTrue(File(dir, "$name.png").length() > 0)
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) =
        await({ label }, timeoutMs, predicate)

    private suspend fun await(label: () -> String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) {
                while (!predicate()) delay(150)
            }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("${label()} did not finish within ${timeoutMs}ms", timeout)
        }
    }

    private companion object {
        val FICTIONAL_STACK = """
            services:
              web:
                image: registry.example.com/shop/web:2.4.1
                ports:
                  - "443:8443"
                environment:
                  - NODE_ENV=production
                depends_on:
                  - api
                  - cache
              api:
                image: registry.example.com/shop/api:2.4.1
                environment:
                  - DATABASE_URL=postgres://db:5432/shop
                depends_on:
                  - db
              cache:
                image: redis:7-alpine
                command: ["redis-server", "--maxmemory", "256mb"]
              db:
                image: postgres:16-alpine
                volumes:
                  - db-data:/var/lib/postgresql/data
            volumes:
              db-data:
            """.trimIndent()

        // Entirely fictional status board printed by the demo shell.
        val DEMO_STATUS_SCRIPT =
            "clear; printf '\\033[1;36m %s\\033[0m\\n' 'shop-platform — production'; " +
                "printf '\\033[32m%s\\033[0m\\n' '● web        running   2/2   v2.4.1'; " +
                "printf '\\033[32m%s\\033[0m\\n' '● api        running   2/2   v2.4.1'; " +
                "printf '\\033[32m%s\\033[0m\\n' '● cache      running   1/1   redis:7'; " +
                "printf '\\033[33m%s\\033[0m\\n' '◐ db         syncing   1/1   postgres:16'; " +
                "printf '\\n%s\\n' 'release v2.4.1 → deploy complete in 41s'\n"

        val DEMO_LOG_SCRIPT =
            "clear; printf '%s\\n' '10:06:01 web  GET /checkout 200 38ms'; " +
                "printf '%s\\n' '10:06:02 api  POST /orders 201 61ms'; " +
                "printf '%s\\n' '10:06:02 web  GET /assets/app.css 200 4ms'; " +
                "printf '%s\\n' '10:06:04 api  GET /health 200 2ms \u2014 healthy'\n"
    }
}
