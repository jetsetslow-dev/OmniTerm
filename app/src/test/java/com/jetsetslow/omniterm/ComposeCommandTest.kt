package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Verifies the shell that compose actions/deploys generate is syntactically valid (so a quoting
 * bug can't ship as a runtime "command failed" surprise) and is podman-aware.
 */
class ComposeCommandTest {
    @Test fun updatePreservesPullOutputAndNamesEveryStage() {
        val command = RemoteCommands.dockerComposeAction("fixture", "/srv/fixture", "compose.yml", "update")
        assertTrue("pull output must not be discarded", !command.contains("pull --ignore-buildable 2>/dev/null"))
        for (stage in listOf("[1/4] Pulling images", "[2/4] Building images", "[3/4] Recreating services", "[4/4] Checking services")) {
            assertTrue("missing stage $stage", command.contains(stage))
        }
        assertTrue("non-fatal pull failure must be visible", command.contains("Warning:"))
        assertValidShell(command)
    }

    @Test fun replicaActionsQuoteOnlyTheObservedIdsWithoutCompose() {
        for (runtime in listOf("docker", "podman")) {
            for (action in listOf("start", "stop", "restart", "pause", "unpause", "remove")) {
                val verb = if (action == "remove") "rm -f" else action
                val command = RemoteCommands.dockerContainersAction(listOf("first", "second", "first"), action, runtime)
                org.junit.Assert.assertEquals("$runtime $verb 'first' 'second' 2>&1", command)
                assertValidShell(command)
            }
            val quoted = RemoteCommands.dockerContainersAction(listOf("a'; echo injected"), "stop", runtime)
            assertValidShell(quoted)
            assertTrue(quoted.contains(RemoteCommands.shellQuote("a'; echo injected")))
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyReplicaActionsAreRefused() {
        RemoteCommands.dockerContainersAction(emptyList(), "stop", "docker")
    }

    private fun assertValidShell(script: String) {
        // Skip silently if there's no bash on the build machine.
        val bash = TestShell.find("bash") ?: return
        val error = TestShell.syntaxError(script, bash)
        assertTrue("shell syntax error:\n$error\n--- script ---\n$script", error == null)
    }

    @Test
    fun deploy_command_is_valid_shell() {
        // Path with a space to prove quoting holds.
        val cmd = RemoteCommands.composeDeploy("/srv/my stack/docker-compose.yml", "my_stack")
        assertValidShell(cmd)
    }

    /**
     * The new file arrives on stdin, byte for byte, and nothing before the staging step reads it:
     * the fake `docker` swallows its stdin on every call, as a tool that reads it would.
     */
    @Test
    fun deploy_writes_exactly_what_arrives_on_stdin() {
        org.junit.Assume.assumeTrue(TestShell.sh != null)
        val dir = java.nio.file.Files.createTempDirectory("omniterm-deploy").toFile()
        try {
            val bin = File(dir, "bin").apply { mkdirs() }
            File(bin, "docker").apply {
                writeText("#!/bin/sh\ncat >/dev/null\necho \"docker \$*\" >> \"${dir.absolutePath}/calls\"\nexit 0\n")
                setExecutable(true)
            }
            val path = "${dir.absolutePath}/stack dir/compose.yml"
            val yaml = "services:\n  web:\n    image: \"nginx:1.27\" # it's ünïcode \$HOME `x` \\ %s\n"
            val output = TestShell.run(
                RemoteCommands.composeDeploy(path, "probe", runtime = "docker"),
                stdin = yaml,
                env = mapOf("PATH" to "${bin.absolutePath}:/usr/bin:/bin"),
            ).output
            assertTrue(output, output.contains("OMNITERM_DEPLOY_OK"))
            org.junit.Assert.assertEquals(yaml, File(path).readText())
            assertTrue(File(dir, "calls").readText().contains("up -d"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun deploy_resolves_runtime_and_validates_before_swap() {
        val path = "/srv/example/docker-compose.yml"
        val cmd = RemoteCommands.composeDeploy(path, "example_stack")
        assertTrue("resolves usable docker|podman", cmd.contains("docker ps") && cmd.contains("podman ps"))
        assertTrue("falls back to standalone compose", cmd.contains("docker-compose") && cmd.contains("podman-compose"))
        assertTrue("prefers podman-compose when Podman is the usable runtime", cmd.indexOf("grep -qi podman") < cmd.indexOf("docker-compose"))
        assertTrue("validates with config before swapping", cmd.contains("config > /dev/null"))
        assertTrue("backs up the live file", cmd.contains(".omniterm.bak"))
        assertTrue("restores on failure", cmd.contains("restoring previous compose file"))
        assertTrue("emits success sentinel", cmd.contains("OMNITERM_DEPLOY_OK"))
        // Operates on the EXACT absolute file via -f, never a guessed relative name.
        assertTrue("uses mktemp staging", cmd.contains("mktemp"))
        assertTrue("stages the file from stdin", cmd.contains("cat > \"\$tmp\"") && !cmd.contains("base64"))
        assertTrue("resolving the runtime reads no stdin", cmd.startsWith("{ ") && cmd.contains("; } </dev/null"))
        assertTrue("uses -f with the absolute compose path", cmd.contains("-f '$path'"))
        assertTrue("up runs against the same -f path", cmd.contains("-f '$path' -p 'example_stack' up -d"))
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
            workingDir = "/srv/app",
            configFiles = "compose.yml,compose.override.yml",
        )
        assertTrue("base file kept in validation", cmd.contains("-f '/srv/app/compose.yml' -f \"\$tmp\" -p 'app' config > /dev/null"))
        assertTrue("base file kept in deploy", cmd.contains("-f '/srv/app/compose.yml' -f '/srv/app/compose.override.yml' -p 'app' up -d"))
        assertValidShell(cmd)
    }

    /**
     * A podman-compose host: `up` creates every container of the stack each time, reports those
     * that already exist as "already in use", starts them anyway and exits 125, as 1.4 does. With
     * [scales] false it ignores `--scale`, as every release before 1.4 does. Containers live in a
     * file as `name service number project`; a fake `podman` reads and removes them.
     */
    private class PodmanComposeHost(private val scales: Boolean = true) : AutoCloseable {
        val dir: File = java.nio.file.Files.createTempDirectory("omniterm-podman-compose").toFile()
        private val bin = File(dir, "bin").apply { mkdirs() }
        val state = File(dir, "containers").apply { writeText("") }

        init {
            val d = dir.absolutePath
            script(
                "podman-compose",
                """
                echo "podman-compose ${'$'}*" >> "$d/calls"
                case " ${'$'}* " in
                *" down --help "*) echo "  --remove-orphans  Remove containers for services not defined"; exit 0 ;;
                *" config --services "*) echo w; exit 0 ;;
                *" up "*)
                  n=1; ${if (scales) "for a; do case ${'$'}a in w=*) n=${'$'}{a#w=} ;; esac; done" else ":"}
                  rc=0; i=1
                  while [ "${'$'}i" -le "${'$'}n" ]; do
                    if grep -q "^p_w_${'$'}i " "$d/containers"; then
                      echo "Error: creating container storage: the container name \"p_w_${'$'}i\" is already in use by abc${'$'}i. You have to remove that container to be able to reuse that name: that name is already in use" >&2
                      rc=125
                    else echo "p_w_${'$'}i w ${'$'}i p" >> "$d/containers"; fi
                    echo "p_w_${'$'}i"; i=${'$'}((i + 1))
                  done
                  exit ${'$'}rc ;;
                esac
                """,
            )
            script(
                "podman",
                """
                echo "podman ${'$'}*" >> "$d/calls"
                case "${'$'}1" in
                inspect) for n; do :; done; awk -v n="${'$'}n" '${'$'}1 == n { print ${'$'}4 }' "$d/containers" ;;
                rm) shift; [ "${'$'}1" = -f ] && shift
                  for n; do grep -v "^${'$'}n " "$d/containers" > "$d/next"; mv "$d/next" "$d/containers"; echo "${'$'}n"; done ;;
                ps) shift; proj=; svc=; quiet=0; fmt=
                  while [ ${'$'}# -gt 0 ]; do
                    case ${'$'}1 in
                    -aq) quiet=1 ;;
                    --filter) shift; case ${'$'}1 in
                      label=io.podman.compose.project=*) proj=${'$'}{1#label=io.podman.compose.project=} ;;
                      label=com.docker.compose.service=*) svc=${'$'}{1#label=com.docker.compose.service=} ;; esac ;;
                    --format) shift; fmt=${'$'}1 ;;
                    esac; shift
                  done
                  awk -v p="${'$'}proj" -v s="${'$'}svc" -v q="${'$'}quiet" -v f="${'$'}fmt" '${'$'}4 == p && (s == "" || ${'$'}2 == s) {
                    if (q == 1) print ${'$'}1; else if (f ~ /container-number/) print ${'$'}1, ${'$'}3; else print ${'$'}1, ${'$'}2 }' "$d/containers" ;;
                esac
                """,
            )
        }

        private fun script(name: String, body: String) =
            File(bin, name).apply { writeText("#!/bin/sh\n" + body.trimIndent() + "\n"); setExecutable(true) }

        fun names(): List<String> = state.readLines().filter { it.isNotBlank() }.map { it.substringBefore(' ') }.sorted()

        fun calls(): String = File(dir, "calls").takeIf { it.exists() }?.readText().orEmpty()

        /** Runs [action] for project `p`, service `w`, as the host's sh would; output and exit code. */
        fun run(action: String, replicas: Int? = null): Pair<String, Int> {
            val command = RemoteCommands.dockerComposeAction("p", dir.absolutePath, "compose.yml", action, "w", replicas, runtime = "podman")
            return TestShell.run(command, env = path).let { it.output to it.exit }
        }

        /** Deploys [yaml] as project `p` through the builder's deploy script; output and exit code. */
        fun deploy(yaml: String, removeOrphans: Boolean): Pair<String, Int> {
            val command = RemoteCommands.composeDeploy("${dir.absolutePath}/compose.yml", "p", runtime = "podman", removeOrphans = removeOrphans)
            return TestShell.run(command, stdin = yaml, env = path).let { it.output to it.exit }
        }

        private val path get() = mapOf("PATH" to "${bin.absolutePath}:/usr/bin:/bin")

        override fun close() { dir.deleteRecursively() }
    }

    /**
     * A deploy that drops a service removes its container. Compose otherwise leaves it running as
     * an orphan, and podman-compose ignores --remove-orphans, so the app removes those itself.
     */
    @Test
    fun deploy_that_drops_a_service_removes_its_container() {
        val docker = RemoteCommands.composeDeploy("/srv/app/compose.yml", "app", removeOrphans = true)
        assertTrue(docker, docker.contains("-p 'app' up -d --remove-orphans"))
        assertValidShell(docker)
        assertTrue(!RemoteCommands.composeDeploy("/srv/app/compose.yml", "app").contains("--remove-orphans"))

        org.junit.Assume.assumeTrue(File("/bin/sh").canExecute())
        PodmanComposeHost().use { host ->
            host.state.writeText("p_old_1 old 1 p\nq_old_1 old 1 q\n")
            val (output, code) = host.deploy("services:\n  w:\n    image: alpine\n", removeOrphans = true)
            assertEquals(output, 0, code)
            assertTrue(output, output.contains("Removed p_old_1") && output.contains("OMNITERM_DEPLOY_OK"))
            assertEquals(listOf("p_w_1", "q_old_1"), host.names())
        }
    }

    @Test
    fun podman_compose_up_on_a_running_stack_succeeds() {
        org.junit.Assume.assumeTrue(File("/bin/sh").canExecute())
        PodmanComposeHost().use { host ->
            assertEquals(0, host.run("up").second)
            val (output, code) = host.run("up")
            assertEquals(output, 0, code)
            assertTrue(output, output.contains("p_w_1") && !output.contains("already in use"))

            host.state.writeText("p_w_1 w 1 someone-else\n")
            val (foreign, foreignCode) = host.run("up")
            assertEquals("a container another project owns is a real conflict", 125, foreignCode)
            assertTrue(foreign, foreign.contains("already in use"))
        }
    }

    @Test
    fun podman_compose_scales_both_ways_and_removes_only_its_own_containers() {
        org.junit.Assume.assumeTrue(File("/bin/sh").canExecute())
        PodmanComposeHost().use { host ->
            host.state.writeText("p_old_1 old 1 p\nq_w_2 w 2 q\n")
            assertEquals(0, host.run("up").second)
            val (up, upCode) = host.run("scale", 3)
            assertEquals(up, 0, upCode)
            assertEquals(listOf("p_old_1", "p_w_1", "p_w_2", "p_w_3", "q_w_2"), host.names())

            val (down, downCode) = host.run("scale", 1)
            assertEquals(down, 0, downCode)
            assertTrue(down, down.contains("Removed p_w_3") && down.contains("Removed p_w_2"))
            assertEquals(listOf("p_old_1", "p_w_1", "q_w_2"), host.names())

            assertEquals(0, host.run("removeOrphans").second)
            assertEquals(listOf("p_w_1", "q_w_2"), host.names())

            assertEquals(0, host.run("serviceRemove").second)
            assertEquals(listOf("q_w_2"), host.names())

            host.run("down")
            assertTrue(host.calls(), host.calls().contains("down --remove-orphans"))
        }
    }

    @Test
    fun podman_compose_that_cannot_scale_says_so() {
        org.junit.Assume.assumeTrue(File("/bin/sh").canExecute())
        PodmanComposeHost(scales = false).use { host ->
            val (output, code) = host.run("scale", 2)
            assertTrue(output, code != 0)
            assertTrue(output, output.contains("podman-compose made 1 of 2 containers for w. Scaling a service needs podman-compose 1.4 or later."))
        }
    }

    @Test
    fun podman_compose_update_recreates_with_the_pulled_images() {
        val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "compose.yml", "update", runtime = "podman")
        assertTrue(cmd, cmd.contains("up -d --force-recreate --remove-orphans"))
        assertValidShell(cmd)
    }

    @Test
    fun stack_actions_are_podman_aware_and_valid() {
        for (action in listOf("up", "down", "restart", "pull", "logs", "config", "ps", "update", "build")) {
            val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "docker-compose.yml", action)
            assertTrue("$action resolves compose runtime", cmd.contains("docker ps") && cmd.contains("podman ps"))
            assertValidShell(cmd)
        }
    }

    @Test
    fun update_builds_dockerfile_images_and_tolerates_pull_failures() {
        val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "docker-compose.yml", "update")
        // Build step is present so Dockerfile-based (build:) services are (re)built rather than
        // pulled from a registry, which is what caused the login error.
        assertTrue("update builds images", cmd.contains("build --pull"))
        // A pull failure (e.g. private-registry login) must not abort the build + recreate.
        assertTrue("pull is non-fatal", cmd.contains("--ignore-buildable") || cmd.contains("|| true"))
        assertTrue("update recreates containers", cmd.contains("up -d"))
        assertValidShell(cmd)
    }

    @Test
    fun build_action_only_builds_without_recreating() {
        val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "docker-compose.yml", "build")
        assertTrue("build action builds with --pull", cmd.contains("build --pull"))
        assertTrue("build action does not recreate", !cmd.contains("up -d"))
        assertValidShell(cmd)
    }

    @Test
    fun docker_volumes_command_is_valid_shell() {
        assertValidShell(RemoteCommands.DOCKER_VOLUMES)
    }

    @Test
    fun docker_ps_uses_runtime_correct_compose_label_placeholders() {
        // Docker exposes labels via the `.Label "key"` method; Podman's psReporter has no such
        // method and exposes `.Labels` as an indexable map. Each branch must use its own syntax,
        // or `podman ps` fails with `can't evaluate field Label in type containers.psReporter`.
        assertTrue(
            "docker branch uses the .Label method",
            RemoteCommands.DOCKER_PS.contains("""{{.Label "com.docker.compose.project"}}"""),
        )
        assertTrue(
            "podman branch indexes the .Labels map",
            RemoteCommands.DOCKER_PS.contains("""{{index .Labels "com.docker.compose.project"}}"""),
        )
        assertTrue("branches on the podman runtime", RemoteCommands.DOCKER_PS.contains("grep -qi podman"))
        assertValidShell(RemoteCommands.DOCKER_PS)
    }

    @Test
    fun docker_restarts_uses_runtime_correct_id_placeholder() {
        // Docker's inspect template field is `.Id`; Podman's is `.ID` (its `.Id` errors with
        // `can't evaluate field Id`). Both expose `.RestartCount`.
        assertTrue("docker branch uses .Id", RemoteCommands.DOCKER_RESTARTS.contains("docker\\t{{.Id}}\\t{{.RestartCount}}"))
        assertTrue("podman branch uses .ID", RemoteCommands.DOCKER_RESTARTS.contains("podman\\t{{.ID}}\\t{{.RestartCount}}"))
        assertValidShell(RemoteCommands.DOCKER_RESTARTS)
    }

    @Test
    fun compose_actions_can_pin_docker_or_podman_runtime() {
        val docker = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "compose.yml", "ps", runtime = "docker")
        val podman = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "compose.yml", "ps", runtime = "podman")
        assertTrue(docker.contains("OT_CR=docker"))
        assertTrue(docker.contains("docker compose"))
        assertTrue(podman.contains("OT_CR=podman"))
        assertTrue(podman.contains("podman-compose"))
        assertValidShell(docker)
        assertValidShell(podman)
    }

    @Test
    fun pinned_podman_compose_never_falls_back_to_docker_compose() {
        val cmd = RemoteCommands.dockerComposeAction("proj", "/srv/proj", "compose.yml", "up", runtime = "podman")
        assertTrue("pinned Podman uses Podman's compose wrapper when available", cmd.contains("podman compose"))
        assertTrue("pinned Podman may use the Podman provider", cmd.contains("podman-compose"))
        assertTrue(
            "native podman-compose must win over podman compose's potentially Docker-backed dispatcher",
            cmd.indexOf("command -v podman-compose") < cmd.indexOf("podman compose version"),
        )
        assertTrue("pinned Podman must not silently deploy with Docker Compose", !cmd.contains("docker-compose"))
        assertValidShell(cmd)
    }

    @Test
    fun container_resource_actions_can_pin_runtime() {
        assertTrue(RemoteCommands.dockerAction("abc", "stop", runtime = "podman").startsWith("podman stop"))
        assertTrue(RemoteCommands.dockerImageAction("abc", "remove", runtime = "podman").startsWith("podman rmi -f"))
        assertTrue(RemoteCommands.dockerVolumeAction("data", "remove", runtime = "podman").startsWith("podman volume rm -f"))
        assertTrue(RemoteCommands.dockerNetworkAction("net", "remove", runtime = "podman").startsWith("podman network rm"))
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
        // As the shell hands it over: inside single quotes nothing changes, so no unescaping here.
        // Rewriting `\$` to `$` once hid that awk was really given `\$1`, which no awk parses.
        val program = RemoteCommands.DOCKER_VOLUMES
            .substringAfter("awk '").substringBefore("' ||")

        val p = ProcessBuilder(awk, program).redirectErrorStream(false).start()
        p.outputStream.bufferedWriter().use { it.write(sample) }
        val tsv = p.inputStream.bufferedReader().readText().lineSequence().filter { it.isNotEmpty() }
            .joinToString("\n") { "podman\t$it" }
        assertTrue("awk accepted the program", p.waitFor() == 0)

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
