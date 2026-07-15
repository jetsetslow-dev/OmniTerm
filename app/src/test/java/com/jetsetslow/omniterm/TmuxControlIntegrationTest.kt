package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TmuxControlCommands
import com.jetsetslow.omniterm.data.term.TmuxControlEvent
import com.jetsetslow.omniterm.data.term.TmuxControlParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit

/**
 * End-to-end contract test for commands sent over `tmux -C` stdin.
 *
 * String assertions alone allowed `%0:pause` to be blessed even though tmux rejects it. This test
 * starts an isolated real tmux server, sends every command produced by [TmuxControlCommands], and
 * parses the real control transcript so any `%error` reply fails the release gate.
 */
class TmuxControlIntegrationTest {

    @Test
    fun everyGeneratedCommandIsAcceptedByRealTmuxControlMode() {
        val tmux = requireTmuxOrSkipLocalRun()
        val unique = "${ProcessHandle.current().pid()}-${System.nanoTime()}"
        val socket = "omniterm-junit-$unique"
        val session = "omniterm-junit"

        try {
            assertCommandSucceeded(
                runCommand(
                    tmux, "-L", socket, "-f", "/dev/null", "new-session", "-d",
                    "-x", "80", "-y", "24", "-s", session, "/bin/sh",
                ),
                "start isolated tmux server",
            )
            val paneResult = runCommand(
                tmux, "-L", socket, "display-message", "-p", "-t", session, "#{pane_id}",
            )
            assertCommandSucceeded(paneResult, "resolve tmux pane")
            val pane = paneResult.output.trim()
            assertTrue("unexpected pane id: $pane", Regex("%\\d+").matches(pane))

            val commands = buildList {
                add(TmuxControlCommands.refreshClientSize(100, 30))
                add(TmuxControlCommands.activePaneQuery())
                add(TmuxControlCommands.paneOutputState(pane, "pause"))
                addAll(TmuxControlCommands.sendKeysHex(pane, "printf tmux-control-ok\\r".encodeToByteArray()))
                add(TmuxControlCommands.paneOutputState(pane, "continue"))
                add(TmuxControlCommands.paneOutputState(pane, "off"))
                add(TmuxControlCommands.paneOutputState(pane, "on"))
                add(TmuxControlCommands.capturePane(pane, 10, includeScreen = false))
                add(TmuxControlCommands.capturePane(pane, 10, includeScreen = true))
                add("detach-client")
            }

            val control = isolatedTmuxProcessBuilder(
                tmux, "-L", socket, "-C", "attach-session", "-t", session,
            ).start()
            control.outputStream.bufferedWriter().use { writer ->
                commands.forEach {
                    writer.write(it)
                    writer.newLine()
                }
            }
            if (!control.waitFor(PROCESS_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                control.destroyForcibly()
                fail("tmux control client did not exit after detach-client")
            }
            val transcript = control.inputStream.readBytes()
            assertEquals("tmux control client failed:\n${transcript.decodeToString()}", 0, control.exitValue())

            val events = TmuxControlParser().feed(transcript)
            val replies = events.filterIsInstance<TmuxControlEvent.Reply>()
            val errors = replies.filter { it.isError }
            assertTrue(
                "tmux rejected generated control command(s):\n${transcript.decodeToString()}",
                errors.isEmpty(),
            )
            // One reply for attach itself, then exactly one for every command written above.
            assertEquals("missing command replies:\n${transcript.decodeToString()}", commands.size + 1, replies.size)
            assertTrue(
                "active-pane query did not execute:\n${transcript.decodeToString()}",
                replies.any { it.body.startsWith("$pane ") },
            )
            assertTrue(events.any { it is TmuxControlEvent.Exit })
            assertFalse(transcript.decodeToString().contains("parse error", ignoreCase = true))
        } finally {
            runCatching { runCommand(tmux, "-L", socket, "kill-server") }
        }
    }

    private fun requireTmuxOrSkipLocalRun(): String {
        // Never resolve an executable through the working directory or an inherited PATH. The CI
        // package installs tmux in /usr/bin; /usr/local/bin covers standard local installations.
        val executable = TMUX_EXECUTABLES.firstOrNull { Files.isExecutable(Path.of(it)) }
        val available = executable != null &&
            runCatching { runCommand(executable, "-V").exitCode == 0 }.getOrDefault(false)
        if (System.getenv("OMNITERM_REQUIRE_TMUX_INTEGRATION") == "true") {
            assertTrue("tmux is required for the CI control-mode integration gate", available)
        } else {
            assumeTrue("tmux is unavailable; CI always installs and requires it", available)
        }
        return checkNotNull(executable)
    }

    private fun assertCommandSucceeded(result: CommandResult, operation: String) {
        assertEquals("could not $operation:\n${result.output}", 0, result.exitCode)
    }

    private fun runCommand(vararg command: String): CommandResult {
        val process = isolatedTmuxProcessBuilder(*command).start()
        if (!process.waitFor(PROCESS_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            fail("command timed out: ${command.joinToString(" ")}")
        }
        return CommandResult(process.exitValue(), process.inputStream.bufferedReader().readText())
    }

    /**
     * The developer/test runner may itself live inside tmux. Inheriting TMUX makes a supposedly
     * isolated `tmux -L <socket> -C attach` behave like a nested command for the outer client; the
     * generated client-scoped commands then fail with "no current client". Remove both client
     * markers so the explicit test socket is the only tmux context in local runs and CI.
     */
    private fun isolatedTmuxProcessBuilder(vararg command: String): ProcessBuilder =
        ProcessBuilder(*command).redirectErrorStream(true).also { builder ->
            builder.environment().remove("TMUX")
            builder.environment().remove("TMUX_PANE")
        }

    private data class CommandResult(val exitCode: Int, val output: String)

    private companion object {
        const val PROCESS_TIMEOUT_SECONDS = 10L
        val TMUX_EXECUTABLES = listOf("/usr/bin/tmux", "/usr/local/bin/tmux")
    }
}
