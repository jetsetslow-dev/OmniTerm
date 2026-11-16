package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.HiKind
import com.jetsetslow.omniterm.ui.HiToken
import com.jetsetslow.omniterm.ui.gutterRows
import com.jetsetslow.omniterm.ui.highlightAll
import com.jetsetslow.omniterm.ui.languageForFileName
import com.jetsetslow.omniterm.ui.logicalLineStartOffsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The editor's colours follow strings, heredocs and YAML blocks across lines, keep quotes and
 * keywords where they mean something, recognise more of the files people open, and line numbers
 * sit beside their lines.
 */
class CodeHighlighterStateTest {

    /** The kind of the token covering [needle]'s first character (its [occurrence]th match), or null. */
    private fun kindAt(text: String, tokens: List<HiToken>, needle: String, occurrence: Int = 0): HiKind? {
        var at = -1
        repeat(occurrence + 1) { at = text.indexOf(needle, at + 1) }
        check(at >= 0) { "no '$needle' in the text" }
        return tokens.firstOrNull { at >= it.start && at < it.end }?.kind
    }

    private fun shell(text: String) = text to highlightAll(text, CodeLanguage.SHELL)
    private fun yaml(text: String) = text to highlightAll(text, CodeLanguage.YAML)

    @Test
    fun aShellStringAcrossLinesEndsWhereItCloses() {
        val (text, tokens) = shell("echo \"a\nb\"  # note\nls")
        assertEquals(HiKind.STRING, kindAt(text, tokens, "b\""))
        assertEquals(HiKind.COMMENT, kindAt(text, tokens, "# note"))
        assertNull(kindAt(text, tokens, "ls"))
        // The same with a single-quoted awk program.
        val (awk, awkTokens) = shell("awk '\n{ print \$1 } # in awk\n' file # after\nif true; then :; fi")
        assertEquals(HiKind.STRING, kindAt(awk, awkTokens, "# in awk"))
        assertEquals(HiKind.COMMENT, kindAt(awk, awkTokens, "# after"))
        assertEquals(HiKind.KEYWORD, kindAt(awk, awkTokens, "if"))
    }

