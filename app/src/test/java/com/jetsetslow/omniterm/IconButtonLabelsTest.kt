package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertWithMessage
import java.io.File
import org.junit.Test

/**
 * Every icon-only button must carry an accessible name.
 *
 * An `IconButton` whose only content is an `Icon` with a null `contentDescription` is announced by
 * TalkBack as "button" and nothing else. The session picker's close, the alert-rule edit and
 * delete, the profile and key deletes and the port-forward dropdown arrows all shipped that way.
 *
 * This is a source scan on purpose: the defect is not one screen, it is that nothing stopped the
 * next one, and a per-screen test only covers the screens someone remembered to test. The Flutter
 * app runs the same check (`test/accessibility_labels_test.dart`).
 */
class IconButtonLabelsTest {
    private val unnamedIcon = Regex("""Icon\([^)]*?(,\s*null\b|contentDescription\s*=\s*null)""", RegexOption.DOT_MATCHES_ALL)

    @Test
    fun noIconOnlyButtonShipsWithoutAnAccessibleName() {
        val sources = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "app/src/main/java").takeIf(File::isDirectory) ?: File(it, "src/main/java") }
            .first { it.isDirectory }
        val offenders = sources.walkTopDown().filter { it.extension == "kt" }.flatMap { file ->
            val source = file.readText()
            Regex("""\bIconButton\s*\(""").findAll(source).mapNotNull { match ->
                val content = contentLambda(source, match.range.last + 1) ?: return@mapNotNull null
                if (content.contains("Text(") || !unnamedIcon.containsMatchIn(content)) return@mapNotNull null
                val line = source.substring(0, match.range.first).count { it == '\n' } + 1
                "${file.relativeTo(sources)}:$line"
            }.toList()
        }.toList()

        assertWithMessage(
            "These icon buttons announce as \"button\" with no name. Give each Icon a contentDescription:\n  " +
                offenders.joinToString("\n  "),
        ).that(offenders).isEmpty()
    }

    /** The trailing `{ ... }` after the argument list that starts at [start], or null if there is none. */
    private fun contentLambda(source: String, start: Int): String? {
        var i = start
        var depth = 1
        while (i < source.length && depth > 0) {
            when (source[i]) { '(' -> depth++; ')' -> depth-- }
            i++
        }
        while (i < source.length && source[i].isWhitespace()) i++
        if (i >= source.length || source[i] != '{') return null
        val open = i++
        depth = 1
        while (i < source.length && depth > 0) {
            when (source[i]) { '{' -> depth++; '}' -> depth-- }
            i++
        }
        return source.substring(open, i)
    }
}
