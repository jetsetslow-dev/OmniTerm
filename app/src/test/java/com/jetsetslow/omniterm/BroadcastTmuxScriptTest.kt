package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/**
 * Runs Fleet broadcast's "Run in tmux" scripts in a real POSIX shell, with a stand-in `tmux` on
 * PATH that runs each new session's command in the background, and a temporary HOME. Nothing here
 * depends on the machine having tmux: the stand-in comes first on PATH.
 */
class BroadcastTmuxScriptTest {

    private lateinit var home: File
    private lateinit var bin: File

    @Before
    fun setUp() {
        assumeTrue("POSIX sh is required", File("/bin/sh").canExecute())
        home = Files.createTempDirectory("omniterm-bc-home").toFile()
        bin = File(home, "stub-bin").apply { mkdirs() }
        File(bin, "tmux").apply {
            writeText(
                """
                #!/bin/sh
                S="${'$'}HOME/stub-sessions"
                case "${'$'}1" in
                  new-session)
                    name=${'$'}4; cmd=${'$'}5
                    echo "${'$'}name" >> "${'$'}S"
                    ( sh -c "${'$'}cmd" ) >/dev/null 2>&1 &
                    ;;
                  list-sessions) cat "${'$'}S" 2>/dev/null ;;
                  kill-session)
                    grep -vxF "${'$'}3" "${'$'}S" > "${'$'}S.tmp" 2>/dev/null; mv "${'$'}S.tmp" "${'$'}S"
                    ;;
                esac
                exit 0
                """.trimIndent() + "\n",
            )
            setExecutable(true)
        }
    }

    @After
    fun tearDown() {
        if (::home.isInitialized) home.deleteRecursively()
    }

    private data class Run(val output: String, val exit: Int)

    private fun sh(script: String, stdin: String = ""): Run {
        val proc = ProcessBuilder("/bin/sh", "-c", script)
            .redirectErrorStream(true)
            .apply {
                environment()["HOME"] = home.absolutePath
                environment()["PATH"] = bin.absolutePath + ":" + System.getenv("PATH")
                environment()["SHELL"] = "/bin/sh"
            }
            .start()
        proc.outputStream.use { it.write(stdin.toByteArray()) }
        val output = proc.inputStream.bufferedReader().readText()
        check(proc.waitFor(30, TimeUnit.SECONDS)) { "script did not finish" }
        return Run(output, proc.exitValue())
    }

    private fun runFiles(runId: String) = File(home, ".cache/omniterm").listFiles().orEmpty()
        .filter { it.name.startsWith("broadcast-$runId") }

    private fun awaitFile(file: File) {
        val deadline = System.currentTimeMillis() + 10_000
        while (!file.exists()) {
            check(System.currentTimeMillis() < deadline) { "$file never appeared" }
            Thread.sleep(50)
        }
    }

    @Test
    fun aRunStreamsItsOutputExitsWithItsStatusAndLeavesNothingBehind() {
        val runId = "abc123"
        val started = sh(
            RemoteCommands.broadcastTmuxStart(runId),
            RemoteCommands.broadcastTmuxRunner(runId, "echo one; echo 'two it''s' >&2; exit 3"),
        )
        assertTrue(started.output, RemoteCommands.broadcastTmuxStarted(started.output))
        awaitFile(File(home, ".cache/omniterm/broadcast-$runId.exit"))

        val followed = sh(RemoteCommands.broadcastTmuxFollow(runId))
        assertEquals("one\ntwo its\n", followed.output)
        assertEquals("the follow exits with the command's own status", 3, followed.exit)
        assertFalse("the session closed with its command", File(home, "stub-sessions").readText().contains(runId))

        sh(RemoteCommands.broadcastTmuxCleanup(runId))
        assertEquals(emptyList<File>(), runFiles(runId))
    }

    @Test
    fun followingWhileTheCommandRunsGetsEveryLine() {
        val runId = "live42"
        sh(
            RemoteCommands.broadcastTmuxStart(runId),
            RemoteCommands.broadcastTmuxRunner(runId, "for i in 1 2 3; do echo line ${'$'}i; sleep 1; done"),
        )
        val followed = sh(RemoteCommands.broadcastTmuxFollow(runId))
        assertEquals("line 1\nline 2\nline 3\n", followed.output)
        assertEquals(0, followed.exit)
    }

    @Test
    fun aSessionThatEndedWithoutFinishingSaysSo() {
        val runId = "gone77"
        sh(RemoteCommands.broadcastTmuxStart(runId), RemoteCommands.broadcastTmuxRunner(runId, "sleep 5"))
        // As if the host restarted: the session is gone and the command never reported a status.
        File(home, "stub-sessions").writeText("")
        val followed = sh(RemoteCommands.broadcastTmuxFollow(runId))
        assertTrue(followed.output, followed.output.trimEnd().endsWith(RemoteCommands.BROADCAST_TMUX_GONE))
        assertEquals(0, followed.exit)
    }

    @Test
    fun stopEndsTheSessionAndRemovesTheFiles() {
        val runId = "stop99"
        sh(RemoteCommands.broadcastTmuxStart(runId), RemoteCommands.broadcastTmuxRunner(runId, "sleep 2"))
        sh(RemoteCommands.broadcastTmuxStop(runId))
        assertFalse(File(home, "stub-sessions").readText().contains(runId))
        assertFalse(File(home, ".cache/omniterm/broadcast-$runId.log").exists())
    }

    @Test
    fun filesARunNeverCameBackForGoAfterADay() {
        val dir = File(home, ".cache/omniterm").apply { mkdirs() }
        val stale = File(dir, "broadcast-old.log").apply {
            writeText("old")
            setLastModified(System.currentTimeMillis() - 2 * 24 * 3_600_000L)
        }
        sh(RemoteCommands.broadcastTmuxStart("new1"), RemoteCommands.broadcastTmuxRunner("new1", "true"))
        assertFalse(stale.exists())
    }
}
