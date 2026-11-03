package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import com.jetsetslow.omniterm.ui.StatusDot
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A status dot is read out as a server's state only on a host. A stopped service or an unused
 * volume said "Server offline" to screen readers.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class StatusDotLabelsRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun onlyHostDotsSpeakOfServers() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
        composeTestRule.setContent {
            Column {
                StatusDot(online = true)
                StatusDot(online = false, contentDescription = "stopped")
                StatusDot(online = false, contentDescription = "")
            }
        }
        fun count(label: String) = composeTestRule.onAllNodesWithContentDescription(label).fetchSemanticsNodes().size
        assertEquals(1, count("Server online"))
        assertEquals(1, count("stopped"))
        assertEquals(0, count("Server offline"))
    }
}
