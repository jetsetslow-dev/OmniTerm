package com.jetsetslow.omniterm.data

import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.hashPinForStorage
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device/emulator coverage for the lifecycle boundary that plain JVM policy tests cannot exercise.
 * It intentionally lives in the data test package so the required PR Android gate runs it beside
 * the Room matrix on every build-affecting change.
 */
@RunWith(AndroidJUnit4::class)
class AppLockLifecycleIntegrationTest {
    private val touchedKeys = listOf(
        "app_pin",
        "app_lock_enabled",
        "biometrics_enabled",
        "app_lock_grace_ms",
        "pin_failed_attempts",
        "pin_locked_until",
        "first_run_complete",
    )

    /**
     * A covered Activity never reaches RESUMED, so `recreate()` below would stall in STOPPED until
     * ActivityScenario times out. CI emulators have no lockscreen, but a real test device usually
     * does — and when it is secured with a PIN/pattern, `wm dismiss-keyguard` cannot clear it
     * (`deviceLocked` stays 1). Asking the window to show over the keyguard works either way and
     * needs no credential.
     */
    private fun showOverKeyguard(scenario: ActivityScenario<MainActivity>) {
        scenario.onActivity { activity ->
            activity.setShowWhenLocked(true)
            activity.setTurnScreenOn(true)
        }
    }

    private fun wakeScreen(instrumentation: android.app.Instrumentation) {
        listOf("input keyevent KEYCODE_WAKEUP", "wm dismiss-keyguard").forEach { command ->
            runCatching { instrumentation.uiAutomation.executeShellCommand(command).close() }
        }
        SystemClock.sleep(1_000L)
    }

    @Test
    fun zeroTimeoutRelocksAfterBackgroundButNotConfigurationChange() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        wakeScreen(instrumentation)
        val context = instrumentation.targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val before = repository.getAllSettings()
            .filter { it.key in touchedKeys }
            .associateBy { it.key }
        var scenario: ActivityScenario<MainActivity>? = null

        try {
            repository.insertSetting("app_pin", hashPinForStorage("4826"))
            repository.insertSetting("app_lock_enabled", "true")
            repository.insertSetting("biometrics_enabled", "false")
            repository.insertSetting("app_lock_grace_ms", "0")
            repository.insertSetting("pin_failed_attempts", "0")
            repository.insertSetting("pin_locked_until", "0")
            repository.insertSetting("first_run_complete", "true")

            scenario = ActivityScenario.launch(MainActivity::class.java)
            showOverKeyguard(scenario)
            lateinit var viewModel: AppViewModel
            scenario.onActivity { activity ->
                viewModel = ViewModelProvider(activity)[AppViewModel::class.java]
            }
            await("cold-start lock") { viewModel.isAppLocked }

            scenario.onActivity {
                "4826".forEach { digit -> viewModel.handlePinTyping(digit.toString()) }
            }
            await("PIN unlock") { !viewModel.isAppLocked }

            // Activity recreation invokes onStop, but isChangingConfigurations must prevent it
            // from starting the background timer.
            scenario.recreate()
            // The recreated Activity is a new instance and does not inherit the flag.
            showOverKeyguard(scenario)
            instrumentation.waitForIdleSync()
            assertFalse("configuration change re-locked the app", viewModel.isAppLocked)

            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            await("zero-timeout warm relock") { viewModel.isAppLocked }
            assertTrue(viewModel.isAppLocked)
        } finally {
            scenario?.close()
            for (key in touchedKeys) {
                val original = before[key]
                if (original == null) repository.deleteSetting(key)
                else repository.insertSetting(key, original.value)
            }
        }
    }

    private fun await(label: String, timeoutMs: Long = 10_000L, condition: () -> Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            instrumentation.waitForIdleSync()
            if (condition()) return
            SystemClock.sleep(50L)
        }
        throw AssertionError("Timed out waiting for $label")
    }
}
