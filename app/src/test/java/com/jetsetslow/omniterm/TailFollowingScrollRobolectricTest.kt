package com.jetsetslow.omniterm

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.rememberTailFollowingScrollState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A Fleet broadcast box stayed on its first line while 150 lines streamed in. Streamed output
 * follows its end, stops following while the user reads further up, and follows again once they
 * scroll back to the end.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class TailFollowingScrollRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    private var text by mutableStateOf("Waiting for output...")
    private var measured by mutableStateOf(true)
    private lateinit var scroll: ScrollState

    /** Laid out like a broadcast host's box, which first shows a one-line placeholder. */
    private fun showBox() {
        composeTestRule.setContent {
            scroll = rememberTailFollowingScrollState()
            // Holds the box back from measurement while [measured] is false, as a list does with an
            // item it composes ahead of showing it.
            Layout(content = {
                Box(Modifier.fillMaxWidth().heightIn(min = 72.dp, max = 260.dp).verticalScroll(scroll)) {
                    Text(text, fontSize = 12.sp)
                }
            }) { measurables, constraints ->
                if (!measured) return@Layout layout(0, 0) {}
                val box = measurables.single().measure(constraints)
                layout(box.width, box.height) { box.place(0, 0) }
            }
        }
    }

    private fun stream(from: Int, to: Int) {
        for (i in from..to) {
            text = if (i == 1) "line 1" else text + "\nline $i"
            composeTestRule.waitForIdle()
        }
    }

    private fun scrollTo(position: Int) {
        composeTestRule.runOnUiThread { runBlocking { scroll.scrollTo(position) } }
        composeTestRule.waitForIdle()
    }

    @Test
    fun streamedOutputShowsItsNewestLines() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showBox()
        stream(1, 150)
        assertTrue("the output overflows the box", scroll.maxValue > 0)
        assertEquals(scroll.maxValue, scroll.value)
    }

    @Test
    fun aBoxComposedBeforeItsFirstLayoutStillFollows() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        measured = false
        showBox()
        composeTestRule.waitForIdle()
        measured = true
        composeTestRule.waitForIdle()
        stream(1, 150)
        assertTrue("the output overflows the box", scroll.maxValue > 0)
        assertEquals(scroll.maxValue, scroll.value)
    }

    @Test
    fun aNewRunFollowsAfterTheLastWasReadFromTheTop() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showBox()
        stream(1, 60)
        scrollTo(0)
        // The host runs again: its card clears, then streams the new output.
        text = "Waiting for output..."
        composeTestRule.waitForIdle()
        stream(1, 60)
        assertEquals(scroll.maxValue, scroll.value)
    }

    @Test
    fun outputArrivingFasterThanItScrollsStillShowsItsNewestLines() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        composeTestRule.mainClock.autoAdvance = false
        showBox()
        composeTestRule.mainClock.advanceTimeByFrame()
        // A chunk per frame, as a fast command streams: each layout grows the extent again before
        // the previous scroll to the end has been seen.
        for (i in 1..150) {
            text = if (i == 1) "line 1" else text + "\nline $i"
            composeTestRule.mainClock.advanceTimeByFrame()
        }
        composeTestRule.mainClock.autoAdvance = true
        composeTestRule.waitForIdle()
        assertTrue("the output overflows the box", scroll.maxValue > 0)
        assertEquals(scroll.maxValue, scroll.value)
    }

    @Test
    fun readingFurtherUpStopsFollowingUntilBackAtTheEnd() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showBox()
        stream(1, 60)
        scrollTo(scroll.maxValue / 3)
        val reading = scroll.value
        stream(61, 90)
        assertEquals("left where the user is reading", reading, scroll.value)

        scrollTo(scroll.maxValue)
        stream(91, 120)
        assertEquals(scroll.maxValue, scroll.value)
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
