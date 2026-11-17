package com.jetsetslow.omniterm.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation

/**
 * Theme-aware highlight palette: one of two fixed palettes, picked by the luminance of the current
 * MaterialTheme's surface. Dark/AMOLED (and dark high-contrast) get bright accents on near-black;
 * light (and light high-contrast) get deeper accents readable on white; both keep a comment colour
 * with real contrast (the old fixed `OmniColors.textMuted` was near-invisible).
 */
@androidx.compose.runtime.Composable
fun rememberHighlightPalette(): HighlightPalette {
    val scheme = androidx.compose.material3.MaterialTheme.colorScheme
    val dark = scheme.surface.luminance() < 0.5f
    return androidx.compose.runtime.remember(scheme.surface, scheme.primary) {
        if (dark) HighlightPalette(
            comment = Color(0xFF6B7A90),   // readable grey-blue on dark
            string = Color(0xFF6BE39B),
            number = Color(0xFFFFC04D),
            key = Color(0xFF4DD0E1),
            keyword = Color(0xFFCE93D8),
        ) else HighlightPalette(
            comment = Color(0xFF6A737D),
            string = Color(0xFF0A7D33),    // deep green, legible on white
            number = Color(0xFF9A5B00),    // deep amber
            key = Color(0xFF00697A),       // deep cyan
            keyword = Color(0xFF7B1FA2),   // deep purple
        )
    }
}

private fun Color.luminance(): Float = 0.299f * red + 0.587f * green + 0.114f * blue

/** Editor languages we do lightweight highlighting for. Picked by file extension at the call site. */
enum class CodeLanguage { NONE, YAML, SHELL, MARKDOWN, JSON }

/** Semantic token kinds. Colour is resolved later from the active theme (see [HighlightPalette]). */
enum class HiKind { COMMENT, STRING, NUMBER, KEY, KEYWORD }

/** A token span: [start, end) over the source text, tagged with its semantic [kind]. */
data class HiToken(val start: Int, val end: Int, val kind: HiKind)

/**
 * Theme-resolved colours for each [HiKind]. Built in a composable from the active MaterialTheme so
 * highlighting stays readable on dark, AMOLED, light, and high-contrast themes alike.
 */
data class HighlightPalette(
    val comment: Color,
    val string: Color,
    val number: Color,
    val key: Color,
    val keyword: Color,
) {
    fun colorFor(kind: HiKind): Color = when (kind) {
        HiKind.COMMENT -> comment
        HiKind.STRING -> string
        HiKind.NUMBER -> number
        HiKind.KEY -> key
        HiKind.KEYWORD -> keyword
    }
}

/**
 * Highlighting re-tokenizes on every keystroke, so above some size we skip it: a plain editor that
 * stays responsive beats a pretty one that lags. The cap is user-configurable (Settings) but never
 * above [HIGHLIGHT_MAX_CHARS_CAP] — users can only lower it, not raise it past a safe ceiling.
 */
const val HIGHLIGHT_MAX_CHARS_CAP = 200_000
const val HIGHLIGHT_MAX_CHARS_DEFAULT = 100_000

/** Clamp a user-chosen highlight char limit into the allowed range (0 disables highlighting). */
fun clampHighlightLimit(value: Int): Int = value.coerceIn(0, HIGHLIGHT_MAX_CHARS_CAP)

/** Template suffixes that keep the language of what they render: `app.yml.j2`, `compose.yaml.tmpl`. */
private val TEMPLATE_SUFFIXES = listOf(".j2", ".jinja", ".jinja2", ".tmpl", ".tpl", ".template")

/** Shell start-up files, named without an extension of their own. */
private val SHELL_DOTFILES = setOf(
    ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases", ".profile",
    ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".kshrc", ".mkshrc",
)

private val SHELL_INTERPRETERS = setOf("sh", "bash", "zsh", "ksh", "mksh", "dash", "ash")

private val MARKDOWN_EXTENSIONS = setOf("md", "markdown", "mdown", "mkd", "mkdn", "mdwn")

/** Files that are Markdown by convention without saying so in their name. */
private val MARKDOWN_NAMES = setOf("readme", "changelog", "contributing")

private val JSON_EXTENSIONS = setOf("json", "jsonc", "json5", "geojson", "webmanifest")

/**
 * Map a file to a [CodeLanguage] by its name, or, for a name that says nothing, by a shell
 * [firstLine] (`#!/bin/sh`, `#!/usr/bin/env bash`). Pure for unit-testing.
 */
