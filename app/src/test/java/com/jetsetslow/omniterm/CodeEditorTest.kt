package com.jetsetslow.omniterm

import androidx.compose.ui.text.input.TextFieldValue
import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.CodeHighlightTransformation
import com.jetsetslow.omniterm.ui.HIGHLIGHT_MAX_CHARS_CAP
import com.jetsetslow.omniterm.ui.HiKind
import com.jetsetslow.omniterm.ui.HighlightPalette
import com.jetsetslow.omniterm.ui.clampHighlightLimit
import com.jetsetslow.omniterm.ui.findMatches
import com.jetsetslow.omniterm.ui.goToLine
import com.jetsetslow.omniterm.ui.highlightAll
import com.jetsetslow.omniterm.ui.highlightLine
import com.jetsetslow.omniterm.ui.languageForFileName
import com.jetsetslow.omniterm.ui.largeEditorWindowEnd
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-logic tests for the shared CodeEditor's find and go-to-line helpers. */
class CodeEditorTest {

    @Test
    fun findMatchesPlainCaseInsensitive() {
        val m = findMatches("Foo foo FOO", "foo", caseSensitive = false, useRegex = false)
        assertEquals(listOf(0 to 3, 4 to 7, 8 to 11), m)
    }

    @Test
    fun findMatchesPlainCaseSensitive() {
        val m = findMatches("Foo foo FOO", "foo", caseSensitive = true, useRegex = false)
        assertEquals(listOf(4 to 7), m)
    }

    @Test
    fun findMatchesEmptyQueryReturnsNothing() {
        assertEquals(emptyList<Pair<Int, Int>>(), findMatches("abc", "", false, false))
    }

    @Test
    fun findMatchesRegex() {
        val m = findMatches("a1 b22 c333", "\\d+", caseSensitive = true, useRegex = true)
        assertEquals(listOf(1 to 2, 4 to 6, 8 to 11), m)
    }

    @Test
    fun goToLineMovesCursorToLineStart() {
        val text = "line1\nline2\nline3"
        val r = goToLine(TextFieldValue(text), text, 3)
        assertEquals(12, r.selection.start) // start of "line3"
    }

    @Test
    fun goToLineClampsBeyondEnd() {
        val text = "a\nb"
        val r = goToLine(TextFieldValue(text), text, 99)
        assertEquals(2, r.selection.start) // start of last line "b"
    }

    @Test
    fun goToLineClampsBelowOne() {
        val text = "a\nb"
        val r = goToLine(TextFieldValue(text), text, 0)
        assertEquals(0, r.selection.start)
    }

    @Test
    fun languageByExtension() {
        assertEquals(CodeLanguage.YAML, languageForFileName("docker-compose.yml"))
        assertEquals(CodeLanguage.YAML, languageForFileName("/etc/app/config.yaml"))
        assertEquals(CodeLanguage.SHELL, languageForFileName("deploy.sh"))
        assertEquals(CodeLanguage.SHELL, languageForFileName("Dockerfile"))
        assertEquals(CodeLanguage.NONE, languageForFileName("notes.txt"))
    }

    @Test
    fun yamlHighlightColoursKeyAndComment() {
        // "image: nginx  # web" → a key token (image) and a comment token (# web) exist.
        val tokens = highlightAll("image: nginx  # web", CodeLanguage.YAML)
        assertTrue("expected a key token starting at 0", tokens.any { it.start == 0 && it.end == 5 })
        assertTrue("expected a comment token", tokens.any { it.start == 14 })
    }

    @Test
    fun noneLanguageProducesNoTokens() {
        assertEquals(emptyList<Any>(), highlightAll("image: nginx", CodeLanguage.NONE))
    }

