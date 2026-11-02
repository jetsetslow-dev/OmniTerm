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

    /**
     * A test that installs its own Main clears its ViewModels through
     * [clearViewModelsAndAwaitTerminalJobs]. Clearing the store directly cancels their work without
     * waiting for it, so `resetMain()` right after races the last dispatch back to Main: four tests
     * did that and one failed a full local run while passing every run on its own.
     */
    @Test
    fun aTestThatSetsMainWaitsForItsViewModelsBeforeResettingIt() {
        val root = listOf(File("src/test"), File("app/src/test")).first { it.isDirectory }
        val offenders = root.walkTopDown()
            .filter { it.extension == "kt" && it.name !in SHARED_TEARDOWN_AND_ITS_TEST }
            .filter { file -> file.readText().contains("Dispatchers.setMain(") }
            .flatMap { file ->
                file.readLines().withIndex()
                    .filter { (_, line) -> STORE_CLEAR.containsMatchIn(line) }
                    .map { (index, line) -> "${file.relativeTo(root)}:${index + 1}: ${line.trim()}" }
            }.toList()
        assertTrue(
            "Clear ViewModels with clearViewModelsAndAwaitTerminalJobs before resetMain:\n" +
                offenders.joinToString("\n"),
            offenders.isEmpty(),
        )
    }

    private companion object {
        /** A loop whose condition reads a ViewModel: `model`, `viewModel`, `vm` and the like. */
        val VIEW_MODEL_POLL = Regex("""\bwhile\s*\(.*\b(\w*[mM]odel|vm)\.""")

        val STORE_CLEAR = Regex("""\b\w*[sS]tore\.clear\(\)""")

        /** The teardown itself, and the test that proves it waits (its fallback clears directly). */
        val SHARED_TEARDOWN_AND_ITS_TEST = setOf("RealMainViewModelCleanup.kt", "TerminalLeavePersistenceRobolectricTest.kt")
    }
}
