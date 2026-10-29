package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.HostTool
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The tool installs run as written against stand-in package managers: what each one is asked to
 * install, how it elevates, and what it says when it cannot. Nothing here reads the machine running
 * the test: PATH holds only the stand-ins and the few standard tools the script itself uses.
 */
class HostToolInstallTest {

    private class Run(val output: String, val exitCode: Int, val log: List<String>)

    private fun shell(): File? = listOf("/bin/sh", "/usr/bin/sh", "/bin/dash").map(::File).firstOrNull { it.canExecute() }

    private fun standardTool(name: String): File? =
        listOf("/usr/bin", "/bin").map { File(it, name) }.firstOrNull { it.canExecute() }

    /** Runs [script] with [fakes] (name → sh body) on PATH, feeding [stdin]. */
    private fun run(script: String, fakes: Map<String, String>, stdin: String? = null): Run {
        val sh = shell()
        val needed = listOf("awk", "sed", "head", "chmod", "timeout")
        assumeTrue("POSIX sh and ${needed.joinToString()} are required", sh != null && needed.all { standardTool(it) != null })
        val dir = Files.createTempDirectory("omniterm-tool-install").toFile()
        try {
            val bin = File(dir, "fakes").apply { mkdirs() }
            val tools = File(dir, "tools").apply { mkdirs() }
            needed.forEach { Files.createSymbolicLink(File(tools, it).toPath(), standardTool(it)!!.toPath()) }
            val log = File(dir, "log").apply { writeText("") }
            fakes.forEach { (name, body) -> File(bin, name).apply { writeText("#!${sh!!.absolutePath}\n$body\n"); setExecutable(true) } }
            val process = ProcessBuilder(sh!!.absolutePath, "-c", script).redirectErrorStream(true)
            process.environment().apply {
                clear()
                put("PATH", "${bin.absolutePath}:${tools.absolutePath}")
                put("FAKES", bin.absolutePath)
                put("LOG", log.absolutePath)
                put("STATE", dir.absolutePath)
            }
            val proc = process.start()
            proc.outputStream.use { out -> stdin?.let { out.write(it.toByteArray()) } }
            val output = proc.inputStream.bufferedReader().readText()
            val code = proc.waitFor()
            return Run(output, code, log.readLines().filter { it.isNotBlank() })
        } finally {
            dir.deleteRecursively()
        }
    }

    private val notRoot = "[ \"\$1\" = -u ] && echo 1000"

    // Logs how it was called, insists on an empty prompt, checks the password once as real sudo
    // does (then trusts the timestamp), and runs the command.
    private val sudo = """
        echo "sudo $*" >> "${'$'}LOG"
        mode=
        while [ ${'$'}# -gt 0 ]; do case ${'$'}1 in -S|-n) mode=${'$'}1; shift;; -p) [ -z "${'$'}2" ] || { echo "sudo: unexpected prompt" >&2; exit 1; }; shift 2;; *) break;; esac; done
        if [ ! -e "${'$'}STATE/sudo-ok" ]; then
          if [ "${'$'}mode" = -n ]; then echo "sudo: a password is required" >&2; exit 1; fi
          read -r pw || pw=
          [ "${'$'}pw" = fixture-sudo ] || { echo "sudo: incorrect password" >&2; exit 1; }
          : > "${'$'}STATE/sudo-ok"
        fi
        exec "$@"
    """.trimIndent()

    // Installing anything also puts nvidia-smi on PATH, as the real package does.
    private val aptGet = """
        echo "apt-get $*" >> "${'$'}LOG"
        if [ "${'$'}1" = install ]; then printf '#!/bin/sh\necho ok\n' > "${'$'}FAKES/nvidia-smi"; chmod +x "${'$'}FAKES/nvidia-smi"; fi
    """.trimIndent()

    private val ubuntuServerDriver = """
        printf 'ii nvidia-kernel-common-595-server 595.91.07-0ubuntu0.26.04.2\n'
        printf 'un nvidia-kernel-common-595-server-595.91.07 \n'
    """.trimIndent()

    @Test
    fun nvidiaSmiOnUbuntuComesFromTheLoadedDriversOwnBranchAndVersion() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = true),
            mapOf("id" to notRoot, "sudo" to sudo, "apt-get" to aptGet, "dpkg-query" to ubuntuServerDriver),
            stdin = "fixture-sudo\n",
        )
        assertEquals(run.output, 0, run.exitCode)
        assertTrue(run.output, run.output.trim().endsWith("nvidia-smi installed"))
        assertEquals(
            listOf(
                "sudo -S -p  apt-get update",
                "apt-get update",
                // nvidia-utils-595 (not -server) is a newer build; it would answer only
                // "Driver/library version mismatch" against this module.
                "sudo -S -p  apt-get install -y nvidia-utils-595-server=595.91.07-0ubuntu0.26.04.2",
                "apt-get install -y nvidia-utils-595-server=595.91.07-0ubuntu0.26.04.2",
            ),
            run.log,
        )
    }

    @Test
    fun debianWithoutUbuntusDriverPackagesInstallsItsOwnNvidiaSmi() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = true),
            mapOf("id" to notRoot, "sudo" to sudo, "apt-get" to aptGet, "dpkg-query" to "exit 1"),
            stdin = "fixture-sudo\n",
        )
        assertEquals(run.output, 0, run.exitCode)
        assertTrue(run.log.toString(), "apt-get install -y nvidia-smi" in run.log)
    }

    @Test
    fun withoutASavedPasswordSudoRefusesInsteadOfWaitingForOne() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = false),
            mapOf("id" to notRoot, "sudo" to sudo, "apt-get" to aptGet, "dpkg-query" to ubuntuServerDriver),
        )
        assertEquals(1, run.exitCode)
        assertTrue(run.output, run.output.contains("sudo: a password is required"))
        assertEquals(listOf("sudo -n -p  apt-get update"), run.log)
    }

    @Test
    fun asRootNothingGoesThroughSudo() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = true),
            mapOf("id" to "[ \"\$1\" = -u ] && echo 0", "sudo" to sudo, "apt-get" to aptGet, "dpkg-query" to ubuntuServerDriver),
        )
        assertEquals(run.output, 0, run.exitCode)
        assertFalse(run.log.toString(), run.log.any { it.startsWith("sudo") })
    }

    @Test
    fun aPackageManagerWithoutThePackageSaysSoAndInstallsNothing() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = true),
            mapOf("id" to notRoot, "sudo" to sudo, "apk" to "echo \"apk $*\" >> \"\$LOG\""),
            stdin = "fixture-sudo\n",
        )
        assertEquals(1, run.exitCode)
        assertTrue(run.output, run.output.contains("OmniTerm cannot install nvidia-smi with apk: it has no nvidia-smi package."))
        assertEquals(emptyList<String>(), run.log)
    }

    @Test
    fun aToolAlreadyThereIsLeftAlone() {
        val run = run(
            HostTool.NvidiaSmi.installCommand(withSudoPassword = true),
            mapOf("id" to notRoot, "sudo" to sudo, "apt-get" to aptGet, "nvidia-smi" to "echo ok"),
        )
        assertEquals(0, run.exitCode)
        assertEquals("nvidia-smi is already installed", run.output.trim())
        assertEquals(emptyList<String>(), run.log)
    }

    @Test
    fun theCheckAnswersOnlyOnceTheToolIsThere() {
        assertEquals("no", run(HostTool.NvidiaSmi.checkCommand(), emptyMap()).output.trim())
        assertEquals("yes", run(HostTool.NvidiaSmi.checkCommand(), mapOf("nvidia-smi" to "echo ok")).output.trim())
    }
}
