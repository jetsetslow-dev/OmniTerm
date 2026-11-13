package com.jetsetslow.omniterm

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.hashPinForStorage
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Setup for App Lock runs driven from the host with real time, `am kill`, force stop and reboots,
 * which cannot run inside an instrumentation (they would end it too). It touches only settings and
 * the window's record file by name, so it also seeds builds from before that record existed.
 *
 * ```
 * adb shell am instrument -w -e omniterm_e2e_applock_seed yes -e pin <digits> -e grace_ms 30000 \
 *   [-e keep_alive true|false] -e class com.jetsetslow.omniterm.E2eAppLockSeed#seed $R
 * adb shell am instrument -w -e omniterm_e2e_applock_unseed yes \
 *   -e class com.jetsetslow.omniterm.E2eAppLockSeed#unseed $R
 * ```
 */
class E2eAppLockSeed {
    private val lockKeys = listOf(
        "app_pin", "app_lock_enabled", "biometrics_enabled",
        "pin_failed_attempts", "pin_locked_until", "app_lock_grace_ms",
    )

    @Test
    fun seed() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_applock_seed") == "yes")
        val pin = requireNotNull(args.getString("pin")) { "-e pin is required" }
        val grace = requireNotNull(args.getString("grace_ms")?.toLongOrNull()) { "-e grace_ms is required" }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        repository.insertSetting("app_pin", hashPinForStorage(pin))
        repository.insertSetting("app_lock_enabled", "true")
        repository.insertSetting("biometrics_enabled", "false")
        repository.insertSetting("pin_failed_attempts", "0")
        repository.insertSetting("pin_locked_until", "0")
        repository.insertSetting("app_lock_grace_ms", grace.toString())
        repository.insertSetting("first_run_complete", "true")
        args.getString("keep_alive")?.let { repository.insertSetting("background_keep_alive", it) }
        forgetWindow(context)
    }

    @Test
    fun unseed() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_applock_unseed") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        for (key in lockKeys) repository.deleteSetting(key)
        forgetWindow(context)
    }

    private fun forgetWindow(context: Context) {
        context.getSharedPreferences("app_lock_away", Context.MODE_PRIVATE).edit().clear().commit()
    }
}
