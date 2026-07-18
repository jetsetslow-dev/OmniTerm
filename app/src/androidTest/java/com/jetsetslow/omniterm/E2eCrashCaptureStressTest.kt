package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.CrashLog
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Controlled debug startup failure through capture, redacted history display, recovery, and clear. */
class E2eCrashCaptureStressTest {
    @Test
    fun controlledStartupCrashIsRedactedRecoverableAndClearable() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_crash_capture") == "yes")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val device = E2eAccessibility(instrumentation)
        val previousHistory = CrashLog.all(context)
        val prefs = context.getSharedPreferences("startup_crash_report", Context.MODE_PRIVATE)
        val previousReport = prefs.getString("last_crash", null)
        val previousTime = prefs.getLong("last_crash_time", 0L)
        prefs.edit().clear().commit()
        CrashLog.clear(context)

        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .putExtra(MainActivity.EXTRA_E2E_FORCE_STARTUP_CRASH, true)
        val scenario = ActivityScenario.launch<MainActivity>(intent)
        try {
            await("startup recovery screen", 10_000) { device.hasText("OmniTerm could not start") }
            val captured = requireNotNull(prefs.getString("last_crash", null))
            assertRedacted(captured)
            val history = CrashLog.all(context)
            assertTrue(history.size == 1)
            assertRedacted(history.single().report)

            // This visible action clears the startup gate and retries the same Activity without
            // replaying the debug-only force-crash extra.
            device.clickText("Clear and try again")
            await("normal app after recovery", 20_000) { !device.hasText("OmniTerm could not start") }
            // Startup recovery clears only the launch gate; history deliberately remains available
            // to About after a successful retry. The broad surface suite renders that card. Here we
            // validate its exact persisted payload and clearing primitive without relying on a
            // device-specific nested-scroll accessibility implementation.
            assertTrue(CrashLog.all(context).single().report.contains("IllegalStateException"))
            CrashLog.clear(context)
            await("crash history cleared", 5_000) { CrashLog.all(context).isEmpty() }
        } finally {
            scenario.close()
            CrashLog.replace(context, previousHistory)
            val editor = prefs.edit().clear()
            if (previousReport != null) editor.putString("last_crash", previousReport).putLong("last_crash_time", previousTime)
            editor.commit()
        }
    }

    private fun assertRedacted(report: String) {
        listOf("hunter2", "e2e-token", "192.0.2.123", "/home/omnitermlab")
            .forEach { assertFalse("Sensitive crash value leaked: $it", report.contains(it)) }
        assertTrue(report.contains("<redacted>"))
        assertTrue(report.contains("IllegalStateException"))
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", e)
        }
    }
}
