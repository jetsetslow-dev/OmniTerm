package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.ui.SftpFileEditor
import com.jetsetslow.omniterm.ui.rememberConfirm
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
 * A file opens read-only, so a stray keystroke cannot change it, unless it is empty: a file just
 * made with New file opened read-only too, one tap short of typing into it. Its text area was also
 * one line tall, so a tap anywhere below that line did nothing.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class FileEditorStartModeRobolectricTest {

    @get:Rule val composeRule = createComposeRule()

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    private fun open(content: String) {
        composeRule.setContent {
            MyApplicationTheme {
                SftpFileEditor(
                    file = SftpFile("notes.txt", isDirectory = false, size = content.length.toLong(), modDate = "", content = content),
                    saving = false,
                    error = null,
                    sudo = false,
                    onToggleSudo = {},
                    onSave = {},
                    onDismiss = {},
                    confirm = rememberConfirm(),
                )
            }
        }
        composeRule.waitForIdle()
    }

    @Test
    fun aFileWithTextOpensReadOnly() {
        open("keep this line")
        composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").assertExists()
    }

    @Test
    fun anEmptyFileOpensReadyToType() {
        open("")
        composeRule.onNodeWithContentDescription("Edit mode: on").assertExists()
    }

    @Test
    fun anEmptyFileTakesATapAnywhereInTheEditor() {
        open("")
        val input = composeRule.onNodeWithTag("code-editor-input").fetchSemanticsNode().boundsInRoot
        val screen = composeRule.onRoot().fetchSemanticsNode().boundsInRoot
        assertThat(input.height).isGreaterThan(screen.height / 2)
    }
}
