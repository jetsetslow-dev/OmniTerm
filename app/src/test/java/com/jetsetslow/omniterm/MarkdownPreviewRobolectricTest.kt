package com.jetsetslow.omniterm

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.text.TextRange
import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.ui.EDITOR_PREVIEW_TOGGLE_TAG
import com.jetsetslow.omniterm.ui.EditorDraftSlot
import com.jetsetslow.omniterm.ui.SftpFileEditor
import com.jetsetslow.omniterm.ui.markdown.LINK_ADDRESS_TAG
import com.jetsetslow.omniterm.ui.markdown.LINK_OPEN_TAG
import com.jetsetslow.omniterm.ui.markdown.LINK_QUESTION_TAG
import com.jetsetslow.omniterm.ui.markdown.MARKDOWN_LIST_TAG
import com.jetsetslow.omniterm.ui.markdown.MARKDOWN_PREVIEW_MAX_CHARS
import com.jetsetslow.omniterm.ui.markdown.MarkdownPreview
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
 * The file editor's Markdown preview on screen: a link opens only after its whole address has been
 * shown and Open chosen, other links are plain text, images are not loaded, and switching between
 * the preview and the text keeps the unsaved text, the cursor and the selection.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class MarkdownPreviewRobolectricTest {

    @get:Rule val composeRule = createComposeRule()

    @Before
    fun skipOnAarch64() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
    }

    private val opened = mutableListOf<String>()

    private fun preview(text: String) {
        composeRule.setContent {
            MyApplicationTheme { MarkdownPreview(text = text, onOpenLink = { opened += it }) }
        }
        waitForPreview()
    }

    private fun waitForPreview() {
        composeRule.waitUntil(10_000) { composeRule.onAllNodesWithTag(MARKDOWN_LIST_TAG).fetchSemanticsNodes().isNotEmpty() }
        composeRule.waitForIdle()
    }

    private fun questionShown() = composeRule.onAllNodesWithTag(LINK_QUESTION_TAG).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun aLinkAsksFirstAndOpensOnlyOnOpen() {
        val url = "https://example.org/a-rather-long/path?with=query&and=more#and-a-fragment"
        preview("[the docs]($url)")
        composeRule.onNodeWithText("the docs").performClick()
        composeRule.waitForIdle()
        assertThat(questionShown()).isTrue()
        composeRule.onNodeWithTag(LINK_ADDRESS_TAG).assert(hasText(url))
        assertThat(opened).isEmpty()
        composeRule.onNodeWithText("Cancel").performClick()
        composeRule.waitForIdle()
        assertThat(questionShown()).isFalse()
        assertThat(opened).isEmpty()

        composeRule.onNodeWithText("the docs").performClick()
        composeRule.onNodeWithTag(LINK_OPEN_TAG).performClick()
        composeRule.waitForIdle()
        assertThat(opened).containsExactly(url)
        assertThat(questionShown()).isFalse()
    }

    @Test
    fun aLinkToAnythingButTheWebOrMailIsPlainText() {
        preview("[run me](javascript:alert(1))")
        composeRule.onNodeWithText("run me").performClick()
        composeRule.waitForIdle()
        assertThat(questionShown()).isFalse()
        assertThat(opened).isEmpty()
    }

    @Test
    fun anImageShowsItsAltTextAndThatItWasNotLoaded() {
        preview("![The logo](https://tracker.example/pixel.png)\n\n<script>alert(1)</script>\n")
        composeRule.onNodeWithText("The logo image not loaded").assertIsDisplayed()
        composeRule.onNodeWithText("<script>alert(1)</script>").assertIsDisplayed()
    }

    @Test
    fun aFileOverTheLimitSaysSo() {
        composeRule.setContent {
            MyApplicationTheme { MarkdownPreview(text = "x".repeat(MARKDOWN_PREVIEW_MAX_CHARS + 1), onOpenLink = { opened += it }) }
        }
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodes(hasText("too large to preview", substring = true)).fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("200,000", substring = true).assertExists()
    }

    private fun editor(name: String, content: String) {
        val slot = EditorDraftSlot()
        val file = SftpFile(name, isDirectory = false, size = content.length.toLong(), modDate = "", content = content)
        composeRule.setContent {
            MyApplicationTheme {
                SftpFileEditor(
                    file = file,
                    saving = false,
                    error = null,
                    sudo = false,
                    onToggleSudo = {},
                    onSave = {},
                    onDismiss = {},
                    confirm = rememberConfirm(),
                    draftSlot = slot,
                )
            }
        }
        composeRule.waitForIdle()
    }

    private fun selection(): TextRange? = composeRule.onNodeWithTag("code-editor-input").fetchSemanticsNode()
        .config.getOrNull(SemanticsProperties.TextSelectionRange)

    @Test
    fun aTextFileOffersNoPreview() {
        editor("notes.txt", "# not offered")
        assertThat(composeRule.onAllNodesWithTag(EDITOR_PREVIEW_TOGGLE_TAG).fetchSemanticsNodes()).isEmpty()
    }

    @Test
    fun aReadmeOffersThePreview() {
        editor("README", "# offered")
        composeRule.onNodeWithTag(EDITOR_PREVIEW_TOGGLE_TAG).assertExists()
    }

    @Test
    fun thePreviewShowsUnsavedTextAndLeavingItKeepsTheEditorAsItWas() {
        editor("guide.md", "# Guide\n\nFirst line\n")
        composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").performClick()
        composeRule.onNodeWithTag("code-editor-input").performTextInputSelection(TextRange(0))
        composeRule.onNodeWithTag("code-editor-input").performTextInput("Unsaved words\n\n")
        composeRule.onNodeWithTag("code-editor-input").performTextInputSelection(TextRange(2, 9))
        composeRule.waitForIdle()
        val before = selection()
        assertThat(before).isEqualTo(TextRange(2, 9))
        composeRule.onNodeWithText("guide.md •", substring = true).assertExists()

        composeRule.onNodeWithTag(EDITOR_PREVIEW_TOGGLE_TAG).performClick()
        waitForPreview()
        composeRule.onNodeWithText("Unsaved words").assertIsDisplayed()
        composeRule.onNodeWithText("Guide").assertIsDisplayed()
        assertThat(composeRule.onAllNodes(hasText(" · preview", substring = true)).fetchSemanticsNodes()).isNotEmpty()
        // The text underneath is out of reach while the preview shows.
        assertThat(composeRule.onAllNodes(hasTestTag("code-editor-input")).fetchSemanticsNodes()).isEmpty()

        composeRule.onNodeWithTag(EDITOR_PREVIEW_TOGGLE_TAG).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("code-editor-input").assert(hasText("Unsaved words\n\n# Guide\n\nFirst line\n"))
        assertThat(selection()).isEqualTo(before)
        composeRule.onNodeWithText("guide.md •", substring = true).assertExists()
        composeRule.onNodeWithContentDescription("Edit mode: on").assertExists()
    }

    @Test
    fun turningEditingOnLeavesThePreview() {
        editor("guide.md", "# Guide\n")
        composeRule.onNodeWithTag(EDITOR_PREVIEW_TOGGLE_TAG).performClick()
        waitForPreview()
        composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").performClick()
        composeRule.waitForIdle()
        assertThat(composeRule.onAllNodesWithTag(MARKDOWN_LIST_TAG).fetchSemanticsNodes()).isEmpty()
        composeRule.onNodeWithTag("code-editor-input").assertExists()
    }
}
