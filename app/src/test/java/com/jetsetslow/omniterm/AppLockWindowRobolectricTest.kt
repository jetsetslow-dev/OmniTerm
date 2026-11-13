package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.ui.AppLockAwayRecord
import com.jetsetslow.omniterm.ui.AppLockAwayStore
import com.jetsetslow.omniterm.ui.AppLockClock
import com.jetsetslow.omniterm.ui.AppLockGrace
import com.jetsetslow.omniterm.ui.AppLockGraceWindow
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.EditorDraftSlot
import com.jetsetslow.omniterm.ui.PreviousExit
import com.jetsetslow.omniterm.ui.SftpFileEditor
import com.jetsetslow.omniterm.ui.hashPinForStorage
import com.jetsetslow.omniterm.ui.rememberConfirm
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors

/**
 * The ViewModel's side of App Lock's window: a new ViewModel (a rebuilt screen, or a new process
 * after Android closed the old one) starts unlocked within the window and locked after it, and a
 * relock keeps the editor's unsaved text. The clock and the record store are injected; no real
 * time passes.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AppLockWindowRobolectricTest {

    @get:Rule val composeRule = createComposeRule()
    @get:Rule val keyStore = TestAndroidKeyStore()

    private class FakeClock(var now: Long = 3_600_000L) : AppLockClock {
        override fun elapsedRealtimeMs() = now
        override fun bootCount(): Int? = 12
    }

    private class MemoryStore : AppLockAwayStore {
        var record: AppLockAwayRecord? = null
        override fun read() = record
        override fun write(record: AppLockAwayRecord) { this.record = record }
        override fun clear() { record = null }
    }

    private val clock = FakeClock()
    private val store = MemoryStore()
    private var pid = 1000

    /** A new process: a new window over the same store, as after Android closed the last one. */
    private fun newProcess(exit: PreviousExit = PreviousExit.CLOSED_BY_SYSTEM) {
        pid += 1
        AppLockGrace.replaceForTests(
            AppLockGraceWindow(clock, store, { exit }, pid = pid, installStamp = 5L),
        )
    }

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    @After
    fun restoreWindow() {
        AppLockGrace.replaceForTests(null)
    }

    @Test
    fun aNewProcessWithinTheWindowStartsUnlockedAndAfterItLocked() {
        for (minutes in listOf(10L, 60L)) {
            val timeout = minutes * 60_000L
            withLock(timeout) { open ->
                newProcess()
                val first = open()
                assertTrue("$minutes min: a first start with no window locks", first.isAppLocked)
                withContext(main) { first.biometricSuccessUnlock() }
                withContext(main) { first.noteAppBackgrounded() }
                assertNotNull("leaving unlocked writes the record", store.record)

                clock.now += timeout - 60_000L
                newProcess()
                val second = open()
                assertFalse("$minutes min: reopened 1 min inside the window", second.isAppLocked)
                assertNull("the record is used once", store.record)

                withContext(main) { second.noteAppBackgrounded() }
                clock.now += timeout
                newProcess()
                assertTrue("$minutes min: reopened at the end of the window", open().isAppLocked)
            }
        }
    }

    @Test
    fun aRebuiltScreenInTheSameProcessKeepsTheWindow() {
        withLock(60 * 60_000L) { open ->
            newProcess()
            val first = open()
            withContext(main) { first.biometricSuccessUnlock() }
            withContext(main) { first.noteAppBackgrounded() }
            clock.now += 59 * 60_000L
            // Same process: Don't keep activities, Back to exit, or the task removed while the
            // keep-alive service ran, then reopened from its notification.
            assertFalse(open().isAppLocked)
        }
    }

    @Test
    fun aForceStopOrCrashLocksWithinTheWindow() {
        withLock(60 * 60_000L) { open ->
            newProcess()
            val first = open()
            withContext(main) { first.biometricSuccessUnlock() }
            withContext(main) { first.noteAppBackgrounded() }
            clock.now += 60_000L
            newProcess(exit = PreviousExit.LOCKS)
            assertTrue(open().isAppLocked)
        }
    }

    @Test
    fun lockNowLocksAndLeavesNoWindow() {
        withLock(60 * 60_000L) { open ->
            newProcess()
            val first = open()
            withContext(main) { first.biometricSuccessUnlock() }
            withContext(main) { first.lockApp() }
            assertTrue(first.isAppLocked)
            withContext(main) { first.noteAppBackgrounded() }
            assertNull("leaving while locked writes nothing", store.record)
            clock.now += 60_000L
            assertTrue(open().isAppLocked)
        }
    }

    @Test
    fun aRelockKeepsTheEditorsUnsavedText() {
        val slot = EditorDraftSlot()
        val file = SftpFile("app.conf", isDirectory = false, size = 9, modDate = "", content = "port=22\n")
        var locked by mutableStateOf(false)
        composeRule.setContent {
            MyApplicationTheme {
                // The same shape as the app's gate: locking takes the editor out of the screen.
                if (locked) {
                    Text("Enter PIN to unlock")
                } else {
                    SftpFileEditor(
                        file = file,
                        saving = false,
                        error = null,
                        sudo = false,
                        onToggleSudo = {},
                        onSave = {},
                        onDismiss = {},
                        confirm = rememberConfirm(),
                        draftSlot = slot,
                    )
                }
            }
        }
        composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").performClick()
        composeRule.onNodeWithTag("code-editor-input").performTextReplacement("port=2222\n")
        composeRule.waitForIdle()

        locked = true
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Enter PIN to unlock").assertExists()
        locked = false
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("code-editor-input").assertTextEquals("port=2222\n")
        composeRule.onNodeWithContentDescription("Edit mode: on").assertExists()
        assertEquals("port=2222\n", slot.draftFor(file).text)
    }

    @Test
    fun aNewlyOpenedFileGetsItsOwnContent() {
        val slot = EditorDraftSlot()
        val first = SftpFile("a.txt", isDirectory = false, size = 1, modDate = "", content = "a")
        slot.draftFor(first).text = "edited"
        assertEquals("edited", slot.draftFor(first).text)
        // Opening the same file again reads it afresh and makes a new object: a new draft.
        val reopened = first.copy()
        assertEquals("a", slot.draftFor(reopened).text)
        slot.draftFor(reopened).text = "x"
        slot.clear()
        assertEquals("a", slot.draftFor(reopened).text)
    }

    private lateinit var main: CoroutineDispatcher

    /**
     * App Lock on with a PIN and [timeoutMs]; [block] gets `open`, which builds a ViewModel the way
     * a new screen does and waits until it has decided whether it starts locked.
     */
    private fun withLock(timeoutMs: Long, block: suspend (open: suspend () -> AppViewModel) -> Unit) = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        main = executor.asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repository = AppRepository(AppDatabase.getDatabase(application))
        try {
            repository.insertSetting("app_pin", hashPinForStorage("4826"))
            repository.insertSetting("app_lock_enabled", "true")
            repository.insertSetting("biometrics_enabled", "false")
            repository.insertSetting("app_lock_grace_ms", timeoutMs.toString())
            var n = 0
            block {
                val model = withContext(main) { AppViewModel(application) }
                store.put("vm${n++}", model)
                waitWhileOnMain(main, 10_000) { !model.securitySettingsLoaded }
                model
            }
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                for (key in listOf("app_pin", "app_lock_enabled", "biometrics_enabled", "app_lock_grace_ms")) {
                    repository.deleteSetting(key)
                }
                Dispatchers.resetMain()
                executor.shutdown()
            }
        }
    }
}