fun languageForFileName(name: String, firstLine: String? = null): CodeLanguage {
    var lower = name.substringAfterLast('/').lowercase()
    TEMPLATE_SUFFIXES.firstOrNull { lower.endsWith(it) && lower.length > it.length }?.let { lower = lower.removeSuffix(it) }
    val ext = lower.substringAfterLast('.', "")
    return when {
        ext == "yml" || ext == "yaml" -> CodeLanguage.YAML
        ext in MARKDOWN_EXTENSIONS || lower in MARKDOWN_NAMES -> CodeLanguage.MARKDOWN
        ext in JSON_EXTENSIONS -> CodeLanguage.JSON
        ext == "sh" || ext == "bash" || ext == "zsh" || ext == "ksh" -> CodeLanguage.SHELL
        lower in SHELL_DOTFILES -> CodeLanguage.SHELL
        lower == "dockerfile" || lower == "containerfile" || lower.startsWith("dockerfile.") ||
            lower.startsWith("containerfile.") || ext == "dockerfile" || ext == "containerfile" -> CodeLanguage.SHELL
        lower == ".env" || lower.endsWith(".env") || lower.startsWith(".env.") -> CodeLanguage.SHELL
        // close enough: # comments + KEY=val + strings
        ext == "conf" || ext == "ini" || ext == "cfg" || ext == "properties" -> CodeLanguage.SHELL
        firstLine != null && isShellShebang(firstLine) -> CodeLanguage.SHELL
        else -> CodeLanguage.NONE
    }
}

/** Whether the file editor offers a preview for [name]: `.md`, `.markdown` and the like, and `README`. */
fun isMarkdownFileName(name: String): Boolean = languageForFileName(name) == CodeLanguage.MARKDOWN

/**
 * The language a Markdown code fence names in its info string (```` ```yaml ````, ```` ```bash title ````):
 * the names people use for shell sessions, then the same names files have as extensions.
 */
fun languageForFenceInfo(info: String): CodeLanguage {
    // Pandoc and others write the name in braces with a dot: {.yaml}, {.bash .numberLines}.
    val word = info.trim().removePrefix("{").trimStart().removePrefix(".")
        .takeWhile { !it.isWhitespace() && it != '{' && it != '}' && it != ',' && it != ';' }
        .lowercase()
    return when {
        word.isEmpty() -> CodeLanguage.NONE
        word in SHELL_FENCE_NAMES -> CodeLanguage.SHELL
        else -> languageForFileName("fence.$word")
    }
}

private val SHELL_FENCE_NAMES = setOf(
    "shell", "console", "shellsession", "sh-session", "terminal", "dockerfile", "containerfile", "docker", "env", "dotenv",
)

/** `#!/bin/bash`, `#!/usr/bin/env -S zsh -e` and the like. */
internal fun isShellShebang(line: String): Boolean {
    if (!line.startsWith("#!")) return false
    val words = line.removePrefix("#!").trim().split(' ', '\t').filter { it.isNotEmpty() }
    val program = words.firstOrNull()?.substringAfterLast('/') ?: return false
    val interpreter = if (program == "env") words.drop(1).firstOrNull { !it.startsWith("-") } else program
    return interpreter in SHELL_INTERPRETERS
}

private val YAML_LITERALS = setOf("true", "false", "null", "yes", "no", "on", "off", "~")
private val SHELL_KEYWORDS = setOf(
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
    "function", "in", "return", "export", "local", "echo", "cd", "exit", "set", "source",
)

/**
 * What a line starts inside: whatever the line before it left open. Highlighting each line on its
 * own turned the rest of a file the wrong colours after a string, heredoc or YAML block that spans
 * lines.
 */
sealed interface LineState {
    /** Nothing open. */
    data object Plain : LineState

    /** Inside a quoted string opened on an earlier line. */
    data class InQuote(val quote: Char) : LineState

    /** Shell: inside a heredoc body, until a line that is just [delimiter]. */
    data class InHeredoc(val delimiter: String, val stripTabs: Boolean) : LineState

    /** YAML: inside a `|` or `>` block, which lasts while lines are indented past [parentIndent]. */
    data class InBlockScalar(val parentIndent: Int) : LineState

    /**
     * Markdown: inside a code block fenced by [length] [fence] characters, whose lines are coloured as
     * [language], each from the [inner] state the line before it left.
     */
    data class InFence(val fence: Char, val length: Int, val language: CodeLanguage, val inner: LineState) : LineState

    /** Inside a comment that ends at [close]: a JSONC block comment, or an HTML comment (`-->`) in Markdown. */
    data class InComment(val close: String) : LineState
}

/** One line's tokens (offsets within the line) and the state the next line starts in. */
class LexedLine(val tokens: List<HiToken>, val endState: LineState)

/**
 * Tokenize one line into coloured spans for [lang], from [state]. [base] is the absolute offset of
 * the line in the file. Pure for unit-testing.
 */
fun highlightLine(line: String, base: Int, lang: CodeLanguage, state: LineState = LineState.Plain): List<HiToken> {
    val lexed = lexLine(line, lang, state)
    return if (base == 0) lexed.tokens else lexed.tokens.map { HiToken(it.start + base, it.end + base, it.kind) }
}

fun lexLine(line: String, lang: CodeLanguage, state: LineState): LexedLine = when (lang) {
    CodeLanguage.NONE -> LexedLine(emptyList(), LineState.Plain)
    CodeLanguage.SHELL -> ShellLexer(line, state).lex()
    CodeLanguage.YAML -> YamlLexer(line, state).lex()
    CodeLanguage.MARKDOWN -> MarkdownLexer(line, state).lex()
    CodeLanguage.JSON -> JsonLexer(line, state).lex()
}

