package com.jetsetslow.omniterm

import androidx.compose.ui.text.input.TextFieldValue
import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.findMatches
import com.jetsetslow.omniterm.ui.goToLine
import com.jetsetslow.omniterm.ui.highlightAll
import com.jetsetslow.omniterm.ui.languageForFileName
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
}