    @Test
    fun yamlHighlightHandlesCommentsQuotesUrlsAnchorsUnicodeAndMalformedLines() {
        val text = """
            # leading comment
            services:
              web:
                image: "registry.example/a:b#fragment" # real comment
                environment: { FLAG: true, COUNT: 12.5 }
                command: 'unterminated café-東京-🙂
                labels:
                  - "url=https://example.test/a#fragment"
                <<: *defaults
        """.trimIndent()
        val tokens = highlightAll(text, CodeLanguage.YAML)

        assertTrue(tokens.all { it.start >= 0 && it.end in (it.start + 1)..text.length })
        assertTrue(tokens.any { it.kind == HiKind.COMMENT && text.substring(it.start, it.end) == "# leading comment" })
        assertTrue(tokens.any { it.kind == HiKind.COMMENT && text.substring(it.start, it.end) == "# real comment" })
        assertTrue(tokens.any { it.kind == HiKind.STRING && text.substring(it.start, it.end).contains("a:b#fragment") })
        assertTrue(tokens.any { it.kind == HiKind.KEYWORD && text.substring(it.start, it.end) == "true" })
        assertTrue(tokens.any { it.kind == HiKind.NUMBER && text.substring(it.start, it.end) == "12.5" })
    }

    @Test
    fun shellHighlightHandlesEscapesFragmentsUnicodeAndUnterminatedQuotes() {
        val line = "if [ \"\$URL\" ]; then echo \"a\\\"#b\" foo#bar # comment Δ; fi; echo 'unterminated 🙂"
        val tokens = highlightLine(line, 17, CodeLanguage.SHELL)
        assertTrue(tokens.all { it.start >= 17 && it.end <= line.length + 17 })
        assertTrue(tokens.any { it.kind == HiKind.KEYWORD && line.substring(it.start - 17, it.end - 17) == "if" })
        assertTrue(tokens.any { it.kind == HiKind.KEYWORD && line.substring(it.start - 17, it.end - 17) == "then" })
        assertTrue(tokens.any { it.kind == HiKind.COMMENT && line.substring(it.start - 17, it.end - 17).startsWith("# comment") })
        assertTrue(tokens.none { it.kind == HiKind.COMMENT && line.substring(it.start - 17, it.end - 17).startsWith("#bar") })
    }

    @Test
    fun largeHighlightAndSafetyCutoffRespectExactBoundaries() {
        val line = "  service-0001: { image: 'nginx:latest', replicas: 12 } # comment\n"
        val large = buildString {
            while (length + line.length <= HIGHLIGHT_MAX_CHARS_CAP) append(line)
            append("x".repeat(HIGHLIGHT_MAX_CHARS_CAP - length))
        }
        assertEquals(HIGHLIGHT_MAX_CHARS_CAP, large.length)
        val tokens = highlightAll(large, CodeLanguage.YAML)
        assertTrue(tokens.isNotEmpty())
        assertTrue(tokens.all { it.end <= large.length })

        val palette = HighlightPalette(Color.Gray, Color.Green, Color.Yellow, Color.Cyan, Color.Magenta)
        val transformation = CodeHighlightTransformation(CodeLanguage.YAML, palette, HIGHLIGHT_MAX_CHARS_CAP)
        val atLimit = transformation.filter(AnnotatedString(large)).text
        val overLimit = transformation.filter(AnnotatedString(large + "x")).text
        assertTrue(atLimit.spanStyles.isNotEmpty())
        assertTrue(overLimit.spanStyles.isEmpty())
        assertEquals(large + "x", overLimit.text)
    }

    @Test
    fun highlightLimitClampsEveryExtreme() {
        assertEquals(0, clampHighlightLimit(Int.MIN_VALUE))
        assertEquals(0, clampHighlightLimit(-1))
        assertEquals(0, clampHighlightLimit(0))
        assertEquals(42, clampHighlightLimit(42))
        assertEquals(HIGHLIGHT_MAX_CHARS_CAP, clampHighlightLimit(Int.MAX_VALUE))
    }

    @Test
    fun largeEditorWindowsAreBoundedAndCoverTailWithoutTruncation() {
        val text = "x".repeat(100_000)
        assertEquals(4_096, largeEditorWindowEnd(text, 0))
        assertEquals(36_096, largeEditorWindowEnd(text, 32_000))
        assertEquals(100_000, largeEditorWindowEnd(text, 96_000))
        assertEquals(100_000, largeEditorWindowEnd(text, Int.MAX_VALUE))
        assertEquals(4_096, largeEditorWindowEnd(text, Int.MIN_VALUE))
    }
}
