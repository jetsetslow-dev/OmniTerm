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

    @Test
    fun theContainerShellFallsBackToShWhereThereIsNoBash() {
        val sh = TestShell.sh
        assumeTrue("POSIX sh is required to run the shell fallback", sh != null)
        val bin = temp.newFolder()
        // A PATH with sh and nothing else, as in an Alpine image.
        File(bin, "sh").apply {
            writeText("#!${sh!!.absolutePath}\necho fell-back-to-sh\n")
            setExecutable(true)
        }
        assertThat(RemoteCommands.CONTAINER_SHELL).isEqualTo("sh -c '${RemoteCommands.CONTAINER_SHELL_SCRIPT}'")
        val run = TestShell.run(RemoteCommands.CONTAINER_SHELL_SCRIPT, env = mapOf("PATH" to bin.absolutePath), clean = true)
        assertThat(run.output.trim()).isEqualTo("fell-back-to-sh")
        assertThat(run.exit).isEqualTo(0)
    }
}
