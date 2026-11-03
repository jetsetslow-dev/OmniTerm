package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.SystemSpecsCommands
import com.jetsetslow.omniterm.ui.builtInFleetPresetCommands
import com.jetsetslow.omniterm.ui.fleetPresetWindowsScripts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * App commands reach a host the same whatever its login shell is.
 *
 * sshd hands every command to the user's login shell. On the lab's hosts csh failed every app
 * command, fish every list that defines a function or uses `$(…)`, zsh split words its own way, and
 * a PowerShell login shell on Windows expanded `$_` before PowerShell itself saw the script. These
 * run the wrapped commands through each shell this machine has, as sshd would (`shell -c command`),
 * so the escaping is checked rather than only the command text.
 */
class CrossShellCommandsTest {

    /** Quotes of both kinds, backslashes, `!`, `%`, `$`, backticks, non-ASCII, newlines and globs. */
    private val tricky = """
        x='it'"'"'s "q" \b \\ !bang %d %s ${'$'}HOME `x` ünï'; printf '%s\n' "${'$'}x"
        ids=${'$'}(printf 'a b c'); for i in ${'$'}ids; do printf '[%s]' "${'$'}i"; done; echo
        f() { echo "fn ${'$'}1"; }; f ok
        ls /nonexistent-omniterm-* 2>/dev/null || echo noglob
        exit 3
    """.trimIndent()

    private val trickyOutput = "it's \"q\" \\b \\\\ !bang %d %s \$HOME `x` ünï\n[a][b][c]\nfn ok\nnoglob\n"

    private val loginShells = listOf("sh", "dash", "bash", "zsh", "ksh", "mksh", "tcsh", "csh", "fish")
        .mapNotNull { name -> listOf("/bin", "/usr/bin", "/usr/local/bin").map { File(it, name) }.firstOrNull { it.canExecute() } }

    private fun run(shell: File, command: String): Pair<String, Int> {
        val proc = ProcessBuilder(shell.absolutePath, "-c", command).redirectErrorStream(true).start()
        val output = proc.inputStream.bufferedReader().readText()
        return output to proc.waitFor()
    }

    @Test
    fun everyLoginShellRunsTheWrappedScriptAsSh() {
        assumeTrue("POSIX sh is required", loginShells.isNotEmpty())
        val command = RemoteCommands.inPosixShell(tricky)
        loginShells.forEach { shell ->
            val (output, code) = run(shell, command)
            assertEquals("${shell.name}: $output", trickyOutput, output)
            assertEquals(shell.name, 3, code)
        }
    }

    @Test
    fun theWrappedScriptHoldsNothingALoginShellReadsSpecially() {
        val command = RemoteCommands.inPosixShell(tricky)
        val quoted = command.substringAfter("'").substringBeforeLast("'")
        // csh expands `!` even inside single quotes; fish ends them at a quote or doubled backslash.
        assertFalse(command, quoted.any { it == '\'' || it == '!' || it == '\n' || it == '\r' })
        assertFalse(command, quoted.contains("\\\\"))
        assertTrue(command, command.startsWith("exec sh -c '"))
    }

    @Test
    fun theWrappedScriptFindsToolsOutsideTheBarePath() {
        val sh = loginShells.firstOrNull() ?: return assumeTrue("POSIX sh is required", false)
        val (output, _) = run(sh, RemoteCommands.inPosixShell("printf '%s' \"\$PATH\""))
        listOf("/opt/homebrew/bin", "/usr/local/bin", "/opt/podman/bin").forEach { assertTrue(output, output.contains(it)) }
    }

    @Test
    fun typedLinesChangeOnlyForShellsThatCannotReadSh() {
        val line = RemoteCommands.tmuxAttachCommand("omniterm-1")
        listOf(null, "", "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/local/bin/zsh", "/bin/ksh", "/bin/ash").forEach {
            assertEquals(it.toString(), line, RemoteCommands.forInteractiveShell(line, it))
        }
        listOf("/bin/tcsh", "/bin/csh", "/usr/local/bin/fish").forEach {
            val typed = RemoteCommands.forInteractiveShell(line, it)
            assertTrue(typed, typed.startsWith("sh -c '") && typed.endsWith("' && exit\n"))
            assertEquals(typed, 1, typed.count { c -> c == '\n' })
        }
    }

    @Test
    fun aFailedTypedLineLeavesTheLoginShellRunning() {
        loginShells.filter { it.name in setOf("tcsh", "csh", "fish") }.forEach { shell ->
            val typed = RemoteCommands.forInteractiveShell("echo typed; exit 4\n", shell.absolutePath)
            val (output, _) = run(shell, typed + "echo still-here\n")
            assertEquals(shell.name, "typed\nstill-here\n", output)
        }
    }

    @Test
    fun powershellScriptsSurviveEveryShellUnchanged() {
        val script = "Get-Service | ForEach-Object { \$_.Name + [char]9 + \"it's\" + 'ünï' }"
        val command = RemoteCommands.powershell(script)
        assertTrue(command, command.matches(Regex("powershell -NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/=]+")))
        val decoded = String(java.util.Base64.getDecoder().decode(command.substringAfterLast(' ')), Charsets.UTF_16LE)
        assertEquals("\$ProgressPreference='SilentlyContinue'; $script", decoded)
    }

    /** A built-in preset runs on Windows what its own text shows, under any login shell. */
    @Test
    fun builtInPresetsRunTheirOwnPowerShellOnWindows() {
        val segment = Regex("""powershell -NoProfile -Command "([^"]*)"""")
        builtInFleetPresetCommands.forEach { (key, command) ->
            val script = fleetPresetWindowsScripts[key]
            assertTrue("$key has no Windows script", script != null)
            segment.findAll(command).forEach { assertTrue("$key: ${it.groupValues[1]}", script!!.contains(it.groupValues[1])) }
            assertTrue(key, RemoteCommands.powershell(script!!).length <= RemoteCommands.WINDOWS_COMMAND_MAX)
        }
    }

    /** cmd.exe, OpenSSH's default shell on Windows, runs nothing longer than 8191 characters. */
    @Test
    fun everyWindowsCommandFitsCmdsLineLimit() {
        val longName = "s".repeat(256)
        val commands = mapOf(
            "metrics" to RemoteCommands.metricsFor("Windows"),
            "processes" to RemoteCommands.processesFor("Windows"),
            "services" to RemoteCommands.servicesFor("Windows"),
            "journal" to RemoteCommands.journal(os = "Windows"),
            "system specs" to SystemSpecsCommands.forOs("Windows"),
        ) + listOf("start", "stop", "restart", "enable", "disable", "status").associate {
            "service $it" to RemoteCommands.serviceAction(longName, it, os = "Windows")
        } + RemoteCommands.QuickCheck.entries.associate { "quick ${it.label}" to RemoteCommands.quickCheck(it, "Windows") }
        commands.forEach { (label, command) ->
            assertTrue("$label is ${command.length} characters", command.length <= RemoteCommands.WINDOWS_COMMAND_MAX)
            assertTrue(label, command.startsWith("powershell -NoProfile -NonInteractive -EncodedCommand "))
        }
    }
}