    @Test
    fun aHeredocBodyIsTextUntilItsDelimiter() {
        val (text, tokens) = shell("cat <<'EOF' > out\nif this is text; then\nEOF\nif true; then echo; fi")
        assertEquals(HiKind.STRING, kindAt(text, tokens, "if this"))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "if", occurrence = 1))
        // <<- strips leading tabs from the delimiter line.
        val (tabbed, tabbedTokens) = shell("cat <<-END\n\tdone here\n\tEND\ndone")
        assertEquals(HiKind.STRING, kindAt(tabbed, tabbedTokens, "done here"))
        assertEquals(HiKind.KEYWORD, kindAt(tabbed, tabbedTokens, "done", occurrence = 1))
        // A here-string is not a heredoc.
        val (here, hereTokens) = shell("grep x <<< \"\$v\"\nif true; then :; fi")
        assertEquals(HiKind.KEYWORD, kindAt(here, hereTokens, "if"))
    }

    @Test
    fun aYamlBlockScalarIsTextWhileItIsIndented() {
        val (text, tokens) = yaml("steps:\n  - run: |\n      echo foo: bar\n      # not a comment\n\n      done\n  - name: next")
        assertEquals(HiKind.STRING, kindAt(text, tokens, "echo foo"))
        assertEquals(HiKind.STRING, kindAt(text, tokens, "# not a comment"))
        assertEquals(HiKind.STRING, kindAt(text, tokens, "done"))
        assertEquals(HiKind.KEY, kindAt(text, tokens, "name"))
        // Folded, with chomping, and a bare "- |" entry.
        val (folded, foldedTokens) = yaml("a: >-\n  key: no\nb: 1\nlist:\n- |\n  x: y\n- z")
        assertEquals(HiKind.STRING, kindAt(folded, foldedTokens, "key: no"))
        assertEquals(HiKind.KEY, kindAt(folded, foldedTokens, "b"))
        assertEquals(HiKind.STRING, kindAt(folded, foldedTokens, "x: y"))
    }

    @Test
    fun apostrophesInsideWordsAreText() {
        val (text, tokens) = yaml("description: Don't stop # x\nnext: 'quoted' # y")
        assertNull(kindAt(text, tokens, "t stop"))
        assertEquals(HiKind.COMMENT, kindAt(text, tokens, "# x"))
        assertEquals(HiKind.STRING, kindAt(text, tokens, "'quoted'"))
        assertEquals(HiKind.COMMENT, kindAt(text, tokens, "# y"))
        // Shell escapes outside strings.
        val (sh, shTokens) = shell("echo it\\'s \\\"fine\\\" # c")
        assertNull(kindAt(sh, shTokens, "s "))
        assertEquals(HiKind.COMMENT, kindAt(sh, shTokens, "# c"))
        // A YAML single-quoted string with a doubled quote inside.
        val (q, qTokens) = yaml("a: 'it''s' # z")
        assertEquals(HiKind.STRING, kindAt(q, qTokens, "s'"))
        assertEquals(HiKind.COMMENT, kindAt(q, qTokens, "# z"))
    }

    @Test
    fun keywordsOnlyStandAlone() {
        val (text, tokens) = shell("cd /usr/local/bin && helm upgrade --set a=1 --local \$done \${in} foo.do x-in\nfor f in *; do echo; done")
        for (word in listOf("local", "set", "done", "in}", "do", "in\n")) {
            assertNull(word, kindAt(text, tokens, word))
        }
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "cd"))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "for"))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "in *"))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "done", occurrence = 1))
    }

    @Test
    fun yamlLiteralsAndNumbersOnlyAsWholeValues() {
        val (text, tokens) = yaml("on: push\nnote: turn it on now\nflag: yes\nport: 8080\nhex: 0x1F\nneg: -3\nver: v1.2\nlist: [1, true, x]")
        assertNull(kindAt(text, tokens, "on now"))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "yes"))
        assertEquals(HiKind.NUMBER, kindAt(text, tokens, "8080"))
        assertEquals(HiKind.NUMBER, kindAt(text, tokens, "0x1F"))
        assertEquals(HiKind.NUMBER, kindAt(text, tokens, "-3"))
        assertNull(kindAt(text, tokens, "1.2"))
        assertEquals(HiKind.NUMBER, kindAt(text, tokens, "1, "))
        assertEquals(HiKind.KEYWORD, kindAt(text, tokens, "true"))
    }

    @Test
    fun crlfAndTabsDoNotHideKeys() {
        val (text, tokens) = yaml("services:\r\n  web:\r\n    image:\tnginx\r\n    port: 80\r\n")
        assertEquals(HiKind.KEY, kindAt(text, tokens, "services"))
        assertEquals(HiKind.KEY, kindAt(text, tokens, "web"))
        assertEquals(HiKind.KEY, kindAt(text, tokens, "image"))
        assertEquals(HiKind.NUMBER, kindAt(text, tokens, "80"))
        assertTrue("no token covers a carriage return", tokens.none { t -> (t.start until t.end).any { text[it] == '\r' } })
        val (sh, shTokens) = shell("if true; then\r\n  echo \"a\r\n\"\r\nfi\r\n")
        assertEquals(HiKind.KEYWORD, kindAt(sh, shTokens, "then"))
        assertEquals(HiKind.KEYWORD, kindAt(sh, shTokens, "fi"))
    }

    @Test
    fun moreFilesAreRecognised() {
        for (name in listOf(".bashrc", "/home/u/.zshrc", ".profile", ".bash_aliases", "Dockerfile.prod", "app.dockerfile",
            "Containerfile", ".env", ".env.local", "prod.env", "run.ksh")) {
            assertEquals(name, CodeLanguage.SHELL, languageForFileName(name))
        }
        for (name in listOf("compose.yml.j2", "values.yaml.tmpl", "a.yaml.template")) {
            assertEquals(name, CodeLanguage.YAML, languageForFileName(name))
        }
        assertEquals(CodeLanguage.SHELL, languageForFileName("backup", "#!/bin/bash"))
        assertEquals(CodeLanguage.SHELL, languageForFileName("deploy", "#!/usr/bin/env -S bash -e"))
        assertEquals(CodeLanguage.SHELL, languageForFileName("x", "#! /bin/sh"))
        assertEquals(CodeLanguage.NONE, languageForFileName("tool", "#!/usr/bin/env python3"))
        assertEquals(CodeLanguage.NONE, languageForFileName("notes", "just text"))
        assertEquals(CodeLanguage.NONE, languageForFileName("notes.txt"))
        // A .j2 alone says nothing about the language.
        assertEquals(CodeLanguage.NONE, languageForFileName("page.j2"))
    }

    @Test
    fun lineNumbersSitAtTheirLinesFirstRow() {
        // 80 lines; line 30 wraps over three rows and line 31 is taller (a fallback-font glyph).
        val text = (1..80).joinToString("\n") { "line $it" }
        val starts = logicalLineStartOffsets(text)
        val rowsOfLine = IntArray(80) { if (it == 29) 3 else 1 }
        val firstRow = IntArray(80).also { var r = 0; for (i in 0 until 80) { it[i] = r; r += rowsOfLine[i] } }
        val rowTop = FloatArray(firstRow.last() + 1).also { var y = 0f; for (r in it.indices) { it[r] = y; y += if (r == firstRow[30]) 30f else 20f } }
        fun visualLineOf(offset: Int) = firstRow[starts.indexOfLast { it <= offset }]
        val rows = gutterRows(
            starts,
            visualLineOf = ::visualLineOf,
            lineTop = { rowTop[it] },
            lineBottom = { rowTop[it] + if (it == firstRow[30]) 30f else 20f },
            lineBaseline = { rowTop[it] + 15f },
            visibleTop = 1_000f,
            visibleBottom = 1_400f,
        )
        val sixty = rows.single { it.number == 60 }
        assertEquals(rowTop[firstRow[59]] + 15f, sixty.baseline)
        assertTrue("only lines in view: ${rows.first().number}..${rows.last().number}", rows.size < 25)
        // Every line in view is there, in order.
        assertEquals((rows.first().number..rows.last().number).toList(), rows.map { it.number })
        assertTrue(rows.first().number <= 50 && rows.last().number >= 68)
        // From the top, the wrapped line 30 is followed by line 31 three rows lower.
        val top = gutterRows(starts, ::visualLineOf, { rowTop[it] }, { rowTop[it] + 20f }, { rowTop[it] }, 0f, 800f)
        assertEquals(rowTop[firstRow[29]] + 60f, top.single { it.number == 31 }.baseline)
    }
}