/** A trailing `\r` (a CRLF file) is part of the line ending, not of the text. */
private fun contentEnd(line: String) = if (line.endsWith('\r')) line.length - 1 else line.length

private fun isNumberStart(line: String, i: Int, end: Int): Boolean {
    val c = line[i]
    if (c.isDigit()) return true
    return (c == '-' || c == '+') && i + 1 < end && line[i + 1].isDigit()
}

/** End of a number at [i]: decimal (`12`, `-3`, `12.5`, `1e3`, `2E-5`) or hexadecimal (`0x1F`). */
private fun numberEnd(line: String, i: Int, end: Int): Int {
    var j = i
    if (line[j] == '-' || line[j] == '+') j++
    if (j + 1 < end && line[j] == '0' && (line[j + 1] == 'x' || line[j + 1] == 'X')) {
        j += 2
        while (j < end && (line[j].isDigit() || line[j].lowercaseChar() in 'a'..'f')) j++
        return j
    }
    while (j < end && (line[j].isDigit() || line[j] == '.' || line[j] == '_')) j++
    if (j < end && (line[j] == 'e' || line[j] == 'E')) {
        var k = j + 1
        if (k < end && (line[k] == '+' || line[k] == '-')) k++
        if (k < end && line[k].isDigit()) {
            j = k
            while (j < end && line[j].isDigit()) j++
        }
    }
    return j
}

private class ShellLexer(private val line: String, private val start: LineState) {
    private val end = contentEnd(line)
    private val tokens = ArrayList<HiToken>()
    private var heredoc: LineState.InHeredoc? = null

    fun lex(): LexedLine {
        var i = 0
        when (start) {
            is LineState.InHeredoc -> {
                val text = line.substring(0, end).let { if (start.stripTabs) it.trimStart('\t') else it }
                if (end > 0) tokens += HiToken(0, end, HiKind.STRING)
                return LexedLine(tokens, if (text == start.delimiter) LineState.Plain else start)
            }
            is LineState.InQuote -> {
                val close = quoteEnd(0, start.quote)
                if (close < 0) {
                    if (end > 0) tokens += HiToken(0, end, HiKind.STRING)
                    return LexedLine(tokens, start)
                }
                tokens += HiToken(0, close, HiKind.STRING)
                i = close
            }
            else -> {}
        }
        while (i < end) {
            val c = line[i]
            when {
                // A backslash takes the next character literally: `it\'s`, `\"`, `\$`.
                c == '\\' -> i += 2
                c == '#' && (i == 0 || line[i - 1] in COMMENT_BEFORE) -> {
                    tokens += HiToken(i, end, HiKind.COMMENT)
                    i = end
                }
                c == '"' || c == '\'' -> {
                    val close = quoteEnd(i + 1, c)
                    if (close < 0) {
                        tokens += HiToken(i, end, HiKind.STRING)
                        return LexedLine(tokens, LineState.InQuote(c))
                    }
                    tokens += HiToken(i, close, HiKind.STRING)
                    i = close
                }
                c == '<' && line.startsWith("<<<", i) -> i += 3 // a here-string, not a heredoc
                c == '<' && line.startsWith("<<", i) -> i = heredocStart(i + 2)
                c.isDigit() && (i == 0 || line[i - 1] in WORD_BEFORE) -> {
                    val j = numberEnd(line, i, end)
                    if (j == end || line[j] in WORD_AFTER) tokens += HiToken(i, j, HiKind.NUMBER)
                    i = maxOf(j, i + 1)
                }
                c.isLetter() || c == '_' -> {
                    var j = i + 1
                    while (j < end && (line[j].isLetterOrDigit() || line[j] == '_')) j++
                    // A keyword only where a command can start, and only as a whole word: never in
                    // a path (/usr/local), an option (--set), a variable ($done, ${in}) or a name (foo.do).
                    val alone = (i == 0 || line[i - 1] in WORD_BEFORE) && (j == end || line[j] in WORD_AFTER)
                    if (alone && line.substring(i, j) in SHELL_KEYWORDS) tokens += HiToken(i, j, HiKind.KEYWORD)
                    i = j
                }
                else -> i++
            }
        }
        return LexedLine(tokens, heredoc ?: LineState.Plain)
    }

    /** Index just past the closing [quote] from [from], or -1 when the line ends inside it. */
    private fun quoteEnd(from: Int, quote: Char): Int {
        var i = from
        while (i < end) {
            if (line[i] == '\\' && quote == '"') { i += 2; continue }
            if (line[i] == quote) return i + 1
            i++
        }
        return -1
    }

