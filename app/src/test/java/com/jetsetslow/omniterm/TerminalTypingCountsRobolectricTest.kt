package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ShellSession
import com.jetsetslow.omniterm.ui.TerminalInputQueue
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import com.jetsetslow.omniterm.ui.TerminalTypingBanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors

/** Typing to one terminal reads as one: "Typing to 1 terminal", not "1 terminals". */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalTypingCountsRobolectricTest {
    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun theBannerCountsOneTerminalAsOne() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val (model, one, two) = runBlocking {
                withContext(main) {
                    TerminalSessionManager.clearAll()
                    val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
                    store.put("typing", model)
                    val one = shell("one")
                    val two = shell("two")
                    model.currentSessionId = one.id
                    model.selectTerminalTyping(setOf(one.id))
                    Triple(model, one, two)
                }
            }
            composeTestRule.setContent { Column { TerminalTypingBanner(model, one) } }
            composeTestRule.onNodeWithText("Typing to 1 terminal · tap for hosts").assertExists()
            runBlocking { withContext(main) { model.selectTerminalTyping(setOf(one.id, two.id)) } }
            composeTestRule.onNodeWithText("Typing to 2 terminals · tap for hosts").assertExists()
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    /** The paste confirmation, its title and the sent note count as the banner does. */
    @Test
    fun pasteCountsReadAsOneOrMany() {
        val resources = ApplicationProvider.getApplicationContext<Application>().resources
        assertEquals("Paste 1 character?", resources.getQuantityString(R.plurals.paste_characters, 1, 1))
        assertEquals("Paste 12 characters?", resources.getQuantityString(R.plurals.paste_characters, 12, 12))
        assertEquals(true, resources.getQuantityString(R.plurals.typing_paste_confirmation, 1, 1).startsWith("Paste into 1 terminal? "))
        assertEquals(true, resources.getQuantityString(R.plurals.typing_paste_confirmation, 3, 3).startsWith("Paste into 3 terminals? "))
        assertEquals("Sent 1 character to terminal.", resources.getQuantityString(R.plurals.terminal_paste_sent, 1, 1))
        assertEquals("Sent 9000 characters to terminal.", resources.getQuantityString(R.plurals.terminal_paste_sent, 9000, 9000))
    }

    private fun shell(name: String): ShellSession = ShellSession(0, name, TypingFixtureTransport(), TerminalEmulator()).apply {
        terminalInputQueue = TerminalInputQueue()
        TerminalSessionManager.addSession(this)
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
