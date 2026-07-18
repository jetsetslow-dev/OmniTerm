package com.jetsetslow.omniterm

import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Settings boundaries, lock lifecycle, backup rollback, battery saver, Fleet, and auto-refresh. */
class E2eSettingsStateStressTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun settingsDraftSurvivesActivityRecreationAndGuardsNavigation() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_settings_state") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val original = repository.getSetting("text_scale")
        try {
            composeRule.runOnUiThread {
                vm.settingsDirty = false
                vm.navigateTo(Screen.Servers)
                vm.saveTextScale("normal")
            }
            await("text-size baseline", 5_000) {
                vm.textScale == "normal" && repository.getSetting("text_scale") == "normal"
            }
            composeRule.runOnUiThread { vm.navigateTo(Screen.Settings) }
            composeRule.onNodeWithText("Small")
                .performScrollTo()
                .assertIsNotSelected()
                .performClick()
                .assertIsSelected()
            await("settings draft dirty", 5_000) { vm.settingsDirty }

            composeRule.activityRule.scenario.recreate()
            assertSame(vm, ViewModelProvider(composeRule.activity)[AppViewModel::class.java])
            await("settings draft after recreation", 5_000) { vm.settingsDirty }
            composeRule.runOnUiThread { vm.navigateTo(Screen.About) }
            assertTrue(vm.showSettingsDiscardDialog)
            composeRule.runOnUiThread { vm.discardSettingsAndLeave() }
            assertEquals(Screen.About, vm.currentScreen)
        } finally {
            vm.settingsDirty = false
            if (original == null) repository.deleteSetting("text_scale") else repository.insertSetting("text_scale", original)
        }
    }

    @Test
    fun settingsBackupSecurityBatteryFleetAndRefreshRemainCoherent() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_settings_state") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val touched = setOf(
            "terminal_font_size", "terminal_theme", "terminal_scrollback_limit", "terminal_smart_swipe",
            "terminal_link_detection", "link_open_in_app", "tmux_control_mode", "text_scale", "accessibility",
            "dark_mode", "amoled", "editor_highlight_limit", "telemetry_interval", "metrics_retention",
            "sftp_large_batch_file_threshold", "sftp_large_batch_bytes_threshold", "keep_screen_on",
            "battery_saver_enabled", "battery_saver_threshold", "app_pin", "app_lock_enabled",
            "biometrics_enabled", "app_lock_grace_ms", "pin_failed_attempts", "pin_locked_until",
        )
        val before = repository.getAllSettings().filter { it.key in touched }.associateBy { it.key }

        try {
            for (theme in listOf("system", "omni_dark", "solarized_dark", "matrix", "light", "invalid")) {
                vm.saveTerminalTheme(theme)
                assertEquals(if (theme == "invalid") "system" else theme, vm.terminalTheme)
            }
            vm.saveTerminalFontSize(-1); assertEquals(8, vm.terminalFontSize)
            vm.saveTerminalFontSize(99); assertEquals(28, vm.terminalFontSize)
            vm.saveTerminalScrollbackLimit(1); assertEquals(1_000, vm.terminalScrollbackLimit)
            vm.saveTerminalScrollbackLimit(99_999); assertEquals(50_000, vm.terminalScrollbackLimit)
            listOf("small", "normal", "large").forEach { vm.saveTextScale(it); assertEquals(it, vm.textScale) }
            for (enabled in listOf(true, false)) {
                vm.saveSmartSwipeInput(enabled); assertEquals(enabled, vm.smartSwipeInput)
                vm.saveTerminalLinkDetection(enabled); assertEquals(enabled, vm.terminalLinkDetection)
                vm.saveLinkOpenInApp(enabled); assertEquals(enabled, vm.linkOpenInApp)
                vm.saveTmuxControlMode(enabled); assertEquals(enabled, vm.tmuxControlMode)
                vm.saveAccessibilityToggle(enabled); assertEquals(enabled, vm.isAccessibilityEnabled)
            }
            for (dark in listOf<Boolean?>(null, false, true)) {
                vm.saveDarkModeToggle(dark)
                await("dark mode", 5_000) { vm.isDarkModeEnabled == dark }
                for (amoled in listOf(false, true)) {
                    vm.saveAmoledToggle(amoled)
                    await("AMOLED", 5_000) { vm.isAmoledEnabled == amoled }
                }
            }
            vm.saveEditorHighlightLimit(-1); await("highlight lower clamp", 5_000) { vm.editorHighlightLimit == 0 }
            vm.saveEditorHighlightLimit(Int.MAX_VALUE); await("highlight upper clamp", 5_000) { vm.editorHighlightLimit == 200_000 }
            vm.saveTelemetryInterval(1); await("interval lower clamp", 5_000) { vm.telemetryIntervalMs == 5_000L }
            vm.saveTelemetryInterval(999); await("interval upper clamp", 5_000) { vm.telemetryIntervalMs == 300_000L }
            vm.saveSftpLargeBatchThresholds(0, 1); await("large threshold clamp", 5_000) {
                vm.sftpLargeBatchFileThreshold == 1 && vm.sftpLargeBatchBytesThreshold == 1_000_000_000L
            }

            vm.saveTerminalTheme("solarized_dark")
            vm.saveTextScale("large")
            vm.saveTelemetryInterval(17)
            await("backup source settings", 5_000) {
                repository.getSetting("terminal_theme") == "solarized_dark" && repository.getSetting("telemetry_interval") == "17"
            }
            val authority = "${context.packageName}.slowtransfer"
            val backupUri = Uri.Builder().scheme("content").authority(authority).appendPath("backup").appendPath("settings-backup.json").build()
            val selection = BackupSelection(
                servers = false, sshKeys = false, credentialProfiles = false, scripts = false,
                alertRules = false, activeAlerts = false, alertHistory = false, wolTargets = false,
                networkShares = false, portForwards = false, settings = true, crashLogs = false,
            )
            val passphrase = "e2e-settings-backup-passphrase"
            val export = CompletableDeferred<Boolean>()
            vm.exportBackup(backupUri, passphrase, context, selection) { ok, _ -> export.complete(ok) }
            assertTrue(withTimeout(30_000) { export.await() })
            await("backup provider flush", 5_000) { SlowTransferContentProvider.payloads[backupUri.toString()]?.isNotEmpty() == true }
            val backup = requireNotNull(SlowTransferContentProvider.payloads[backupUri.toString()]).toString(Charsets.UTF_8)
            assertFalse(backup.contains("solarized_dark"))

            val wrong = CompletableDeferred<Boolean>()
            vm.inspectBackupContents(backup, "wrong-passphrase") { ok, _, _ -> wrong.complete(ok) }
            assertFalse(withTimeout(45_000) { wrong.await() })
            val corrupted = CompletableDeferred<Boolean>()
            vm.restoreEncryptedBackup(backup.dropLast(8) + "corrupt!!", passphrase, selection) { ok, _ -> corrupted.complete(ok) }
            assertFalse(withTimeout(45_000) { corrupted.await() })

            vm.saveTerminalTheme("matrix"); vm.saveTextScale("small"); vm.saveTelemetryInterval(300)
            val restored = CompletableDeferred<Boolean>()
            vm.restoreEncryptedBackup(backup, passphrase, selection) { ok, _ -> restored.complete(ok) }
            assertTrue(withTimeout(60_000) { restored.await() })
            await("live settings after restore", 10_000) {
                vm.terminalTheme == "solarized_dark" && vm.textScale == "large" && vm.telemetryIntervalMs == 17_000L
            }

            vm.removeSecurityPin(); await("old PIN removed", 5_000) { vm.savedPin == null }
            vm.savePinConfiguration("4826"); await("test PIN saved", 5_000) { vm.verifyPin("4826") }
            assertFalse(vm.verifyPin("0000"))
            assertNotNull(vm.verifyPinForSensitiveAction("0000"))
            vm.saveAppLockGrace(0); vm.isAppLocked = false; vm.noteAppBackgrounded(); vm.relockIfNeeded()
            assertTrue(vm.isAppLocked)
            "4826".forEach { vm.handlePinTyping(it.toString()) }
            await("PIN unlock", 5_000) { !vm.isAppLocked }
            vm.saveBiometricsToggle(true); await("biometric setting", 5_000) { vm.useBiometrics }
            vm.saveAppLockToggle(false); assertFalse(vm.useBiometrics); assertFalse(vm.isAppLocked)
        } finally {
            shell("cmd battery reset")
            vm.settingsDirty = false; vm.isAppLocked = false; vm.resumeFromBatterySaver(); vm.stopFleetBroadcast()
            for (key in touched) {
                val original = before[key]
                if (original == null) repository.deleteSetting(key) else repository.insertSetting(key, original.value)
            }
        }
    }

    @Test
    fun batterySaverFleetCancellationAndAutoRefreshRemainCoherent() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_settings_state") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val touched = setOf(
            "keep_screen_on", "battery_saver_enabled", "battery_saver_threshold", "telemetry_interval",
        )
        val before = repository.getAllSettings().filter { it.key in touched }.associateBy { it.key }
        try {
            vm.saveKeepScreenOnToggle(true)
            vm.saveBatterySaverThreshold(50)
            vm.saveBatterySaverEnabled(true)
            await("battery settings", 5_000) {
                vm.isKeepScreenOnEnabled && vm.batterySaverEnabled && vm.batterySaverThresholdPct == 50
            }
            shell("cmd battery unplug")
            shell("cmd battery set status 3")
            shell("cmd battery set level 1")
            await("battery saver engage", 10_000) { vm.batterySaverActive }
            assertFalse(vm.isKeepScreenOnEnabled)
            vm.refreshAllServers()
            await("manual refresh resumes saver", 10_000) { !vm.batterySaverActive && !vm.isRefreshing }
            vm.saveKeepScreenOnToggle(true)
            await("keep screen on restored for Fleet", 5_000) { vm.isKeepScreenOnEnabled }

            await("Fleet test host", 10_000) { vm.servers.value.any { it.name == "E2E Foreground Demo" } }
            val host = requireNotNull(vm.servers.value.find { it.name == "E2E Foreground Demo" })
            vm.selectedServerId = host.id
            vm.runFleetBroadcast("printf 'FLEET-SMALL-END\\n'", listOf(host.id))
            await("small Fleet connectivity probe", 20_000) {
                !vm.isBroadcastExecuting && vm.broadcastResults.singleOrNull()?.output?.contains("FLEET-SMALL-END") == true
            }
            vm.runFleetBroadcast("head -c 180000 /dev/zero | tr '\\0' X; printf '\\nFLEET-LONG-END\\n'", listOf(host.id))
            try {
                await("long Fleet broadcast", 45_000) { !vm.isBroadcastExecuting && vm.broadcastResults.isNotEmpty() }
            } catch (failure: AssertionError) {
                val result = vm.broadcastResults.singleOrNull()
                vm.stopFleetBroadcast()
                throw AssertionError(
                    "long Fleet state: executing=${vm.isBroadcastExecuting}, status=${result?.status}, " +
                        "chars=${result?.output?.length}, truncated=${result?.truncated}",
                    failure,
                )
            }
            assertTrue(vm.broadcastResults.single().truncated)
            assertTrue(vm.broadcastResults.single().output.contains("FLEET-LONG-END"))
            vm.runFleetBroadcast("yes tick", listOf(host.id))
            await("Fleet stream starts", 15_000) { vm.isBroadcastExecuting && vm.broadcastResults.any { it.output.contains("tick") } }
            vm.stopFleetBroadcast()
            await("Fleet cancellation", 10_000) { !vm.isBroadcastExecuting }

            vm.saveTelemetryInterval(5)
            vm.refreshAllServers()
            await("manual Fleet refresh", 15_000) { !vm.isRefreshing && vm.lastTelemetryStartMs > 0L }
            val firstCycle = vm.lastTelemetryStartMs
            await("auto refresh next cycle", 12_000) { vm.lastTelemetryStartMs > firstCycle }
        } finally {
            shell("cmd battery reset")
            vm.resumeFromBatterySaver()
            vm.stopFleetBroadcast()
            for (key in touched) {
                val original = before[key]
                if (original == null) repository.deleteSetting(key) else repository.insertSetting(key, original.value)
            }
        }
    }

    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }
    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        try { withTimeout(timeoutMs) { while (!predicate()) delay(100) } }
        catch (e: kotlinx.coroutines.TimeoutCancellationException) { throw AssertionError("$label did not finish within ${timeoutMs}ms", e) }
    }
}