    /** `<<EOF`, `<<-EOF`, `<< 'EOF'`, `<<"EOF"`, `<<\EOF`: the body starts on the next line. */
    private fun heredocStart(from: Int): Int {
        var i = from
        val stripTabs = i < end && line[i] == '-'
        if (stripTabs) i++
        while (i < end && (line[i] == ' ' || line[i] == '\t')) i++
        if (i < end && line[i] == '\\') i++
        val quote = line.getOrNull(i)?.takeIf { (it == '\'' || it == '"') && i < end }
        if (quote != null) i++
        val wordStart = i
        while (i < end && (line[i].isLetterOrDigit() || line[i] == '_' || line[i] == '-' || line[i] == '.')) i++
        val delimiter = line.substring(wordStart, i)
        if (quote != null && i < end && line[i] == quote) i++
        if (delimiter.isNotEmpty()) {
            if (heredoc == null) heredoc = LineState.InHeredoc(delimiter, stripTabs)
            tokens += HiToken(wordStart, wordStart + delimiter.length, HiKind.STRING)
        }
        return maxOf(i, from)
    }

    private companion object {
        val COMMENT_BEFORE = setOf(' ', '\t', ';', '|', '&', '(', ')')
        /** What may come right before a keyword or number that stands alone. */
        val WORD_BEFORE = setOf(' ', '\t', ';', '|', '&', '(', '!', '`', '=')
        /** What may come right after one. */
        val WORD_AFTER = setOf(' ', '\t', ';', '|', '&', ')', '`', '\r')
    }
}

private class YamlLexer(private val line: String, private val start: LineState) {
    private val end = contentEnd(line)
    private val tokens = ArrayList<HiToken>()

    fun lex(): LexedLine {
        var i = 0
        when (start) {
            is LineState.InBlockScalar -> {
                val indent = indentOf()
                // Blank lines belong to the block; it ends at the first line indented no further than
                // its key.
                if (indent >= end) return LexedLine(tokens, start)
                if (indent > start.parentIndent) {
                    tokens += HiToken(indent, end, HiKind.STRING)
                    return LexedLine(tokens, start)
                }
            }
            is LineState.InQuote -> {
                val close = quoteEnd(0, start.quote)
                if (close < 0) {
                    if (end > 0) tokens += HiToken(0, end, HiKind.STRING)
                    return LexedLine(tokens, start)
                }
                tokens += HiToken(0, close, HiKind.STRING)
                i = close
                return LexedLine(tokens, scanValue(i, keyColumn = indentOf()))
            }
            else -> {}
        }
        val indent = indentOf()
        if (indent < end && line[indent] == '#') {
            tokens += HiToken(indent, end, HiKind.COMMENT)
            return LexedLine(tokens, LineState.Plain)
        }
        // Sequence entries ("- ", "- - ") and then, perhaps, "key:".
        var keyStart = indent
        while (keyStart + 1 < end && line[keyStart] == '-' && (line[keyStart + 1] == ' ' || line[keyStart + 1] == '\t')) {
            keyStart += 2
            while (keyStart < end && (line[keyStart] == ' ' || line[keyStart] == '\t')) keyStart++
        }
        if (keyStart < end && line[keyStart] == '-' && keyStart + 1 == end) keyStart = end
        i = keyStart
        val colon = keyColon(keyStart)
        if (colon > keyStart) {
            tokens += HiToken(keyStart, colon, HiKind.KEY)
            i = colon + 1
        }
        // A block scalar's lines are indented past its key, or past its "- " when it has none.
        return LexedLine(tokens, scanValue(i, keyColumn = if (colon > keyStart) keyStart else indent))
    }

    private fun indentOf(): Int {
        var i = 0
        while (i < end && line[i] == ' ') i++
        return i
    }

    /** The colon that ends a key at [from]: followed by a space, a tab or the end of the line. */
    private fun keyColon(from: Int): Int {
        if (from >= end || line[from] == '"' || line[from] == '\'' || line[from] == '#') {
            // A quoted key: "a b": 1
            if (from < end && (line[from] == '"' || line[from] == '\'')) {
                val close = quoteEnd(from + 1, line[from])
                if (close > 0 && close < end && line[close] == ':' && (close + 1 == end || line[close + 1] == ' ' || line[close + 1] == '\t')) {
                    return close
                }
            }
            return -1
        }
        var i = from
        while (i < end) {
            val c = line[i]
            if (c == ':' && (i + 1 == end || line[i + 1] == ' ' || line[i + 1] == '\t')) return i
            if (c == '#' && i > from && (line[i - 1] == ' ' || line[i - 1] == '\t')) return -1
            i++
        }
        return -1
    }

