package com.jetsetslow.omniterm

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.CodeEditor
import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/**
 * Pictures of the editor on a device for a person to compare: a long shell script, YAML file,
 * Markdown file and JSON file scrolled to about line 60, with emoji and CJK lines (taller fallback
 * glyphs) and strings, heredocs, blocks, fenced code and comments that span lines. Line 60's number must sit beside line 60, and the colours
 * must follow the constructs. Saved in the app's external files directory, `editor-*.png`.
 *
 * Opt in with `-e omniterm_e2e_editor_gutter yes`. Uses only the editor's public API, so the same
 * test runs against an older build.
 */
class E2eCodeEditorGutterTest {
    @get:Rule val composeRule = createComposeRule()

    @Test
    fun longFilesKeepNumbersBesideTheirLines() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_editor_gutter") == "yes")
        shoot("editor-sh", CodeLanguage.SHELL, shellScript())
    }

    @Test
    fun longYamlKeepsNumbersBesideTheirLines() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_editor_gutter") == "yes")
        shoot("editor-yml", CodeLanguage.YAML, yamlFile())
    }

    @Test
    fun longMarkdownKeepsNumbersBesideTheirLines() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_editor_gutter") == "yes")
        shoot("editor-md", CodeLanguage.MARKDOWN, markdownFile())
    }

    @Test
    fun longJsonKeepsNumbersBesideTheirLines() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_editor_gutter") == "yes")
        shoot("editor-json", CodeLanguage.JSON, jsonFile())
    }

    private fun shoot(name: String, language: CodeLanguage, text: String) {
        composeRule.setContent {
            MyApplicationTheme {
                Box(Modifier.width(400.dp).height(700.dp)) {
                    CodeEditor(value = text, onValueChange = {}, language = language)
                }
            }
        }
        composeRule.waitForIdle()
        save(composeRule.onRoot().captureToImage().asAndroidBitmap(), "$name-top")
        // Slow drags, so no fling carries the view to the end.
        repeat(2) {
            composeRule.onRoot().performTouchInput { swipeUp(startY = bottom - 40f, endY = top + 400f, durationMillis = 2_000) }
            composeRule.waitForIdle()
        }
        composeRule.mainClock.advanceTimeBy(2_000)
        composeRule.waitForIdle()
        save(composeRule.onRoot().captureToImage().asAndroidBitmap(), "$name-scrolled")
    }

    private fun save(bitmap: Bitmap, name: String) {
        val dir = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null))
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun shellScript() = buildString {
        appendLine("#!/bin/sh")
        for (n in 2..120) {
            when {
                n == 20 -> appendLine("echo \"a string that runs")
                n == 21 -> appendLine("on to here\"  # line $n, a comment")
                n == 40 -> appendLine("cat <<'EOF' > /tmp/x  # line $n")
                n == 41 -> appendLine("if this were code it would be coloured; fi  # line $n")
                n == 42 -> appendLine("EOF")
                n % 7 == 0 -> appendLine("echo 'line $n ✅ 東京 🙂'")
                else -> appendLine("cd /usr/local/bin && echo line $n --set \$done")
            }
        }
    }

    private fun yamlFile() = buildString {
        appendLine("jobs:")
        appendLine("  build:")
        appendLine("    steps:")
        for (n in 4..120) {
            when {
                n == 30 -> appendLine("      - run: |")
                n in 31..34 -> appendLine("          echo line $n: not a key # nor a comment")
                n % 7 == 0 -> appendLine("      - name: \"line $n ✅ 東京\"")
                else -> appendLine("      - name: line $n Don't stop  # comment")
            }
        }
    }

    private fun markdownFile() = buildString {
        appendLine("# Line 1, a heading")
        for (n in 2..120) {
            when {
                n == 20 -> appendLine("```yaml")
                n == 21 -> appendLine("key: line $n # a YAML comment")
                n == 22 -> appendLine("```")
                n == 40 -> appendLine("<!-- line $n, a comment")
                n == 41 -> appendLine("that ends on line $n -->")
                n == 50 -> appendLine("| line | $n |")
                n == 51 -> appendLine("|------|----|")
                n % 10 == 0 -> appendLine("## Line $n, a heading")
                n % 7 == 0 -> appendLine("> line $n ✅ 東京 🙂 *quoted*")
                n % 3 == 0 -> appendLine("- [x] line $n with `code` and [a link](https://example.org/$n)")
                else -> appendLine("Line $n is **plain** text with snake_case words.")
            }
        }
    }

    private fun jsonFile() = buildString {
        appendLine("{")
        for (n in 2..119) {
            when {
                n == 30 -> appendLine("  /* line $n, a comment")
                n == 31 -> appendLine("     that ends on line $n */")
                n % 7 == 0 -> appendLine("  \"line$n\": \"✅ 東京 🙂\",")
                n % 5 == 0 -> appendLine("  \"line$n\": [true, false, null], // line $n")
                else -> appendLine("  \"line$n\": $n.5e-3,")
            }
        }
        appendLine("  \"end\": 120")
        appendLine("}")
    }
}
