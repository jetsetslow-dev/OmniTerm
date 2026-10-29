package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.jetsetslow.omniterm.ui.ageText
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A session started in the last minute read "Started just now ago" in the session pickers and the
 * Attach tmux dialog, because the age itself said "just now". Every age line now goes through
 * `ageText`, which has a whole "just now" string for the first minute.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class AgeTextRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun theFirstMinuteReadsJustNowAndLaterAgesReadAgo() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val now = 1_800_000_000_000L
        composeTestRule.setContent {
            Column {
                Text(ageText(R.string.started_ago, R.string.started_just_now, now - 59_000L, now))
                Text(ageText(R.string.backgrounded_ago, R.string.backgrounded_just_now, now - 1_000L, now))
                Text(ageText(R.string.last_seen_ago, R.string.last_seen_just_now, now + 5_000L, now))
                Text(ageText(R.string.started_ago, R.string.started_just_now, now - 60_000L, now))
                Text(ageText(R.string.backgrounded_ago, R.string.backgrounded_just_now, now - (3 * 60 + 4) * 60_000L, now))
                Text(ageText(R.string.last_seen_ago, R.string.last_seen_just_now, now - (2 * 24 + 7) * 3_600_000L, now))
            }
        }

        composeTestRule.onNodeWithText("Started just now").assertExists()
        composeTestRule.onNodeWithText("backgrounded just now").assertExists()
        // A time ahead of the clock (set back since) is just now too.
        composeTestRule.onNodeWithText("Last seen just now").assertExists()
        composeTestRule.onNodeWithText("Started 1m ago").assertExists()
        composeTestRule.onNodeWithText("backgrounded 3h 04m ago").assertExists()
        composeTestRule.onNodeWithText("Last seen 2d 07h ago").assertExists()
        composeTestRule.onNodeWithText("just now ago", substring = true).assertDoesNotExist()
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
