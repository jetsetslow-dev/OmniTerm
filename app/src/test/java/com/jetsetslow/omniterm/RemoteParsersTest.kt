package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic tests for the SSH output parsers, using captured sample command output. */
class RemoteParsersTest {

    @Test
    fun parsesPsOutput() {
        // Columns: pid user %cpu %mem vsz etime stat comm
        val out = """
            1234 root      2.5  1.2 123456 01:02:03 S    nginx
            5678 deploy   10.0  4.0 654321 10-00:00 Rl   node
        """.trimIndent()
        val procs = RemoteParsers.parseProcesses(out)
        assertEquals(2, procs.size)
        assertEquals(1234, procs[0].pid)
        assertEquals("root", procs[0].owner)
        assertEquals(2.5f, procs[0].cpu, 0.001f)
        assertEquals("01:02:03", procs[0].uptime)
        assertEquals("nginx", procs[0].name)
        assertEquals("R", procs[1].state) // first char of "Rl"
    }

    @Test
    fun parsesSystemctlServices() {
        val out = """
            ssh.service     loaded active running OpenBSD Secure Shell server
            cron.service    loaded active running Regular background program processing daemon
            broke.service   loaded failed failed  A broken unit
        """.trimIndent()
        val svcs = RemoteParsers.parseServices(out)
        assertEquals(3, svcs.size)
        assertEquals("ssh", svcs[0].name)
        assertEquals("running", svcs[0].status)
        assertEquals("active", svcs[0].subState)
        assertEquals("failed", svcs[2].status)
        assertEquals("failed", svcs[2].subState)
    }

    @Test
    fun parsesJournalWithLevelInference() {
        val out = """
            2026-05-30T10:41:22+0000 host sshd[123]: Accepted publickey for deploy
            2026-05-30T10:42:00+0000 host nginx[9]: connect() failed (111: Connection refused)
        """.trimIndent()
        val logs = RemoteParsers.parseJournal(out)
        assertEquals(2, logs.size)
        assertEquals("10:41:22", logs[0].time)
        assertEquals("sshd", logs[0].source)
        assertEquals("INFO", logs[0].level)
        assertEquals("nginx", logs[1].source)
        assertEquals("ERROR", logs[1].level)
    }

    @Test
    fun parsesRuntimeList() {
        assertEquals(setOf("docker", "podman"), RemoteParsers.parseRuntimeList("docker\npodman\n"))
        assertEquals(setOf("podman"), RemoteParsers.parseRuntimeList("  podman  \n"))
        assertEquals(emptySet<String>(), RemoteParsers.parseRuntimeList(""))
        // Noise (motd banners, errors) must not register as a runtime.
        assertEquals(setOf("docker"), RemoteParsers.parseRuntimeList("Welcome to host\ndocker\nbash: podman: command not found"))
    }

    @Test
    fun parsesDockerPs() {
        val out =
            "podman\tabc123\tweb\tnginx:1.25\tUp 3 hours (healthy)\t80/tcp\tmyproj\tweb\t/opt/app\tcompose.yml\t2026-05-01 00:00:00 +0000 UTC\n" +
            "docker\tdef456\tdb\tpostgres:16\tExited (0) 2 hours ago\t\t\t\t\t\t2026-05-02 00:00:00 +0000 UTC"
        val containers = RemoteParsers.parseDockerPs(out)
        assertEquals(2, containers.size)
        assertEquals("web", containers[0].name)
        assertEquals("podman", containers[0].runtime)
        assertEquals("running", containers[0].status)
        assertEquals("myproj", containers[0].group)
        assertEquals("web", containers[0].composeService)
        assertEquals("healthy", containers[0].health)
        assertEquals("exited", containers[1].status)
        assertEquals("docker", containers[1].runtime)
        assertEquals("standalone", containers[1].group)
    }

    @Test
    fun parsesDockerComposeLabels() {
        val out = "abc123\tweb\tnginx:1.25\tUp 3 hours\t80/tcp\tmyproj\tweb\t/opt/app\tcompose.yml,compose.prod.yml\t2026-05-01 00:00:00 +0000 UTC"
        val container = RemoteParsers.parseDockerPs(out).single()
        assertEquals("myproj", container.group)
        assertEquals("web", container.composeService)
        assertEquals("/opt/app", container.composeWorkingDir)
        assertEquals("compose.yml,compose.prod.yml", container.composeConfigFiles)
    }

