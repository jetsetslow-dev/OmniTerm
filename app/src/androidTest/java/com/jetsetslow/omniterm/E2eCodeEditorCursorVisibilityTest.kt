package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.ui.CodeEditor
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test

/**
 * Regression for the editor losing the cursor off-screen: typing at the end of a buffer taller
 * than the viewport must scroll the editor so the cursor line stays visible. The cursor position
 * is read from the field's real TextLayoutResult (via its semantics action) and compared against
 * the field's visible bounds in the root — no coordinates are hard-coded.
 */
class E2eCodeEditorCursorVisibilityTest {
    @get:Rule val composeRule = createComposeRule()

    @Test
    fun typingAtBufferEndKeepsCursorInsideViewport() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_editor_cursor") == "yes")
        composeRule.setContent {
            var text by remember { mutableStateOf((1..200).joinToString("\n") { "line $it" }) }
            Box(Modifier.width(360.dp).height(320.dp)) {
                CodeEditor(value = text, onValueChange = { text = it })
            }
        }
        // Focus the field (cursor lands where the tap falls — some visible line near the top).
        composeRule.onNodeWithTag("code-editor-input").performClick()
        composeRule.waitForIdle()
        // Append text; the internal field moves the cursor to the end of the pre-existing content
        // only if we type there, so inject at the current cursor and then verify visibility. To
        // force the interesting case, type enough newlines to walk the cursor far below the fold.
        composeRule.onNodeWithTag("code-editor-input").performTextInput("\n".repeat(80) + "cursor-here")
        composeRule.waitForIdle()

        val node = composeRule.onNodeWithTag("code-editor-input").fetchSemanticsNode()
        val getLayout = node.config.getOrNull(SemanticsActions.GetTextLayoutResult)
        val results = mutableListOf<TextLayoutResult>()
        composeRule.runOnUiThread { getLayout?.action?.invoke(results) }
        assertTrue("no text layout available", results.isNotEmpty())
        val layout = results.first()

        val selection = node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange)
        assertTrue("no selection available", selection != null)
        val cursorRect = layout.getCursorRect(selection!!.end)

        // The field's positionInRoot already reflects the parent scroll offset, so the cursor's
        // root-space Y must fall inside the root's bounds for the cursor to be visible.
        val cursorTopInRoot = node.positionInRoot.y + cursorRect.top
        val cursorBottomInRoot = node.positionInRoot.y + cursorRect.bottom
        val rootHeightPx = composeRule.onRoot().fetchSemanticsNode().size.height.toFloat()
        assertTrue(
            "cursor is above the viewport (top=$cursorTopInRoot)",
            cursorBottomInRoot > 0f,
        )
        assertTrue(
            "cursor is below the viewport (bottom=$cursorBottomInRoot, viewport=$rootHeightPx)",
            cursorTopInRoot < rootHeightPx,
        )
    }
}
