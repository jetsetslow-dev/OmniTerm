package com.jetsetslow.omniterm.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation

/**
 * Theme-aware highlight palette resolved from the current MaterialTheme. Dark/AMOLED get bright
 * accents on near-black; light gets deeper accents readable on white; both keep a comment colour with
 * real contrast (the old fixed `OmniColors.textMuted` was near-invisible). High-contrast themes feed
 * in their own strong scheme colours here too.
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
enum class CodeLanguage { NONE, YAML, SHELL }

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

/** Map a filename to a [CodeLanguage] by extension. Pure for unit-testing. */
fun languageForFileName(name: String): CodeLanguage {
    val lower = name.substringAfterLast('/').lowercase()
    val ext = lower.substringAfterLast('.', "")
    return when {
        ext == "yml" || ext == "yaml" -> CodeLanguage.YAML
        ext == "sh" || ext == "bash" || ext == "zsh" -> CodeLanguage.SHELL
        lower == "dockerfile" || lower.endsWith(".env") || ext == "conf" || ext == "ini" ||
            ext == "cfg" || ext == "properties" -> CodeLanguage.SHELL // close enough: # comments + KEY=val + strings
        else -> CodeLanguage.NONE
    }
}

private val YAML_LITERALS = setOf("true", "false", "null", "yes", "no", "on", "off", "~")
private val SHELL_KEYWORDS = setOf(
    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
    "function", "in", "return", "export", "local", "echo", "cd", "exit", "set", "source",
)

/**
 * Tokenize one line into coloured spans for [lang]. Line-scoped (no multi-line constructs) which keeps
 * it cheap and robust for an editable buffer. [base] is the absolute offset of the line in the file.
 * Pure for unit-testing.
 */
fun highlightLine(line: String, base: Int, lang: CodeLanguage): List<HiToken> {
    if (lang == CodeLanguage.NONE || line.isEmpty()) return emptyList()
    val tokens = ArrayList<HiToken>()
    var i = 0
    // Leading-whitespace + (YAML) key detection.
    if (lang == CodeLanguage.YAML) {
        val trimmed = line.trimStart()
        val indent = line.length - trimmed.length
        // "key:" (optionally after a "- ") → colour the key up to the colon.
        val afterDash = if (trimmed.startsWith("- ")) indent + 2 else indent
        val colon = line.indexOf(':', afterDash)
        if (colon > afterDash && line.getOrNull(colon + 1).let { it == null || it == ' ' }) {
            tokens.add(HiToken(base + afterDash, base + colon, HiKind.KEY))
            i = colon + 1
        }
    }
    while (i < line.length) {
        val c = line[i]
        when {
            // Comments: # to end of line (both YAML and shell). Require start or preceding space so a
            // '#' inside a value/URL fragment isn't misread.
            c == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t') -> {
                tokens.add(HiToken(base + i, base + line.length, HiKind.COMMENT)); i = line.length
            }
            c == '"' || c == '\'' -> {
                val end = findStringEnd(line, i, c)
                tokens.add(HiToken(base + i, base + end, HiKind.STRING)); i = end
            }
            c.isDigit() && (i == 0 || !line[i - 1].isLetterOrDigit() && line[i - 1] != '_') -> {
                var j = i + 1
                while (j < line.length && (line[j].isDigit() || line[j] == '.')) j++
                tokens.add(HiToken(base + i, base + j, HiKind.NUMBER)); i = j
            }
            c.isLetter() -> {
                var j = i + 1
                while (j < line.length && (line[j].isLetterOrDigit() || line[j] == '_' || line[j] == '-')) j++
                val word = line.substring(i, j)
                val kw = when (lang) {
                    CodeLanguage.YAML -> word.lowercase() in YAML_LITERALS
                    CodeLanguage.SHELL -> word in SHELL_KEYWORDS
                    else -> false
                }
                if (kw) tokens.add(HiToken(base + i, base + j, HiKind.KEYWORD))
                i = j
            }
            else -> i++
        }
    }
    return tokens
}

/** Index just past the closing quote (or end of line if unterminated). */
private fun findStringEnd(line: String, openIdx: Int, quote: Char): Int {
    var i = openIdx + 1
    while (i < line.length) {
        if (line[i] == '\\' && quote == '"') { i += 2; continue } // shell/dquote escapes
        if (line[i] == quote) return i + 1
        i++
    }
    return line.length
}

/** All tokens for the whole text, walking line by line. Pure for unit-testing. */
fun highlightAll(text: String, lang: CodeLanguage): List<HiToken> {
    if (lang == CodeLanguage.NONE) return emptyList()
    val out = ArrayList<HiToken>()
    var base = 0
    for (line in text.split('\n')) {
        out.addAll(highlightLine(line, base, lang))
        base += line.length + 1 // + the '\n'
    }
    return out
}

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
    override fun filter(text: AnnotatedString): TransformedText {
        if (lang == CodeLanguage.NONE || maxChars <= 0 || text.length > maxChars) {
            return TransformedText(text, OffsetMapping.Identity)
        }
        val spans = highlightAll(text.text, lang).map {
            AnnotatedString.Range(SpanStyle(color = palette.colorFor(it.kind)), it.start, it.end)
        }
        return TransformedText(
            AnnotatedString(text.text, spans),
            OffsetMapping.Identity,
        )
    }
}