    @Test
    fun parsesDockerRestartCounts() {
        val counts = RemoteParsers.parseDockerRestartCounts("podman\tabc1234567890\t2\nabc1234567890\t2\ndef4567890000\t0")
        assertEquals(2, counts["podman:abc123456789"])
        assertEquals(2, counts["abc123456789"])
        assertEquals(0, counts["def456789000"])
    }

    @Test
    fun parsesContainerResourcesWithRuntimePrefixes() {
        val images = RemoteParsers.parseDockerImages("podman\tsha256:abc1234567890\tnginx\tlatest\t187MB\t2 days ago")
        assertEquals("podman", images.single().runtime)
        val volumes = RemoteParsers.parseDockerVolumes("podman\tpgdata\tlocal\t/var/lib/containers/storage/volumes/pgdata\t1GB\t1")
        assertEquals("podman", volumes.single().runtime)
        assertTrue(volumes.single().inUse)
        val networks = RemoteParsers.parseDockerNetworks("podman\tnet1234567890\tpodman\tbridge")
        assertEquals("podman", networks.single().runtime)
    }

    @Test
    fun parsesMetrics() {
        val out = """
            @CPU
            %Cpu(s):  3.4 us,  1.0 sy,  0.0 ni, 95.6 id,  0.0 wa
            @MEM
            Mem:  8000000000 2000000000 1000000000 0 5000000000 6000000000
            @DISK
            /dev/sda1 100000000000 18000000000 82000000000 18% /
            @LOAD
            0.08 0.11 0.09 2/297 1234
            @UP
            123456.78 100000.0
            @PROC
            297
        """.trimIndent()
        val m = RemoteParsers.parseMetrics(out)
        assertEquals(4.4f, m.cpuPercent, 0.05f)        // 100 - 95.6
        assertEquals(8_000_000_000L, m.memTotalBytes)
        assertEquals(2_000_000_000L, m.memUsedBytes)   // total - available
        assertEquals(100_000_000_000L, m.diskTotalBytes)
        assertEquals(18_000_000_000L, m.diskUsedBytes)
        assertEquals(0.08f, m.load1, 0.001f)
        assertEquals(123456L, m.uptimeSeconds)
        assertEquals(297, m.procCount)
        assertTrue(m.diskPercent in 17f..19f)
    }

    @Test
    fun humanBytesFormatsReadably() {
        assertEquals("0 B", RemoteParsers.humanBytes(0))
        assertEquals("1.0 KB", RemoteParsers.humanBytes(1024))
        assertEquals("1.0 GB", RemoteParsers.humanBytes(1024L * 1024 * 1024))
    }

    @Test
    fun parsesBusyBoxCpuAndMeminfoFallback() {
        // BusyBox `top` uses "CPU: ... 98% idle" (no GNU "id"), and `free -b` may be absent so the
        // MEM section is empty — parseMetrics should fall back to /proc/meminfo (kB).
        val out = """
            @CPU
            CPU:   1% usr   0% sys   0% nic  98% idle   0% io   0% irq   0% sirq
            @MEM
            @MEMINFO
            MemTotal:        2000000 kB
            MemFree:          500000 kB
            MemAvailable:    1600000 kB
            @DISK
            /dev/sda1 100000000000 18000000000 82000000000 18% /
            @LOAD
            0.10 0.20 0.30 1/100 555
            @UP
            5000.00 4000.0
            @PROC
            100
        """.trimIndent()
        val m = RemoteParsers.parseMetrics(out)
        assertEquals(2f, m.cpuPercent, 0.05f)                 // 100 - 98
        assertEquals(2_000_000L * 1024, m.memTotalBytes)
        assertEquals(400_000L * 1024, m.memUsedBytes)         // (total - available) * 1024
    }

    @Test
    fun procStatAggregateCpuMatchesSameDeltaModelAsPerCore() {
        val prev = RemoteParsers.parseProcStat(
            """
            cpu  100 0 0 900 0 0 0 0
            cpu0 50 0 0 450 0 0 0 0
            cpu1 50 0 0 450 0 0 0 0
            """.trimIndent()
        )
        val cur = RemoteParsers.parseProcStat(
            """
            cpu  160 0 0 940 0 0 0 0
            cpu0 80 0 0 470 0 0 0 0
            cpu1 80 0 0 470 0 0 0 0
            """.trimIndent()
        )

        val aggregate = RemoteParsers.computeCpuUsageDelta(prev, cur, "cpu")
        val perCore = RemoteParsers.computePerCoreCpuDeltas(prev, cur)

        assertEquals(60f, aggregate ?: 0f, 0.001f)
        assertEquals(2, perCore.size)
        assertEquals(60f, perCore[0], 0.001f)
        assertEquals(60f, perCore[1], 0.001f)
    }

