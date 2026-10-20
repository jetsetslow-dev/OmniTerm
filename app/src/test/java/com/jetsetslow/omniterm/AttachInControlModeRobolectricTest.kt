package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * The connect card's "Attach in control mode" checkbox, ported from Flutter: a choice for the next
 * persistent session, not a saved setting. It starts at the Settings default and follows that
 * default again once the default changes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class AttachInControlModeRobolectricTest {

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    @Test
    fun theCheckboxOverridesTheDefaultUntilTheDefaultChanges() = runBlocking {
        // A real Main dispatcher, and the model cleared and awaited afterwards: a ViewModel left
        // running into the next class races its resetMain (see clearViewModelsAndAwaitTerminalJobs).
        val main = Executors.newSingleThreadExecutor { Thread(it, "control-mode-main") }.asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            withContext(main) {
                val model = AppViewModel(application)
                store.put("controlMode", model)
                assertFalse("starts at the Settings default", model.attachInControlMode)

                model.attachInControlMode = true
                assertTrue(model.attachInControlMode)
                assertFalse("the checkbox is not the saved setting", model.tmuxControlMode)

                model.saveTmuxControlMode(false)
                assertFalse("a change in Settings drops the one-off choice", model.attachInControlMode)

                model.saveTmuxControlMode(true)
                assertTrue("and the checkbox follows the new default", model.attachInControlMode)
            }
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
