package com.jetsetslow.omniterm

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.ui.AppViewModel
import org.junit.Assert.assertNull
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Cold-start smoke tests: opening the app must reach the real UI without crashing.
 *
 * Guards the whole class of construction-order bugs — e.g. AppViewModel's init collects the
 * allSettings StateFlow synchronously on Main.immediate, so an assignment to a mutableStateOf
 * property declared below the init block hits a null delegate and NPEs (shipped as the 0.9.207
 * startup crash). Like the other Robolectric classes this is excluded on Linux aarch64 hosts
 * (build.gradle.kts) and runs in CI, where it gates both PR checks and releases.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ColdStartRobolectricTest {

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    @Test
    fun appViewModel_constructs_without_crashing() {
        // Construction runs the init block on the main thread exactly like a real cold start:
        // viewModelScope is Main.immediate, so launched blocks execute undispatched up to their
        // first suspension, inside the constructor. Any init-order bug throws right here.
        AppViewModel(ApplicationProvider.getApplicationContext<Application>())
    }

    @Test
    fun mainActivity_cold_start_shows_app_not_crash_screen() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        // MainActivity.onCreate catches startup throwables, records them in the crash prefs and
        // shows the crash-report screen instead of dying — so "setup() didn't throw" is not
        // enough; an empty crash record is the actual success signal.
        val prefs = activity.getSharedPreferences("startup_crash_report", Context.MODE_PRIVATE)
        assertNull(
            "Cold start crashed; the in-app recorder captured:\n${prefs.getString("last_crash", null)}",
            prefs.getString("last_crash", null),
        )
    }
}