    /**
     * The value from [from]: a quoted scalar (which may run on), a block scalar indicator, a comment,
     * or plain scalars whose whole text is a number or a literal (`true`, `null`). A quote inside a
     * plain scalar (`Don't`) is just text.
     */
    private fun scanValue(from: Int, keyColumn: Int): LineState {
        var i = from
        var atScalarStart = true
        while (i < end) {
            val c = line[i]
            when {
                c == ' ' || c == '\t' -> i++
                c == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t') -> {
                    tokens += HiToken(i, end, HiKind.COMMENT)
                    return LineState.Plain
                }
                (c == '"' || c == '\'') && atScalarStart -> {
                    val close = quoteEnd(i + 1, c)
                    if (close < 0) {
                        tokens += HiToken(i, end, HiKind.STRING)
                        return LineState.InQuote(c)
                    }
                    tokens += HiToken(i, close, HiKind.STRING)
                    i = close
                    atScalarStart = false
                }
                (c == '|' || c == '>') && atScalarStart && blockIndicatorEnds(i + 1) -> {
                    return LineState.InBlockScalar(keyColumn)
                }
                c == '[' || c == '{' || c == ',' || c == ']' || c == '}' -> {
                    i++
                    atScalarStart = true
                }
                else -> {
                    // A plain scalar, up to a flow indicator or a comment.
                    val scalarStart = i
                    var j = i
                    while (j < end) {
                        val d = line[j]
                        if (d == ',' || d == ']' || d == '}' || d == '[' || d == '{') break
                        if (d == '#' && (line[j - 1] == ' ' || line[j - 1] == '\t')) break
                        if (d == ':' && (j + 1 == end || line[j + 1] == ' ' || line[j + 1] == '\t')) {
                            // "key: value" inside a flow mapping: the value starts after it.
                            j++
                            break
                        }
                        j++
                    }
                    var scalarEnd = j
                    while (scalarEnd > scalarStart && (line[scalarEnd - 1] == ' ' || line[scalarEnd - 1] == '\t')) scalarEnd--
                    val text = line.substring(scalarStart, scalarEnd)
                    if (!text.endsWith(':')) {
                        when {
                            text.lowercase() in YAML_LITERALS -> tokens += HiToken(scalarStart, scalarEnd, HiKind.KEYWORD)
                            text.isNotEmpty() && isNumberStart(text, 0, text.length) &&
                                numberEnd(text, 0, text.length) == text.length -> tokens += HiToken(scalarStart, scalarEnd, HiKind.NUMBER)
                        }
                    }
                    atScalarStart = text.endsWith(':')
                    i = maxOf(j, i + 1)
                }
            }
        }
        return LineState.Plain
    }

    /** After `|` or `>`: only chomping and indentation indicators, then the end or a comment. */
    private fun blockIndicatorEnds(from: Int): Boolean {
        var i = from
        while (i < end && (line[i] == '-' || line[i] == '+' || line[i].isDigit())) i++
        while (i < end && (line[i] == ' ' || line[i] == '\t')) i++
        return i == end || line[i] == '#'
    }

    /** Index just past the closing [quote]: `\"` escapes in double quotes, `''` in single. */
    private fun quoteEnd(from: Int, quote: Char): Int {
        var i = from
        while (i < end) {
            val c = line[i]
            if (quote == '"' && c == '\\') { i += 2; continue }
            if (c == quote) {
                if (quote == '\'' && i + 1 < end && line[i + 1] == '\'') { i += 2; continue }
                return i + 1
            }
            i++
        }
        return -1
    }
}

/**
 * Markdown as it is written: headings, list markers and task boxes, quote markers, emphasis markers,
 * code spans, link addresses, rules, table pipes and HTML comments. A fenced code block is coloured
 * as the language its fence names, line by line in that language's own state. Only colours change,
 * never the text's size or weight, so the editor's lines keep their places. Linear in the line's
 * length: the editor colours on the main thread.
 */
private class MarkdownLexer(private val line: String, private val start: LineState) {
    private val end = contentEnd(line)
    private val tokens = ArrayList<HiToken>()

    /** Set once a `](` on this line found no closing `)`: later ones will not either. */
    private var noClosingParen = false

    fun lex(): LexedLine {
        when (start) {
            is LineState.InFence -> return fenceLine(start)
            is LineState.InComment -> {
                val close = line.indexOf(start.close)
                if (close < 0 || close + start.close.length > end) {
                    if (end > 0) tokens += HiToken(0, end, HiKind.COMMENT)
                    return LexedLine(tokens, start)
                }
                val after = close + start.close.length
                tokens += HiToken(0, after, HiKind.COMMENT)
                return LexedLine(tokens, inline(after))
            }
            else -> {}
        }
        var i = spaces(0)
        var quoted = false
        while (i < end && line[i] == '>') {
            tokens += HiToken(i, i + 1, HiKind.COMMENT)
            quoted = true
            i = spaces(i + 1)
        }
        fenceOpen(i, quoted)?.let { return it }
        if (i < end && line[i] == '#') {
            var j = i
            while (j < end && line[j] == '#') j++
            if (j - i <= 6 && (j == end || line[j] == ' ' || line[j] == '\t')) {
                tokens += HiToken(i, end, HiKind.KEY)
                return LexedLine(tokens, LineState.Plain)
            }
        }
        if (isRule(i) || isTableDelimiterRow(i)) {
            tokens += HiToken(i, end, HiKind.COMMENT)
            return LexedLine(tokens, LineState.Plain)
        }
        return LexedLine(tokens, inline(listMarker(i)))
    }

    private fun spaces(from: Int): Int {
        var i = from
        while (i < end && (line[i] == ' ' || line[i] == '\t')) i++
        return i
    }

