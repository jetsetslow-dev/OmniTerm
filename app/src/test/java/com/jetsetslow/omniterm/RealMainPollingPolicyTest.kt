package com.jetsetslow.omniterm

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Tests read ViewModel state on the main dispatcher, through [waitWhileOnMain].
 *
 * A loop that polls it from the test's own thread can land between two writes the ViewModel makes
 * together. Such a test passes almost every time and fails now and then: one failed in a release
 * build after passing on its pull request. Chance cannot be relied on to catch that, so this
 * catches the pattern instead.
 */
class RealMainPollingPolicyTest {
    @Test
    fun viewModelStateIsNotPolledFromTheTestThread() {
        val root = listOf(File("src/test"), File("app/src/test")).first { it.isDirectory }
        val offenders = root.walkTopDown().filter { it.extension == "kt" }.flatMap { file ->
            file.readLines().withIndex()
                .filter { (_, line) -> VIEW_MODEL_POLL.containsMatchIn(line) }
                .map { (index, line) -> "${file.relativeTo(root)}:${index + 1}: ${line.trim()}" }
        }.toList()
        assertTrue(
            "Wait on ViewModel state with waitWhileOnMain, not a loop on the test thread:\n" +
                offenders.joinToString("\n"),
            offenders.isEmpty(),
        )
    }

    private companion object {
        /** A loop whose condition reads a ViewModel: `model`, `viewModel`, `vm` and the like. */
        val VIEW_MODEL_POLL = Regex("""\bwhile\s*\(.*\b(\w*[mM]odel|vm)\.""")
    }
}
