package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.ui.AppLockClock
import com.jetsetslow.omniterm.ui.AppLockGrace
import com.jetsetslow.omniterm.ui.AppLockGraceWindow
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.PrefsAppLockAwayStore
import com.jetsetslow.omniterm.ui.PreviousExit
import com.jetsetslow.omniterm.ui.hashPinForStorage
import java.security.SecureRandom
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * App Lock's 60-minute window through the real Activity lifecycle, on a device, with an injected
 * clock: no real time passes, the clock is moved forward. Real-time runs with real process kills
 * and reboots are driven from the host (they would kill this instrumentation too); this covers
 * what only a long window can show.
 *
 * Opt in with `-e omniterm_e2e_applock_window yes`. Every setting it touches is restored.
 */
class E2eAppLockWindowTest {
    @get:Rule val composeRule = createEmptyComposeRule()

    private val touchedKeys = listOf(
        "app_pin", "app_lock_enabled", "biometrics_enabled",
        "pin_failed_attempts", "pin_locked_until", "app_lock_grace_ms", "first_run_complete",
    )

    private class MovableClock(var now: Long) : AppLockClock {
        override fun elapsedRealtimeMs() = now
        override fun bootCount(): Int? = 3
    }

    @Test
    fun sixtyMinuteWindowAcrossTheActivityLifecycle() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_applock_window") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val before = repository.getAllSettings().filter { it.key in touchedKeys }.associateBy { it.key }
        // Generated per run; never logged, never in an assertion message.
        val pin = (SecureRandom().nextInt(900_000) + 100_000).toString()
        val clock = MovableClock(now = 10 * HOUR)
        val store = PrefsAppLockAwayStore(context)
        fun process(pid: Int) = AppLockGraceWindow(
            clock, store, { PreviousExit.CLOSED_BY_SYSTEM }, pid = pid, installStamp = 1L,
        )
        store.clear()
        AppLockGrace.replaceForTests(process(pid = 1))
        var scenario: ActivityScenario<MainActivity>? = null
        try {
            repository.insertSetting("app_pin", hashPinForStorage(pin))
            repository.insertSetting("app_lock_enabled", "true")
            repository.insertSetting("biometrics_enabled", "false")
            repository.insertSetting("pin_failed_attempts", "0")
            repository.insertSetting("pin_locked_until", "0")
            repository.insertSetting("app_lock_grace_ms", (60 * MINUTE).toString())
            repository.insertSetting("first_run_complete", "true")

            scenario = ActivityScenario.launch(MainActivity::class.java)
            var vm = modelOf(scenario)
            await("first start locks", 10_000) { vm.securitySettingsLoaded && vm.isAppLocked }
            unlock(vm, pin)

            // (a) Away 59 minutes, back: unlocked.
            leaveAndReturn(scenario, clock, away = 59 * MINUTE)
            assertStaysUnlocked(vm, "back after 59 min")

            // (b) Away exactly 60 minutes, back: locked.
            leaveAndReturn(scenario, clock, away = 60 * MINUTE)
            await("back after 60 min locks", 10_000) { vm.isAppLocked }
            unlock(vm, pin)

            // (c) A rotation-equivalent recreation never starts the countdown, however long it is.
            clock.now += 2 * HOUR
            scenario.recreate()
            vm = modelOf(scenario)
            assertStaysUnlocked(vm, "recreated")

            // (d) The Activity finishes (Back to exit, or the task removed while the keep-alive
            // service keeps the process) and is opened again in the same process.
            scenario.close()
            clock.now += 59 * MINUTE
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = modelOf(scenario)
            await("new screen settled", 10_000) { vm.securitySettingsLoaded }
            assertStaysUnlocked(vm, "new screen after 59 min")
            scenario.close()
            clock.now += 60 * MINUTE
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = modelOf(scenario)
            await("new screen after 60 min locks", 10_000) { vm.securitySettingsLoaded && vm.isAppLocked }
            unlock(vm, pin)

            // (e) Android closes the process in the background: a new process takes over the
            // window from disk.
            scenario.close()
            AppLockGrace.replaceForTests(process(pid = 2))
            clock.now += 59 * MINUTE
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = modelOf(scenario)
            await("new process settled", 10_000) { vm.securitySettingsLoaded }
            assertStaysUnlocked(vm, "new process after 59 min")
            scenario.close()
            AppLockGrace.replaceForTests(process(pid = 3))
            clock.now += 60 * MINUTE
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = modelOf(scenario)
            await("new process after 60 min locks", 10_000) { vm.securitySettingsLoaded && vm.isAppLocked }
            unlock(vm, pin)

            // A relock keeps the editor's unsaved text.
            val file = SftpFile("lock-window.conf", isDirectory = false, size = 8, modDate = "", content = "port=22\n")
            composeRule.runOnUiThread { vm.edittingSftpFile = file }
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("lock-window.conf")).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").performClick()
            composeRule.onNodeWithTag("code-editor-input").performTextReplacement("port=2222\n")
            composeRule.waitForIdle()
            leaveAndReturn(scenario, clock, away = 61 * MINUTE)
            await("editor relocked", 10_000) { vm.isAppLocked }
            unlock(vm, pin)
            // Still open, and still marked unsaved ("lock-window.conf •").
            composeRule.waitUntil(10_000) {
                composeRule.onAllNodes(hasText("lock-window.conf •")).fetchSemanticsNodes().isNotEmpty()
            }
            composeRule.onNodeWithTag("code-editor-input").assertTextEquals("port=2222\n")
            composeRule.runOnUiThread {
                vm.edittingSftpFile = null
                vm.sftpEditorDraft.clear()
            }

