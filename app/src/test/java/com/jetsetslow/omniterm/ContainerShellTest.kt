package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ContainerShellTest {
    @get:Rule val temp = TemporaryFolder()

    private fun shell(): File? = listOf("/bin/sh", "/usr/bin/sh").map(::File).firstOrNull { it.canExecute() }

    @Test
    fun theContainerShellFallsBackToShWhereThereIsNoBash() {
        assumeTrue("POSIX sh is required to run the shell fallback", shell() != null)
        val bin = temp.newFolder()
        // A PATH with sh and nothing else, as in an Alpine image.
        File(bin, "sh").apply {
            writeText("#!${shell()!!.absolutePath}\necho fell-back-to-sh\n")
            setExecutable(true)
        }
        assertThat(RemoteCommands.CONTAINER_SHELL).isEqualTo("sh -c '${RemoteCommands.CONTAINER_SHELL_SCRIPT}'")
        val inner = RemoteCommands.CONTAINER_SHELL_SCRIPT
        val process = ProcessBuilder(shell()!!.absolutePath, "-c", inner).redirectErrorStream(true).apply {
            environment().clear()
            environment()["PATH"] = bin.absolutePath
        }.start()
        assertThat(process.inputStream.bufferedReader().readText().trim()).isEqualTo("fell-back-to-sh")
        assertThat(process.waitFor()).isEqualTo(0)
    }
}
