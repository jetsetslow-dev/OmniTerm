package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.jetsetslow.omniterm.ui.CodeEditor
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Find and replace in a read-only editor: the Replace row is shown, as before, but its buttons are
 * disabled. They used to be enabled whenever the query matched, and did nothing when tapped.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class CodeEditorReadOnlyRobolectricTest {

    @get:Rule val composeRule = createComposeRule()

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    private fun searchFor(readOnly: Boolean) {
        composeRule.setContent {
            MyApplicationTheme { CodeEditor(value = "keep this line", onValueChange = {}, readOnly = readOnly) }
        }
        composeRule.onNodeWithContentDescription("Find / replace").performClick()
        composeRule.onNode(hasSetTextAction() and hasAnySibling(hasText("Find"))).performTextInput("this")
        composeRule.waitForIdle()
    }

    @Test
    fun replaceIsDisabledWhenTheTextCannotChange() {
        searchFor(readOnly = true)
        composeRule.onNode(hasText("Replace") and hasClickAction()).assertIsNotEnabled()
        composeRule.onNode(hasText("All") and hasClickAction()).assertIsNotEnabled()
    }

    @Test
    fun replaceIsEnabledInAnEditableEditor() {
        searchFor(readOnly = false)
        composeRule.onNode(hasText("Replace") and hasClickAction()).assertIsEnabled()
    }
}