    /** ```` ``` ```` or `~~~` and an info string. A fence inside a quote is coloured, not followed. */
    private fun fenceOpen(at: Int, quoted: Boolean): LexedLine? {
        if (at >= end || (line[at] != '`' && line[at] != '~')) return null
        val fence = line[at]
        var j = at
        while (j < end && line[j] == fence) j++
        val length = j - at
        if (length < 3) return null
        val info = line.substring(j, end)
        if (fence == '`' && '`' in info) return null
        tokens += HiToken(at, end, HiKind.COMMENT)
        if (quoted) return LexedLine(tokens, LineState.Plain)
        val language = languageForFenceInfo(info).let { if (it == CodeLanguage.MARKDOWN) CodeLanguage.NONE else it }
        return LexedLine(tokens, LineState.InFence(fence, length, language, LineState.Plain))
    }

    private fun fenceLine(state: LineState.InFence): LexedLine {
        val i = spaces(0)
        var j = i
        while (j < end && line[j] == state.fence) j++
        if (j - i >= state.length && spaces(j) == end) {
            tokens += HiToken(i, end, HiKind.COMMENT)
            return LexedLine(tokens, LineState.Plain)
        }
        if (state.language == CodeLanguage.NONE) {
            if (end > 0) tokens += HiToken(0, end, HiKind.STRING)
            return LexedLine(tokens, state)
        }
        val inner = lexLine(line, state.language, state.inner)
        return LexedLine(inner.tokens, state.copy(inner = inner.endState))
    }

    /** `---`, `***`, `___`, or a setext heading's `===`: three or more of one of them, and spaces. */
    private fun isRule(from: Int): Boolean {
        if (from >= end) return false
        val c = line[from]
        if (c != '-' && c != '*' && c != '_' && c != '=') return false
        var count = 0
        for (k in from until end) {
            when (line[k]) {
                c -> count++
                ' ', '\t' -> {}
                else -> return false
            }
        }
        return count >= 3
    }

    /** A table's `| --- | :-: |` row. */
    private fun isTableDelimiterRow(from: Int): Boolean {
        var pipes = 0
        var dashes = 0
        for (k in from until end) {
            when (line[k]) {
                '|' -> pipes++
                '-' -> dashes++
                ':', ' ', '\t' -> {}
                else -> return false
            }
        }
        return pipes > 0 && dashes > 0
    }

    /** A list marker (`-`, `*`, `+`, `1.`, `2)`) and a task box after it; returns where the text starts. */
    private fun listMarker(at: Int): Int {
        if (at >= end) return at
        val c = line[at]
        var j = at
        when {
            c == '-' || c == '*' || c == '+' -> j = at + 1
            c.isDigit() -> {
                while (j < end && j - at < 9 && line[j].isDigit()) j++
                if (j < end && (line[j] == '.' || line[j] == ')')) j++ else return at
            }
            else -> return at
        }
        if (j < end && line[j] != ' ' && line[j] != '\t') return at
        tokens += HiToken(at, j, HiKind.KEYWORD)
        var k = spaces(j)
        if (k + 2 < end && line[k] == '[' && line[k + 2] == ']' && line[k + 1] in " xX" && (k + 3 == end || line[k + 3] == ' ')) {
            tokens += HiToken(k, k + 3, HiKind.KEYWORD)
            k += 3
        }
        return k
    }

    /** Inline markup from [from]; returns the state the next line starts in. */
    private fun inline(from: Int): LineState {
        var i = from
        // Backtick run lengths with no closing run later on this line: not searched for again.
        var failedTicks: HashSet<Int>? = null
        while (i < end) {
            val c = line[i]
            when {
                c == '\\' -> i += 2
                c == '`' -> {
                    var j = i
                    while (j < end && line[j] == '`') j++
                    val run = j - i
                    val close = if (failedTicks?.contains(run) == true) -1 else closingTicks(j, run)
                    if (close < 0) {
                        if (failedTicks == null) failedTicks = HashSet()
                        failedTicks.add(run)
                        i = j
                    } else {
                        tokens += HiToken(i, close + run, HiKind.STRING)
                        i = close + run
                    }
                }
                c == '<' && line.startsWith("<!--", i) -> {
                    val close = line.indexOf("-->", i + 4)
                    if (close < 0 || close + 3 > end) {
                        tokens += HiToken(i, end, HiKind.COMMENT)
                        return LineState.InComment("-->")
                    }
                    tokens += HiToken(i, close + 3, HiKind.COMMENT)
                    i = close + 3
                }
                c == '<' -> {
                    val close = autolinkEnd(i)
                    if (close > 0) {
                        tokens += HiToken(i, close, HiKind.NUMBER)
                        i = close
                    } else {
                        i++
                    }
                }
                c == ']' && i + 1 < end && line[i + 1] == '(' && !noClosingParen -> {
                    val close = closingParen(i + 1)
                    if (close < 0) {
                        noClosingParen = true
                        i++
                    } else {
                        tokens += HiToken(i + 1, close + 1, HiKind.NUMBER)
                        i = close + 1
                    }
                }
                c == ']' && i + 1 < end && line[i + 1] == '[' -> {
                    val close = line.indexOf(']', i + 2)
                    if (close in i + 2 until end) {
                        tokens += HiToken(i + 1, close + 1, HiKind.NUMBER)
                        i = close + 1
                    } else {
                        i++
                    }
                }
                c == ']' && i + 1 < end && line[i + 1] == ':' -> {
                    // A reference definition: `[label]: address`.
                    val from2 = spaces(i + 2)
                    var j = from2
                    while (j < end && !line[j].isWhitespace()) j++
                    if (j > from2) tokens += HiToken(from2, j, HiKind.NUMBER)
                    i = j
                }
                c == '*' || c == '_' || c == '~' -> i = delimiter(i)
                c == '|' -> {
                    tokens += HiToken(i, i + 1, HiKind.KEYWORD)
                    i++
                }
                (c == 'h' || c == 'H') && isBareUrl(i) -> {
                    var j = i
                    while (j < end && !line[j].isWhitespace() && line[j] != '<' && line[j] != '>' && line[j] != ')' && line[j] != ']') j++
                    tokens += HiToken(i, j, HiKind.NUMBER)
                    i = j
                }
                else -> i++
            }
        }
        return LineState.Plain
    }

