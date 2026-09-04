package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Every generated remote command must be valid POSIX `sh`.
 *
 * These strings are assembled by concatenation, so an edit can easily leave a shell construct
 * unbalanced — an `else`/`fi` bolted onto what was actually an `&&` chain, an unclosed quote, a
 * missing `done`. The Kotlin compiler cannot see any of that: it is a syntactically fine Kotlin
 * string that happens to be broken shell.
 *
 * The failure mode is severe and silent. `sh` aborts the whole script at the syntax error, so a
 * single bad section takes out *every* section after it: the metrics probe returns nothing, the host
 * reports no memory or disk at all, and alerts that depend on those values simply never fire. That
 * exact bug shipped into a device run and cost a full emulator cycle to find, when `sh -n` would
 * have caught it in milliseconds.
 *
 * `sh -n` parses without executing, so this is safe to run anywhere and touches no remote host.
 */
class RemoteCommandShellSyntaxTest {

    private fun shell(): File? =
        listOf("/bin/sh", "/usr/bin/sh", "/bin/dash").map(::File).firstOrNull { it.canExecute() }

    private fun assertParses(label: String, script: String) {
        val sh = shell() ?: return
        val proc = ProcessBuilder(sh.absolutePath, "-n")
            .redirectErrorStream(true)
            .start()
        proc.outputStream.use { it.write(script.toByteArray()) }
        val output = proc.inputStream.bufferedReader().readText().trim()
        val code = proc.waitFor()
        check(code == 0) { "$label is not valid POSIX sh (sh -n exit $code):\n$output\n\n--- script ---\n$script" }
    }

    @Test
    fun everyGeneratedRemoteCommandIsValidPosixShell() {
        assumeTrue("POSIX sh is required to parse the generated commands", shell() != null)

        val commands = linkedMapOf(
            "METRICS" to RemoteCommands.METRICS,
            "DOCKER_PS" to RemoteCommands.DOCKER_PS,
            "DOCKER_RUNTIMES" to RemoteCommands.DOCKER_RUNTIMES,
            "DOCKER_RESTARTS" to RemoteCommands.DOCKER_RESTARTS,
            "DOCKER_IMAGES" to RemoteCommands.DOCKER_IMAGES,
            "DOCKER_VOLUMES" to RemoteCommands.DOCKER_VOLUMES,
            "DOCKER_NETWORKS" to RemoteCommands.DOCKER_NETWORKS,
            "SERVICES" to RemoteCommands.SERVICES,
            "PROCESSES" to RemoteCommands.PROCESSES,
            "OS_PROBE" to RemoteCommands.OS_PROBE,
            "TMUX_CHECK" to RemoteCommands.TMUX_CHECK,
            "CRON_READ_COMMAND" to RemoteCommands.CRON_READ_COMMAND,
            "journal(Linux)" to RemoteCommands.journal(200, "Linux"),
            "dockerPruneImages" to RemoteCommands.dockerPruneImages(),
            "dockerPruneVolumes" to RemoteCommands.dockerPruneVolumes(),
            "dockerPruneNetworks" to RemoteCommands.dockerPruneNetworks(),
            "tmuxHasSessionCommand" to RemoteCommands.tmuxHasSessionCommand("omniterm-1"),
            "tmuxCaptureHistoryCommand" to RemoteCommands.tmuxCaptureHistoryCommand("omniterm-1", 5_000),
        )

        commands.forEach { (label, script) -> assertParses(label, script) }
    }

    /**
     * The bound helper must be *defined* in every command that calls `ot`.
     *
     * A command that uses `ot` without [RemoteCommands.OT_HELPER] parses fine — `ot 5 df` is a valid
     * command invocation — and then fails at runtime with "ot: not found", losing that section on
     * every host. `sh -n` cannot catch it, so it is checked explicitly.
     */
    @Test
    fun everyCommandThatCallsOtAlsoDefinesIt() {
        val usesOt = Regex("""\bot \d+ """)
        val commands = mapOf(
            "METRICS" to RemoteCommands.METRICS,
            "DOCKER_PS" to RemoteCommands.DOCKER_PS,
            "DOCKER_RUNTIMES" to RemoteCommands.DOCKER_RUNTIMES,
            "DOCKER_RESTARTS" to RemoteCommands.DOCKER_RESTARTS,
            "DOCKER_IMAGES" to RemoteCommands.DOCKER_IMAGES,
            "DOCKER_VOLUMES" to RemoteCommands.DOCKER_VOLUMES,
            "DOCKER_NETWORKS" to RemoteCommands.DOCKER_NETWORKS,
            "SERVICES" to RemoteCommands.SERVICES,
            "journal(Linux)" to RemoteCommands.journal(200, "Linux"),
            "dockerPruneImages" to RemoteCommands.dockerPruneImages(),
            "dockerPruneVolumes" to RemoteCommands.dockerPruneVolumes(),
            "dockerPruneNetworks" to RemoteCommands.dockerPruneNetworks(),
        )
        commands.forEach { (label, script) ->
            if (usesOt.containsMatchIn(script)) {
                check(script.contains("ot(){")) { "$label calls `ot` but never defines it (missing OT_HELPER)" }
            }
        }
    }
}
