package com.jetsetslow.omniterm

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Runs scripts in this machine's POSIX `sh`, for tests of the shell code OmniTerm sends to hosts.
 * One copy for every such test: each used to start its own process, wait and read its output.
 */
internal object TestShell {
    /** This machine's `sh`, or null where there is none: tests then skip themselves. */
    val sh: File? = find("sh")

    /** The first of [names] found as a program in the usual places, or null. */
    fun find(vararg names: String): File? = names.asSequence()
        .flatMap { name -> listOf("/bin", "/usr/bin", "/usr/local/bin").asSequence().map { File(it, name) } }
        .firstOrNull { it.canExecute() }

    data class Result(val output: String, val exit: Int)

    /**
     * Runs [script] with `[shell] [flags] -c`, writing [stdin] to it. The environment is the test's
     * own plus [env], or only [env] when [clean]. Output and errors are merged. A script that does
     * not read its input still runs; one still running after [timeoutSeconds] is killed and fails
     * the test.
     */
    fun run(
        script: String,
        stdin: String = "",
        env: Map<String, String> = emptyMap(),
        clean: Boolean = false,
        shell: File = requireNotNull(sh) { "no POSIX sh on this machine" },
        timeoutSeconds: Long = 30,
        flags: List<String> = emptyList(),
    ): Result {
        val process = ProcessBuilder(listOf(shell.absolutePath) + flags + listOf("-c", script))
            .redirectErrorStream(true)
            .apply {
                if (clean) environment().clear()
                environment().putAll(env)
            }
            .start()
        // Read while the script runs, so neither side waits on a full pipe and the timeout holds.
        var output = ""
        val reader = thread(isDaemon = true) { output = process.inputStream.bufferedReader(Charsets.UTF_8).readText() }
        try {
            process.outputStream.use { it.write(stdin.toByteArray(Charsets.UTF_8)) }
        } catch (_: IOException) {
            // The script finished, or closed its input, without reading it.
        }
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            reader.join(5_000)
            error("script did not finish in $timeoutSeconds s:\n$output")
        }
        // A background child can hold the output open after the script exits.
        reader.join(5_000)
        return Result(output, process.exitValue())
    }

    /** What `[shell] -n` says is wrong with [script]'s syntax, or null when it parses. */
    fun syntaxError(script: String, shell: File = requireNotNull(sh) { "no POSIX sh on this machine" }): String? =
        run(script, shell = shell, timeoutSeconds = 10, flags = listOf("-n")).takeIf { it.exit != 0 }?.output
}
