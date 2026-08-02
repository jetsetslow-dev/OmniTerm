package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performSemanticsAction
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
                // Both panes need an explicit height. The frame wraps its content, the content here
                // is empty, and a Row aligns children to the top rather than stretching them, so
                // without fillMaxHeight each pane lays out zero-height and assertIsDisplayed fails
                // on a frame that is in fact correct.
                Row(Modifier.fillMaxSize()) {
                    TerminalPaneFrame(
                        paneIndex = 1,
                        label = "bash-host",
                        isFocused = focusedPane == 1,
                        onRequestFocus = { focusedPane = 1 },
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                    ) {}
                    TerminalPaneFrame(
                        paneIndex = 2,
                        label = "claude-host",
                        isFocused = focusedPane == 2,
                        onRequestFocus = { focusedPane = 2 },
                        modifier = Modifier.weight(1f).fillMaxHeight(),
                    ) {}
                }
            }
        }

        val left = composeTestRule.onNodeWithContentDescription("Terminal pane 1: bash-host")
        val right = composeTestRule.onNodeWithContentDescription("Terminal pane 2: claude-host")
        left.assertIsDisplayed().assertIsSelected()
        right.assertIsDisplayed().assertIsNotSelected()

        // Drive the semantics action, not a synthesized tap. The frame exposes focus through
        // `semantics { onClick { ... } }` for accessibility services and deliberately carries no
        // pointer-input modifier of its own -- real taps are handled by the terminal content it
        // wraps. performClick() injects a gesture that nothing here consumes, so it silently left
        // focus unchanged and the switching this test exists to cover was never exercised.
        fun SemanticsNodeInteraction.focusPane() = performSemanticsAction(SemanticsActions.OnClick)

        repeat(20) { switch ->
            if (switch % 2 == 0) right.focusPane() else left.focusPane()
        }

        left.assertIsSelected()
        right.assertIsNotSelected()
        right.focusPane()
        right.assertIsSelected()
        left.assertIsNotSelected()
    }
}
