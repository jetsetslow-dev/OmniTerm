package com.jetsetslow.omniterm

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.performTextInput
import com.jetsetslow.omniterm.ui.PathTextField
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
 * The Files path bar and the bookmark editor open their path field to be typed in: it used to
 * need a second tap before the keyboard came up. Typing goes to the end of the path, and a line
 * break never gets in.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class PathTextFieldRobolectricTest {

    @get:Rule val composeRule = createComposeRule()

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    private fun show(autofocus: Boolean) {
        composeRule.setContent {
            MyApplicationTheme {
                var path by remember { mutableStateOf("/srv/data") }
                PathTextField(value = path, onValueChange = { path = it }, autofocus = autofocus)
            }
        }
        composeRule.waitForIdle()
    }

    @Test
    fun anOpenedPathFieldTakesTheKeyboard() {
        show(autofocus = true)
        val field = composeRule.onNode(hasSetTextAction())
        field.assertIsFocused()
        field.performTextInput("/logs\n")
        field.assertTextEquals("/srv/data/logs")
    }

    @Test
    fun otherPathFieldsWaitForATap() {
        show(autofocus = false)
        composeRule.onNode(hasSetTextAction()).assertIsNotFocused()
    }
}
