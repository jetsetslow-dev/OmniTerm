package com.jetsetslow.omniterm

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isHeading
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.text.TextRange
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/**
 * The file editor's Markdown preview on a device, on a Markdown file in the lab host's home: edit it
 * without saving, switch to the preview, see the formatting, the unsaved words and "image not
 * loaded" in place of an image, tap a link and get the question with its whole address (and no
 * question for a javascript: link), then switch back to the text with the edit, the cursor, the
 * selection and the scroll position as they were. Saves `markdown-preview.png` and
 * `markdown-link-question.png` in the app's external files directory for a person to look at.
 *
 * Run with `./scripts/test-hosts.sh suite E2eMarkdownPreviewTest omniterm_e2e_markdown_preview=yes
 * host port user pass omniterm_e2e_sftp_home`. The file is removed afterwards and never saved.
 */
class E2eMarkdownPreviewTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun previewShowsUnsavedTextAsksBeforeLinksAndKeepsTheEditor() = runBlocking {
        assumeTrue(E2eArgs.on("omniterm_e2e_markdown_preview"))
        DeviceShell.run("input keyevent KEYCODE_WAKEUP")
        DeviceShell.run("wm dismiss-keyguard")
        composeRule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val home = E2eArgs.require("omniterm_e2e_sftp_home")
        // Saved as it is rather than through the form: the provisioned lab host is usually at this
        // same address already, and the form allows one saved host per address.
        val host = E2eLabHosts.save(
            vm,
            ServerEntity(
                name = HOST, host = E2eArgs.require("host"), port = E2eArgs.get("port")?.toIntOrNull() ?: 2205,
                username = E2eArgs.require("user"), authPassword = E2eArgs.require("pass"),
            ),
        ).also { E2eLabHosts.connectOnce(vm, it) }
        val name = "omniterm-e2e-preview-${System.currentTimeMillis().toString(36)}.md"
        val path = "$home/$name"
        vm.executeSshCommand(host, "cat > '$path' && printf 'OT-WRITTEN\\n'", stdin = FIXTURE).also {
            assertTrue("fixture written: ${it.take(200)}", "OT-WRITTEN" in it)
        }
        try {
            lateinit var load: Job
            composeRule.runOnUiThread {
                vm.isAppLocked = false
                vm.selectedServerId = host.id
                vm.navigateTo(Screen.SFTP)
                vm.activeSftpTab = 1
                load = vm.loadSftp(home)
            }
            withTimeout(30_000) { load.join() }
            composeRule.waitUntil(15_000) { !vm.sftpLoading && vm.sftpEntries.any { it.name == name } }
            lateinit var read: Job
            composeRule.runOnUiThread { read = requireNotNull(vm.openSftpFileForEdit(vm.sftpEntries.single { it.name == name })) }
            withTimeout(30_000) { read.join() }
            assertEquals(FIXTURE, vm.edittingSftpFile?.content)
            composeRule.waitUntil(15_000) { composeRule.onAllNodesWithTag(INPUT).fetchSemanticsNodes().isNotEmpty() }

            // Edit without saving, select a few words, put the keyboard away and scroll down a little.
            composeRule.onNodeWithContentDescription("Edit mode: off (read-only)").performClick()
            composeRule.onNodeWithTag(INPUT).performTextInputSelection(TextRange(0))
            composeRule.onNodeWithTag(INPUT).performTextInput(EDIT)
            composeRule.onNodeWithTag(INPUT).performTextInputSelection(SELECTED)
            composeRule.waitForIdle()
            hideKeyboard()
            val startTop = editorState().top
            composeRule.onNodeWithTag(INPUT).performTouchInput { swipeUp(startY = centerY + 200f, endY = centerY - 200f, durationMillis = 1_500) }
            composeRule.waitForIdle()
            val text = EDIT + FIXTURE
            val before = editorState()
            assertEquals(text, before.text)
            assertEquals(SELECTED, before.selection)
            assertTrue("the editor scrolled: from $startTop to ${before.top}", before.top < startTop - 50f)

            composeRule.onNodeWithTag(TOGGLE).performClick()
            composeRule.waitUntil(15_000) { composeRule.onAllNodesWithTag(LIST).fetchSemanticsNodes().isNotEmpty() }
            composeRule.waitForIdle()
            assertTrue("the text is out of reach under the preview", composeRule.onAllNodesWithTag(INPUT).fetchSemanticsNodes().isEmpty())
            composeRule.onNode(hasText("Unsaved line from the device test")).assertIsDisplayed()
            composeRule.onNode(hasText("OmniTerm preview check") and isHeading()).assertIsDisplayed()
            save(composeRule.onRoot().captureToImage().asAndroidBitmap(), "markdown-preview")
            scrollTo(hasText("The project logo image not loaded"))
            scrollTo(hasText("443"))
            scrollTo(hasText("image: nginx", substring = true))
            scrollTo(hasText("<script>alert('not run')</script>"))

            // A web link asks first, with its whole address; Cancel opens nothing.
            scrollTo(hasText("the project page"))
            composeRule.onNodeWithText("the project page").performClick()
            composeRule.waitUntil(5_000) { questionShown() }
            composeRule.onNodeWithTag(ADDRESS).assert(hasText(LINK))
            save(composeRule.onNodeWithTag(QUESTION).captureToImage().asAndroidBitmap(), "markdown-link-question")
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.waitForIdle()
            assertFalse(questionShown())
            // Nothing else took the screen: the app's own window has the focus back once the question is gone.
            composeRule.waitUntil(5_000) { composeRule.activity.hasWindowFocus() }
            // A javascript: link is plain text: no question, nothing opens.
            scrollTo(hasText("run this"))
            composeRule.onNodeWithText("run this").performClick()
            composeRule.waitForIdle()
            assertFalse(questionShown())

            // Back to the text: the edit, the cursor and selection, and the scroll position as they were.
            composeRule.onNodeWithTag(TOGGLE).performClick()
            composeRule.waitUntil(10_000) { composeRule.onAllNodesWithTag(INPUT).fetchSemanticsNodes().isNotEmpty() }
            composeRule.waitForIdle()
            val after = editorState()
            assertEquals(text, after.text)
            assertEquals(SELECTED, after.selection)
            assertEquals(before.top, after.top, 1f)
            assertNotNull("still unsaved", vm.edittingSftpFile)
            assertEquals(FIXTURE, vm.edittingSftpFile?.content)
            assertTrue(composeRule.onAllNodes(hasText("$name •")).fetchSemanticsNodes().isNotEmpty())
        } finally {
            composeRule.runOnUiThread {
                vm.edittingSftpFile = null
                vm.edittingSftpFilePath = ""
                vm.sftpEditorDraft.clear()
            }
            vm.executeSshCommand(host, "rm -f '$path'")
            E2eLabHosts.remove(vm, HOST)
        }
        assertNull(vm.edittingSftpFile)
    }

    /** The editor's text, selection, and where its text starts: above the screen once scrolled. */
    private class EditorState(val text: String, val selection: TextRange?, val top: Float)

    private fun editorState(): EditorState {
        val node = composeRule.onNodeWithTag(INPUT).fetchSemanticsNode()
        return EditorState(
            node.config.getOrNull(SemanticsProperties.EditableText)?.text.orEmpty(),
            node.config.getOrNull(SemanticsProperties.TextSelectionRange),
            node.positionInRoot.y,
        )
    }

    private fun questionShown() = composeRule.onAllNodesWithTag(QUESTION).fetchSemanticsNodes().isNotEmpty()

    private fun scrollTo(matcher: androidx.compose.ui.test.SemanticsMatcher) {
        composeRule.onNode(hasTestTag(LIST)).performScrollToNode(matcher)
        composeRule.waitForIdle()
        composeRule.onNode(matcher).assertIsDisplayed()
    }

    private fun hideKeyboard() {
        val ime = androidx.core.view.WindowInsetsCompat.Type.ime()
        fun shown() = androidx.core.view.ViewCompat.getRootWindowInsets(composeRule.activity.window.decorView)?.isVisible(ime) == true
        composeRule.waitUntil(5_000) {
            if (shown()) androidx.test.espresso.Espresso.closeSoftKeyboard()
            !shown()
        }
        composeRule.waitForIdle()
    }

    private fun save(bitmap: Bitmap, name: String) {
        val dir = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null))
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private companion object {
        const val HOST = "E2E Markdown Preview"
        const val INPUT = "code-editor-input"
        const val TOGGLE = "editor-preview-toggle"
        const val LIST = "markdown-preview-list"
        const val QUESTION = "markdown-link-question"
        const val ADDRESS = "markdown-link-address"
        const val LINK = "https://example.org/omniterm/docs?from=preview#links"
        const val EDIT = "Unsaved line from the device test\n\n"
        val SELECTED = TextRange(40, 52)
        val FIXTURE = buildString {
            appendLine("# OmniTerm preview check")
            appendLine()
            appendLine("Some *soft* and **loud** text with `inline code`.")
            appendLine()
            appendLine("![The project logo](https://tracker.invalid/pixel.png)")
            appendLine()
            appendLine("- [x] done item")
            appendLine("- [ ] open item")
            appendLine("  - nested bullet")
            appendLine()
            appendLine("> A quoted line")
            appendLine()
            appendLine("| Host | Port |")
            appendLine("|------|-----:|")
            appendLine("| web  | 443  |")
            appendLine()
            appendLine("```yaml")
            appendLine("services:")
            appendLine("  web: # comment")
            appendLine("    image: nginx")
            appendLine("```")
            appendLine()
            appendLine("<script>alert('not run')</script>")
            appendLine()
            appendLine("[the project page]($LINK)")
            appendLine()
            appendLine("[run this](javascript:alert(1))")
            appendLine()
            for (n in 1..80) appendLine("Line $n of text that makes the file long enough to scroll.")
        }
    }
}