    /** Start of the next run of exactly [run] backticks from [from], or -1. */
    private fun closingTicks(from: Int, run: Int): Int {
        var k = from
        while (k < end) {
            if (line[k] == '`') {
                var m = k
                while (m < end && line[m] == '`') m++
                if (m - k == run) return k
                k = m
            } else {
                k++
            }
        }
        return -1
    }

    /** The `)` that closes the `(` at [open], counting nested pairs, or -1. */
    private fun closingParen(open: Int): Int {
        var depth = 0
        var k = open
        while (k < end) {
            when (line[k]) {
                '\\' -> k++
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return k
                }
            }
            k++
        }
        return -1
    }

    /** Just past an autolink at [open] (`<https://...>`, `<me@example.org>`), or -1. */
    private fun autolinkEnd(open: Int): Int {
        var k = open + 1
        var marked = false
        while (k < end) {
            val c = line[k]
            if (c == '>') return if (marked && k > open + 1) k + 1 else -1
            if (c.isWhitespace() || c == '<') return -1
            if (c == ':' || c == '@') marked = true
            k++
        }
        return -1
    }

    private fun isBareUrl(at: Int): Boolean =
        (at == 0 || !line[at - 1].isLetterOrDigit()) &&
            (line.startsWith("http://", at, ignoreCase = true) || line.startsWith("https://", at, ignoreCase = true))

    /** A run of `*`, `_` or `~~` that can open or close emphasis; `snake_case` and `a * b` are text. */
    private fun delimiter(at: Int): Int {
        val c = line[at]
        var j = at
        while (j < end && line[j] == c) j++
        val before = if (at > 0) line[at - 1] else ' '
        val after = if (j < end) line[j] else ' '
        val flanking = !after.isWhitespace() || !before.isWhitespace()
        val intraword = before.isLetterOrDigit() && after.isLetterOrDigit()
        val emphasis = flanking && when (c) {
            '_' -> !intraword
            '~' -> j - at == 2
            else -> true
        }
        if (emphasis) tokens += HiToken(at, j, HiKind.KEYWORD)
        return j
    }
}

/**
 * JSON, and the comments and unquoted keys JSONC and JSON5 files have: keys, strings, numbers,
 * `true`/`false`/`null`, line and block comments. A string never runs past its line, which JSON
 * does not allow, so one missing quote colours one line, not the rest of the file.
 */
private class JsonLexer(private val line: String, private val start: LineState) {
    private val end = contentEnd(line)
    private val tokens = ArrayList<HiToken>()

