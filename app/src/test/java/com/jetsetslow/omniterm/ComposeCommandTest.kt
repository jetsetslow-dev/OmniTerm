package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Verifies the shell that compose actions/deploys generate is syntactically valid (so a quoting
 * bug can't ship as a runtime "command failed" surprise) and is podman-aware.
 */
class ComposeCommandTest {

    private fun assertValidShell(script: String) {
        // Skip silently if there's no bash on the build machine.
        val bash = listOf("/bin/bash", "/usr/bin/bash").firstOrNull { File(it).exists() } ?: return
        val p = ProcessBuilder(bash, "-n").redirectErrorStream(true).start()
        p.outputStream.bufferedWriter().use { it.write(script) }
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        assertTrue("shell syntax error:\n$out\n--- script ---\n$script", code == 0)
    }

    @Test
    fun deploy_command_is_valid_shell() {
        val b64 = java.util.Base64.getEncoder().encodeToString("version: \"3.8\"\n".toByteArray())
        // Path with a space to prove quoting holds.
        val cmd = RemoteCommands.composeDeploy("/srv/my stack/docker-compose.yml", "my_stack", b64)
        assertValidShell(cmd)
    }

    @Test
    fun deploy_resolves_runtime_and_validates_before_swap() {
        val path = "/home/ubuntu/core/docker-compose.yml"
        val cmd = RemoteCommands.composeDeploy(path, "core_utilities", "eA==")
        assertTrue("resolves usable docker|podman", cmd.contains("docker ps") && cmd.contains("podman ps"))
        assertTrue("falls back to standalone compose", cmd.contains("docker-compose") && cmd.contains("podman-compose"))
        assertTrue("validates with config before swapping", cmd.contains("config > /dev/null"))
        assertTrue("backs up the live file", cmd.contains(".omniterm.bak"))
        assertTrue("restores on failure", cmd.contains("restoring previous compose file"))
        assertTrue("emits success sentinel", cmd.contains("OMNITERM_DEPLOY_OK"))
        // Operates on the EXACT absolute file via -f, never a guessed relative name.
        assertTrue("uses mktemp staging", cmd.contains("mktemp"))
        assertTrue("uses portable base64 decode", cmd.contains("base64 -d") && cmd.contains("base64 --decode") && cmd.contains("base64 -D"))
        assertTrue("uses -f with the absolute compose path", cmd.contains("-f '$path'"))
        assertTrue("up runs against the same -f path", cmd.contains("-f '$path' -p 'core_utilities' up -d"))
        assertTrue("removes failed new stack file", cmd.contains("removing new compose file"))
        // The new file is staged to a temp and only moved in AFTER validation.
        val stageIdx = cmd.indexOf("mktemp")
        val validateIdx = cmd.indexOf("config > /dev/null")
        val moveIdx = cmd.indexOf("mv \"\$tmp\" '$path'")
        assertTrue(stageIdx in 0 until validateIdx)
        assertTrue(validateIdx in 0 until moveIdx)
    }

    @Test
    fun deploy_preserves_multifile_compose_chain() {
        val cmd = RemoteCommands.composeDeploy(
            composeFilePath = "/srv/app/compose.override.yml",
            project = "app",
            yamlBase64 = "eA==",
            workingDir = "/srv/app",
            configFiles = "compose.yml,compose.override.yml",
        )
        assertTrue("base file kept in validation", cmd.contains("-f '/srv/app/compose.yml' -f \"\$tmp\" -p 'app' config > /dev/null"))
        assertTrue("base file kept in deploy", cmd.contains("-f '/srv/app/compose.yml' -f '/srv/app/compose.override.yml' -p 'app' up -d"))
        assertValidShell(cmd)
    }

    @Test
    fun stack_actions_are_podman_aware_and_valid() {
        for (action in listOf("up", "down", "restart", "pull", "logs", "config", "ps", "update")) {
            val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "docker-compose.yml", action)
            assertTrue("$action resolves compose runtime", cmd.contains("docker ps") && cmd.contains("podman ps"))
            assertValidShell(cmd)
        }
    }

    @Test
    fun docker_volumes_command_is_valid_shell() {
        assertValidShell(RemoteCommands.DOCKER_VOLUMES)
    }

    @Test
    fun docker_ps_uses_portable_compose_label_placeholders() {
        assertTrue(RemoteCommands.DOCKER_PS.contains("""{{.Label "com.docker.compose.project"}}"""))
        assertTrue(!RemoteCommands.DOCKER_PS.contains("index .Labels"))
        assertValidShell(RemoteCommands.DOCKER_PS)
    }

    @Test
    fun volume_prune_prunes_named_unused_volumes_on_docker_and_podman() {
        val cmd = RemoteCommands.dockerPruneVolumes()
        assertTrue(cmd.contains("volume prune -a -f"))
        assertValidShell(cmd)
    }

    @Test
    fun service_actions_support_systemd_and_openrc() {
        val restart = RemoteCommands.serviceAction("nginx", "restart")
        assertTrue(restart.contains("systemctl restart"))
        assertTrue(restart.contains("rc-service"))
        assertTrue(restart.contains("restart"))
        assertValidShell(restart)

        val enable = RemoteCommands.serviceAction("nginx", "enable")
        assertTrue(enable.contains("systemctl enable"))
        assertTrue(enable.contains("rc-update add"))
        assertTrue(enable.contains("default"))
        assertValidShell(enable)

        val disable = RemoteCommands.serviceAction("nginx", "disable")
        assertTrue(disable.contains("systemctl disable"))
        assertTrue(disable.contains("rc-update delete"))
        assertTrue(disable.contains("-a"))
        assertValidShell(disable)
    }

    /**
     * Runs the Podman text-fallback `awk` from DOCKER_VOLUMES against a realistic
     * `podman system df -v` capture, then feeds the result through the real parser. This pins both
     * the awk state machine (blank line between heading and column header must NOT end the section)
     * and the name/links/size column mapping.
     */
    @Test
    fun podman_volume_awk_feeds_parser_correctly() {
        val awk = listOf("/usr/bin/awk", "/bin/awk").firstOrNull { File(it).exists() } ?: return
        val sample = """
            Images space usage:

            REPOSITORY  TAG     IMAGE ID      CREATED     SIZE   SHARED SIZE  UNIQUE SIZE  CONTAINERS
            nginx       latest  abc123def456  2 days ago  187MB  0B           187MB        1

            Local Volumes space usage:

            VOLUME NAME  LINKS       SIZE
            pgdata       2           1.234GB
            cache_vol    0           0B
            media        1           512.5MB

        """.trimIndent()

        // The exact awk program embedded in DOCKER_VOLUMES (the part between `awk '` and `'`).
        val program = RemoteCommands.DOCKER_VOLUMES
            .substringAfter("awk '").substringBefore("' ||")
            .replace("\\\$", "\$").replace("\\t", "\t").replace("\\\"", "\"")

        val p = ProcessBuilder(awk, program).redirectErrorStream(false).start()
        p.outputStream.bufferedWriter().use { it.write(sample) }
        val tsv = p.inputStream.bufferedReader().readText()
        p.waitFor()

        val vols = com.jetsetslow.omniterm.data.RemoteParsers.parseDockerVolumes(tsv)
        assertTrue("parsed 3 volumes (got ${vols.size}): $tsv", vols.size == 3)
        val pg = vols.first { it.name == "pgdata" }
        assertTrue(pg.size == "1.234GB")
        assertTrue("pgdata has 2 links so in-use", pg.inUse)
        val cache = vols.first { it.name == "cache_vol" }
        assertTrue("cache_vol has 0 links so unused", !cache.inUse)
        assertTrue(vols.any { it.name == "media" && it.size == "512.5MB" })
    }
}
