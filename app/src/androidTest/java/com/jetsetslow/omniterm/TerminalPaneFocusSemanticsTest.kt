package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import com.jetsetslow.omniterm.ui.TerminalPaneFrame
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Rule
import org.junit.Test

class TerminalPaneFocusSemanticsTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun rapidPaneSwitchingMovesActiveSemanticsWithoutChangingLabels() {
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                var focusedPane by remember { mutableIntStateOf(1) }
                Row(Modifier.fillMaxSize()) {
                    TerminalPaneFrame(
                        paneIndex = 1,
                        label = "bash-host",
                        isFocused = focusedPane == 1,
                        onRequestFocus = { focusedPane = 1 },
                        modifier = Modifier.weight(1f),
                    ) {}
                    TerminalPaneFrame(
                        paneIndex = 2,
                        label = "claude-host",
                        isFocused = focusedPane == 2,
                        onRequestFocus = { focusedPane = 2 },
                        modifier = Modifier.weight(1f),
                    ) {}
                }
            }
        }

        val left = composeTestRule.onNodeWithContentDescription("Terminal pane 1: bash-host")
        val right = composeTestRule.onNodeWithContentDescription("Terminal pane 2: claude-host")
        left.assertIsDisplayed().assertIsSelected()
        right.assertIsDisplayed().assertIsNotSelected()

        repeat(20) { switch ->
            if (switch % 2 == 0) right.performClick() else left.performClick()
        }

        left.assertIsSelected()
        right.assertIsNotSelected()
        right.performClick().assertIsSelected()
        left.assertIsNotSelected()
    }
}