            // (j) Lock now locks at once and leaves no window behind.
            composeRule.runOnUiThread { vm.lockApp() }
            assertTrue(vm.isAppLocked)
            scenario.close()
            clock.now += MINUTE
            scenario = ActivityScenario.launch(MainActivity::class.java)
            vm = modelOf(scenario)
            await("after Lock now a new screen is locked", 10_000) { vm.securitySettingsLoaded && vm.isAppLocked }
        } finally {
            scenario?.close()
            AppLockGrace.replaceForTests(null)
            store.clear()
            for (key in touchedKeys) {
                val original = before[key]
                if (original == null) repository.deleteSetting(key) else repository.insertSetting(key, original.value)
            }
        }
    }

    private fun modelOf(scenario: ActivityScenario<MainActivity>): AppViewModel {
        var activity: MainActivity? = null
        scenario.onActivity { activity = it }
        return ViewModelProvider(activity!!)[AppViewModel::class.java]
    }

    private fun leaveAndReturn(scenario: ActivityScenario<MainActivity>, clock: MovableClock, away: Long) {
        scenario.moveToState(Lifecycle.State.CREATED)
        clock.now += away
        scenario.moveToState(Lifecycle.State.RESUMED)
    }

    /** Unlocked now, and still unlocked a moment later: no late relock flips it. */
    private suspend fun assertStaysUnlocked(vm: AppViewModel, phase: String) {
        composeRule.waitForIdle()
        assertFalse("$phase: locked", vm.isAppLocked)
        delay(1_000)
        composeRule.waitForIdle()
        assertFalse("$phase: locked a moment later", vm.isAppLocked)
        assertTrue(
            "$phase: lock screen showing",
            composeRule.onAllNodes(hasText("Enter PIN to unlock")).fetchSemanticsNodes().isEmpty(),
        )
    }

    /** Types the PIN into the real lock screen and submits it with the keyboard's Done. */
    private suspend fun unlock(vm: AppViewModel, pin: String) {
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodes(hasText("Enter PIN to unlock")).fetchSemanticsNodes().isNotEmpty() &&
                composeRule.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNode(hasSetTextAction()).performClick()
        composeRule.onNode(hasSetTextAction()).performTextClearance()
        composeRule.onNode(hasSetTextAction()).performTextInput(pin)
        await("PIN typed", 10_000) { vm.currentPinInput.length == pin.length }
        composeRule.onNode(hasSetTextAction()).performImeAction()
        await("PIN unlocks", 10_000) { !vm.isAppLocked }
        composeRule.waitForIdle()
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            delay(150)
        }
        throw AssertionError("Timed out waiting for: $label")
    }

    private companion object {
        const val MINUTE = 60_000L
        const val HOUR = 60 * MINUTE
    }
}
