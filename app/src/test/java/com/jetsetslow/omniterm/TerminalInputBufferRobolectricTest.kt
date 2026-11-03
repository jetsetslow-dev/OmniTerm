package com.jetsetslow.omniterm

import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.input.TextFieldValue
import com.jetsetslow.omniterm.ui.rememberTerminalInputBuffer
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Keys that reach the terminal's hidden field faster than it recomposes are each sent once. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class TerminalInputBufferRobolectricTest {

    @get:Rule val composeRule = createComposeRule()

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    /** The terminal's stream mode: send what each edit added, then hand the field back empty. */
    private fun typeInOneFrame(text: String, useBuffer: Boolean): String {
        val sent = StringBuilder()
        lateinit var view: View
        composeRule.setContent {
            view = LocalView.current
            val fieldState = remember { mutableStateOf(TextFieldValue("")) }
            var field by fieldState
            val buffer = rememberTerminalInputBuffer(Unit, fieldState)
            BasicTextField(
                value = field,
                onValueChange = { edit ->
                    val before = if (useBuffer) buffer.onEdit(edit.text) else field.text
                    sent.append(edit.text.removePrefix(before))
                    field = TextFieldValue("")
                },
                modifier = Modifier.testTag("sink"),
            )
        }
        composeRule.onNodeWithTag("sink").performSemanticsAction(SemanticsActions.RequestFocus)
        composeRule.waitForIdle()
        composeRule.runOnIdle {
            val connection = requireNotNull(view.onCreateInputConnection(EditorInfo()))
            text.forEach { connection.commitText(it.toString(), 1) }
        }
        composeRule.waitForIdle()
        return sent.toString()
    }

    @Test
    fun aBurstOfKeysIsSentOnce() {
        assertEquals("echo abc", typeInOneFrame("echo abc", useBuffer = true))
    }

    /** Keeps the test above honest: the keys really do land before the field takes its value back. */
    @Test
    fun diffingAgainstTheFieldStateResendsEarlierKeys() {
        assertEquals("eecechechoecho echo aecho abecho abc", typeInOneFrame("echo abc", useBuffer = false))
    }
}