    @Test
    fun parsesServicesWithLeadingBullet() {
        // Some systemd builds emit a leading "●" status marker even with --plain; the unit must
        // still parse rather than being dropped.
        val out = "● nginx.service loaded active running A high performance web server"
        val svcs = RemoteParsers.parseServices(out)
        assertEquals(1, svcs.size)
        assertEquals("nginx", svcs[0].name)
        assertEquals("running", svcs[0].status)
        assertEquals("active", svcs[0].subState)
    }

    @Test
    fun tmuxAttachCommandDisablesMouseAndSetsHistory() {
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxCreateAttachCommand("omniterm-test-name", 12_000)
        // Touch scrolling stays local to the app; history-limit still caps tmux's own buffer.
        assertTrue("expected mouse off", cmd.contains("set-option -t omniterm-test-name mouse off"))
        assertTrue("expected history-limit", cmd.contains("history-limit 12000"))
        assertTrue("expected exec attach", cmd.contains("exec tmux attach-session -t omniterm-test-name"))
    }

    @Test
    fun tmuxAttachCommandSanitisesSessionName() {
        // Only [a-z0-9-] survives into the shell command; anything else is stripped (injection guard).
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxAttachCommand("bad; rm -rf /", 5_000)
        assertTrue(cmd.contains("badrm-rf"))
        assertTrue("no raw semicolon from the name", !cmd.contains("bad; rm"))
    }

    @Test
    fun tmuxAttachCommandClampsHistoryLimit() {
        val low = com.jetsetslow.omniterm.data.RemoteCommands.tmuxAttachCommand("x", 10)
        val high = com.jetsetslow.omniterm.data.RemoteCommands.tmuxAttachCommand("x", 999_999)
        assertTrue(low.contains("history-limit 1000"))   // floor
        assertTrue(high.contains("history-limit 50000"))  // ceiling
    }

    @Test
    fun tmuxAttachCommandSetsGlobalHistoryLimitBeforeSessionCreation() {
        // history-limit only applies to panes created after it is set, so the global option must
        // appear before new-session in the command — otherwise the first pane keeps tmux's
        // 2000-line default and back-scroll is silently capped regardless of the app setting.
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxCreateAttachCommand("omniterm-test-name", 12_000)
        val globalSet = cmd.indexOf("set-option -g history-limit 12000")
        val newSession = cmd.indexOf("new-session")
        assertTrue("expected a global history-limit", globalSet >= 0)
        assertTrue("global history-limit must precede new-session", globalSet < newSession)
    }

    @Test
    fun tmuxAttachCommandBootstrapsHistoryLimitOnFreshServer() {
        // A standalone `tmux set-option -g` ERRORS when no tmux server is running yet (the very
        // first session on a host), so the option must be chained after start-server inside one
        // tmux invocation — otherwise the first pane silently keeps the 2000-line default.
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxCreateAttachCommand("omniterm-test-name", 12_000)
        assertTrue(
            "history-limit must be set in a single start-server \\; set-option \\; new-session chain",
            cmd.contains("start-server \\; set-option -g history-limit 12000 \\; new-session"),
        )
    }

    @Test
    fun tmuxControlAttachSharesBootstrapAndUsesSingleC() {
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxControlCreateAttachCommand("omniterm-test-name", 12_000)
        // Same fresh-server-safe bootstrap as the regular attach…
        assertTrue(cmd.contains("start-server \\; set-option -g history-limit 12000 \\; new-session"))
        assertTrue(cmd.contains("set-option -t omniterm-test-name mouse off"))
        // …but ending in control mode. Single -C: -CC adds a DCS envelope we must not parse.
        assertTrue(cmd.trimEnd().endsWith("exec tmux -C attach-session -t omniterm-test-name"))
        assertTrue(!cmd.contains("-CC"))
    }

    @Test
    fun tmuxReconnectRequiresExistingSessionAndNeverCreatesReplacement() {
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxAttachCommand("omniterm-test-name", 12_000)
        assertTrue(cmd.contains("tmux has-session -t omniterm-test-name"))
        assertFalse(cmd.contains("new-session"))
    }