    fun lex(): LexedLine {
        var i = 0
        if (start is LineState.InComment) {
            val close = line.indexOf("*/")
            if (close < 0 || close + 2 > end) {
                if (end > 0) tokens += HiToken(0, end, HiKind.COMMENT)
                return LexedLine(tokens, start)
            }
            tokens += HiToken(0, close + 2, HiKind.COMMENT)
            i = close + 2
        }
        while (i < end) {
            val c = line[i]
            when {
                c == '"' || c == '\'' -> {
                    val close = stringEnd(i + 1, c)
                    val stop = if (close < 0) end else close
                    tokens += HiToken(i, stop, if (close > 0 && isKey(close)) HiKind.KEY else HiKind.STRING)
                    i = stop
                }
                c == '/' && i + 1 < end && line[i + 1] == '/' -> {
                    tokens += HiToken(i, end, HiKind.COMMENT)
                    i = end
                }
                c == '/' && i + 1 < end && line[i + 1] == '*' -> {
                    val close = line.indexOf("*/", i + 2)
                    if (close < 0 || close + 2 > end) {
                        tokens += HiToken(i, end, HiKind.COMMENT)
                        return LexedLine(tokens, LineState.InComment("*/"))
                    }
                    tokens += HiToken(i, close + 2, HiKind.COMMENT)
                    i = close + 2
                }
                isNumberStart(line, i, end) && (i == 0 || line[i - 1] in BEFORE_VALUE) -> {
                    val j = numberEnd(line, i, end)
                    if (j == end || line[j] in AFTER_VALUE) tokens += HiToken(i, j, HiKind.NUMBER)
                    i = maxOf(j, i + 1)
                }
                c.isLetter() || c == '_' || c == '$' -> {
                    var j = i + 1
                    while (j < end && (line[j].isLetterOrDigit() || line[j] == '_' || line[j] == '$')) j++
                    when {
                        line.regionMatches(i, "true", 0, 4) && j - i == 4 -> tokens += HiToken(i, j, HiKind.KEYWORD)
                        line.regionMatches(i, "false", 0, 5) && j - i == 5 -> tokens += HiToken(i, j, HiKind.KEYWORD)
                        line.regionMatches(i, "null", 0, 4) && j - i == 4 -> tokens += HiToken(i, j, HiKind.KEYWORD)
                        isKey(j) -> tokens += HiToken(i, j, HiKind.KEY)
                    }
                    i = j
                }
                else -> i++
            }
        }
        return LexedLine(tokens, LineState.Plain)
    }

    /** Whether a `:` follows [after], past spaces: what makes a string a key. */
    private fun isKey(after: Int): Boolean {
        var k = after
        while (k < end && (line[k] == ' ' || line[k] == '\t')) k++
        return k < end && line[k] == ':'
    }

    /** Just past the closing [quote] from [from] (`\"` escapes), or -1 when the line ends first. */
    private fun stringEnd(from: Int, quote: Char): Int {
        var i = from
        while (i < end) {
            if (line[i] == '\\') {
                i += 2
                continue
            }
            if (line[i] == quote) return i + 1
            i++
        }
        return -1
    }

    private companion object {
        val BEFORE_VALUE = setOf(' ', '\t', '[', ',', ':')
        val AFTER_VALUE = setOf(' ', '\t', ',', ']', '}', '\r', '/')
    }
}

/**
 * All tokens for the whole text, each line starting in the state the one before ended in. Pure for
 * unit-testing; the editor gets the same tokens from an [IncrementalHighlighter] it keeps.
 */
fun highlightAll(text: String, lang: CodeLanguage): List<HiToken> =
    if (lang == CodeLanguage.NONE) emptyList() else IncrementalHighlighter(lang).tokens(text)

/**
 * Highlights a buffer as it is edited. A line whose text and starting state are unchanged reuses its
 * tokens, and the same text twice in a row (a cursor move, an IME composing update) costs nothing.
 */
internal class IncrementalHighlighter(private val lang: CodeLanguage) {
    private val lines = HashMap<Pair<LineState, String>, LexedLine>()
    private var lastText: String? = null
    private var lastTokens: List<HiToken> = emptyList()

    fun tokens(text: String): List<HiToken> {
        if (text == lastText) return lastTokens
        if (lines.size > MAX_CACHED_LINES) lines.clear()
        val out = ArrayList<HiToken>()
        var base = 0
        var state: LineState = LineState.Plain
        var index = 0
        while (index <= text.length) {
            val newline = text.indexOf('\n', index).let { if (it < 0) text.length else it }
            val line = text.substring(index, newline)
            val lexed = lines.getOrPut(state to line) { lexLine(line, lang, state) }
            lexed.tokens.mapTo(out) { HiToken(it.start + base, it.end + base, it.kind) }
            state = lexed.endState
            base += line.length + 1
            index = newline + 1
        }
        lastText = text
        lastTokens = out
        return out
    }

    private companion object {
        const val MAX_CACHED_LINES = 50_000
    }
}

/** [text] coloured by [tokens] in [palette]: the editor's colouring, which the Markdown preview's code blocks use too. */
fun highlightedText(text: String, tokens: List<HiToken>, palette: HighlightPalette): AnnotatedString =
    AnnotatedString(text, tokens.map { AnnotatedString.Range(SpanStyle(color = palette.colorFor(it.kind)), it.start, it.end) })

/**
 * [VisualTransformation] that colours the buffer for [lang] using [palette] without changing its
 * layout (offsets map 1:1, so cursor/selection math is untouched). Highlighting is skipped when the
 * text exceeds [maxChars] (the user-configurable cap, already clamped via [clampHighlightLimit]).
 */
class CodeHighlightTransformation(
    private val lang: CodeLanguage,
    private val palette: HighlightPalette,
    private val maxChars: Int,
) : VisualTransformation {
    private val highlighter = IncrementalHighlighter(lang)

    override fun filter(text: AnnotatedString): TransformedText {
        if (lang == CodeLanguage.NONE || maxChars <= 0 || text.length > maxChars) {
            return TransformedText(text, OffsetMapping.Identity)
        }
        return TransformedText(highlightedText(text.text, highlighter.tokens(text.text), palette), OffsetMapping.Identity)
    }
}