    @Test
    fun tmuxControlSideChannelCommandsSanitiseSessionNames() {
        val hostile = "bad; rm -rf /"
        for (cmd in listOf(
            com.jetsetslow.omniterm.data.RemoteCommands.tmuxActivePaneQuery(hostile),
            com.jetsetslow.omniterm.data.RemoteCommands.tmuxCursorQuery(hostile),
            com.jetsetslow.omniterm.data.RemoteCommands.tmuxCaptureScreenCommand(hostile),
        )) {
            assertTrue("expected sanitised name in: $cmd", cmd.contains("-t badrm-rf"))
            assertTrue("semicolon must not survive: $cmd", !cmd.contains(";"))
        }
    }

    @Test
    fun composeStackWorkingDirPrefersLabelThenConfigFileParent() {
        val p = com.jetsetslow.omniterm.data.RemoteParsers
        assertEquals("/srv/app", p.composeStackWorkingDir("/srv/app", "/elsewhere/docker-compose.yml"))
        // podman-compose case: config_files label set, working_dir absent.
        assertEquals("/srv/stacks/app", p.composeStackWorkingDir("", "/srv/stacks/app/docker-compose.yml,/srv/stacks/app/override.yml"))
        // A relative config file gives no usable directory.
        assertEquals("", p.composeStackWorkingDir("", "relative/compose.yml"))
        assertEquals("", p.composeStackWorkingDir("", ""))
    }

    @Test
    fun composeConfigPresentRequiresAllRecordedFiles() {
        // The -f chain fails if ANY file is missing, so the probe must AND them; relative
        // entries resolve against the working dir.
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.composeConfigPresent("/srv/app", "/srv/app/a.yml, b.yml")
        assertTrue(cmd.contains("[ -f '/srv/app/a.yml' ] && [ -f '/srv/app/b.yml' ]"))
        assertTrue(cmd.contains("OMNITERM_COMPOSE_OK"))
        assertTrue(cmd.contains("OMNITERM_COMPOSE_MISSING"))
    }

    @Test
    fun composeConfigPresentFallsBackToConventionalComposeNames() {
        // With no recorded config files, any conventional compose file in the working dir will do
        // (that's what compose itself would pick up there).
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.composeConfigPresent("/srv/app/", "")
        assertTrue(cmd.contains("[ -f '/srv/app/compose.yaml' ] || [ -f '/srv/app/compose.yml' ]"))
        assertTrue(cmd.contains("'/srv/app/docker-compose.yml'"))
    }

    @Test
    fun tmuxCaptureHistoryCommandTargetsHistoryOnlyAndSanitises() {
        val cmd = com.jetsetslow.omniterm.data.RemoteCommands.tmuxCaptureHistoryCommand("bad; rm -rf /", 12_000)
        assertTrue("expected joined wrapped lines", cmd.contains("-J"))
        assertTrue("expected colours preserved", cmd.contains("-e"))
        assertTrue("expected capture depth", cmd.contains("-S -12000"))
        assertTrue("expected to stop above the visible screen", cmd.contains("-E -1"))
        assertTrue("no raw semicolon from the name", !cmd.contains("bad; rm"))
        assertTrue(
            "expected inner-TUI guard: capture must emit nothing while the pane's alternate screen is on",
            cmd.contains("#{alternate_on}"),
        )
    }

    @Test
    fun shellQuoteNeutralisesSpecialCharacters() {
        val q = com.jetsetslow.omniterm.data.RemoteCommands::shellQuote
        // Plain text is wrapped in single quotes.
        assertEquals("'file.txt'", q.invoke("file.txt"))
        // Spaces survive intact inside the quotes (one argument, not split).
        assertEquals("'my file'", q.invoke("my file"))
        // A single quote is closed, escaped, and reopened: ' -> '\'' .
        assertEquals("'it'\\''s'", q.invoke("it's"))
        // Shell metacharacters are inert inside single quotes — no expansion, no command execution.
        assertEquals("'\$(rm -rf /)'", q.invoke("\$(rm -rf /)"))
        assertEquals("'`whoami`'", q.invoke("`whoami`"))
        assertEquals("'a;b|c&d'", q.invoke("a;b|c&d"))
        // Newlines stay literal (a path with a newline is still a single argument).
        assertEquals("'line1\nline2'", q.invoke("line1\nline2"))
        // Unicode passes through untouched.
        assertEquals("'café_日本'", q.invoke("café_日本"))
    }
}
