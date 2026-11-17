package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.BackupChecks
import com.jetsetslow.omniterm.data.BackupChecks.Tool
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.Proxmox
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Backup Age readings: what each tool's listing and errors mean, and the command itself in a real
 * POSIX shell against stand-in tools that print what restic 0.18, Borg 1.4 and the PBS client print.
 */
class BackupChecksTest {
    @get:Rule val tmp = TemporaryFolder()

    /** 2026-01-01 00:00:00 UTC, the fixture backups' time. */
    private val jan1 = 1_767_225_600L
    private val now = jan1 + 30 * 3600

    private fun target(tool: Tool, repo: String = "/srv/repo", filter: String = "", settings: String = "", fp: String = "") =
        BackupChecks.Target(tool, repo, filter, settings, fp)

    private fun ran(body: String, rc: Int, err: String = "") = "@BACKUP\n$body\n!RC $rc\n@ERR\n$err\n"

    @Test
    fun aTargetSurvivesItsOwnEncodingAndRefusesWhatCannotBeChecked() {
        val t = target(Tool.PBS, "backup@pbs@pbs.lan:store", "vm/100", "/etc/pbs.env", List(32) { "ab" }.joinToString(":"))
        assertEquals(t, BackupChecks.decode(BackupChecks.encode(t)))
        assertNull(BackupChecks.decode("rsync\n/srv"))
        assertEquals("Pick a backup tool", BackupChecks.problem(null))
        assertNotNull(BackupChecks.problem(target(Tool.RESTIC, repo = "")))
        assertNull("a settings file can name the repository", BackupChecks.problem(target(Tool.RESTIC, repo = "", settings = "/etc/restic/env")))
        assertNull("no folder: the Proxmox VE server's backup tasks", BackupChecks.problem(target(Tool.VZDUMP, repo = "")))
        assertNotNull(BackupChecks.problem(target(Tool.VZDUMP, repo = "", filter = "web")))
        assertNotNull(BackupChecks.problem(target(Tool.VZDUMP, filter = "100; rm -rf /")))
        assertNotNull(BackupChecks.problem(target(Tool.PBS, fp = "ab:cd")))
        // A newline typed into a field cannot start a new field.
        assertEquals("/srv repo", BackupChecks.decode(BackupChecks.encode(target(Tool.BORG, repo = "/srv\nrepo")))!!.repository)
    }

    @Test
    fun resticReadsTheNewestSnapshotOfEveryGroupAndNamesItsErrors() {
        val t = target(Tool.RESTIC)
        val listing = """[{"time":"2025-12-31T00:00:00Z","short_id":"aaaa1111"},""" +
            """{"time":"2026-01-01T05:30:00.123456789+05:30","short_id":"718e5335"}]"""
        val newest = BackupChecks.parse(t, ran(listing, 0), now)!!
        assertEquals(30f, newest.value)
        assertEquals("snapshot 718e5335", newest.detail)
        assertEquals(BackupChecks.NO_BACKUPS, BackupChecks.parse(t, ran("[]", 0), now)!!.value)

        val wrong = BackupChecks.parse(t, ran("", 12, """{"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}"""), now)!!
        assertEquals(BackupChecks.AUTH_FAILED, wrong.value)
        assertEquals("Fatal: wrong password or no key found", wrong.detail)
        val missing = """{"message_type":"exit_error","code":10,"message":"Fatal: repository does not exist: unable to open config file: stat /srv/repo/config: no such file or directory\nIs there a repository at the following location?"}"""
        assertEquals(BackupChecks.REPO_MISSING, BackupChecks.parse(t, ran("", 10, missing), now)!!.value)
        // Older restic exits 1 with the same words.
        assertEquals(BackupChecks.AUTH_FAILED, BackupChecks.parse(t, ran("", 1, "Fatal: wrong password or no key found"), now)!!.value)
        assertEquals(BackupChecks.AUTH_FAILED, BackupChecks.parse(t, ran("", 1, "Fatal: an empty password is not allowed by default"), now)!!.value)
        assertNull("a locked repository says nothing", BackupChecks.parse(t, ran("", 11, "unable to create lock in backend"), now)!!.value)
        assertEquals(BackupChecks.FAILED, BackupChecks.parse(t, ran("", 1, "Fatal: unable to open repository: block device gone"), now)!!.value)
    }

    @Test
    fun borgTimesAreUtcAndItsModernExitCodesAreNamed() {
        val t = target(Tool.BORG)
        val listing = """
            {
                "archives": [
                    {"archive": "fixture-2026-01-01", "name": "fixture-2026-01-01", "start": "2026-01-01T00:00:00.000000", "time": "2026-01-01T00:00:00.000000"}
                ],
                "encryption": {"mode": "repokey"}
            }
        """.trimIndent()
        val read = BackupChecks.parse(t, ran(listing, 0), now)!!
        assertEquals(30f, read.value)
        assertEquals("archive fixture-2026-01-01", read.detail)
        assertEquals(BackupChecks.NO_BACKUPS, BackupChecks.parse(t, ran("""{"archives": []}""", 0), now)!!.value)
        val badPass = "Passphrase supplied in BORG_PASSPHRASE, by BORG_PASSCOMMAND, or via BORG_PASSPHRASE_FD is incorrect."
        assertEquals(BackupChecks.AUTH_FAILED, BackupChecks.parse(t, ran("", 52, badPass), now)!!.value)
        assertEquals(BackupChecks.AUTH_FAILED, BackupChecks.parse(t, ran("", 2, badPass), now)!!.value)
        assertEquals(BackupChecks.REPO_MISSING, BackupChecks.parse(t, ran("", 13, "Repository /srv/repo does not exist."), now)!!.value)
        assertEquals(BackupChecks.REPO_MISSING, BackupChecks.parse(t, ran("", 2, "Repository /srv/repo does not exist."), now)!!.value)
        assertNull(BackupChecks.parse(t, ran("", 2, "Failed to create/acquire the lock /srv/repo/lock.exclusive (timeout)."), now)!!.value)
    }

    @Test
    fun pbsReadsBackupTimeAndNamesTheGroup() {
        val t = target(Tool.PBS, "backup@pbs@pbs.lan:store")
        val listing = """[{"backup-type":"vm","backup-id":"100","backup-time":${jan1 - 86_400}},{"backup-type":"ct","backup-id":"101","backup-time":$jan1}]"""
        val read = BackupChecks.parse(t, ran(listing, 0), now)!!
        assertEquals(30f, read.value)
        assertEquals("ct/101", read.detail)
        assertEquals(BackupChecks.AUTH_FAILED, BackupChecks.parse(t, ran("", 255, "Error: authentication failed - invalid credentials"), now)!!.value)
        assertEquals(BackupChecks.REPO_MISSING, BackupChecks.parse(t, ran("", 255, "Error: datastore 'store' does not exist"), now)!!.value)
        val untrusted = BackupChecks.parse(t, ran("", 255, "Error: certificate validation failed - Certificate fingerprint was not confirmed."), now)!!
        assertEquals(BackupChecks.FAILED, untrusted.value)
        assertTrue(untrusted.detail, "fingerprint" in untrusted.detail)
    }

    @Test
    fun aCheckThatNeverRanSaysNothingAndASlowOneIsUnknown() {
        val t = target(Tool.RESTIC)
        assertNull(BackupChecks.parse(t, "SSH Error: connect timed out", now))
        assertNull(BackupChecks.parse(t, ran("", 124), now)!!.value)
        assertEquals(BackupChecks.TOOL_MISSING, BackupChecks.parse(t, "@BACKUP\n!TOOL\n", now)!!.value)
        assertEquals(BackupChecks.FAILED, BackupChecks.parse(target(Tool.RESTIC, settings = "/etc/x"), "@BACKUP\n!SETTINGS\n", now)!!.value)
    }

    @Test
    fun everyErrorAlertsWhateverTheLimitAndAgesReadAsPeopleSayThem() {
        listOf(BackupChecks.NO_BACKUPS, BackupChecks.TOOL_MISSING, BackupChecks.REPO_MISSING, BackupChecks.AUTH_FAILED, BackupChecks.FAILED)
            .forEach { assertTrue(HostChecks.breached(HostChecks.BACKUP_AGE, it, 1000f)) }
        assertFalse(HostChecks.breached(HostChecks.BACKUP_AGE, 25f, 26f))
        assertTrue(HostChecks.breached(HostChecks.BACKUP_AGE, 27f, 26f))
        assertFalse("other checks keep their own rule", HostChecks.breached(HostChecks.FAILED_SERVICES, -1f, 0f))
        assertEquals("30 h old", BackupChecks.describe(30f))
        assertEquals("3 days old", BackupChecks.describe(72f))
        assertEquals("Newest backup 30 h old (snapshot 718e5335)", BackupChecks.summary(30f, "snapshot 718e5335"))
        assertEquals("Wrong password: Fatal: wrong password", BackupChecks.summary(BackupChecks.AUTH_FAILED, "Fatal: wrong password"))
        assertEquals(
            "Newest restic backup is 30 h old (limit 26 h): snapshot 718e5335",
            BackupChecks.alertText(target(Tool.RESTIC), 30f, 26f, "snapshot 718e5335"),
        )
        assertEquals("restic refused the password for /srv/repo", BackupChecks.alertText(target(Tool.RESTIC), BackupChecks.AUTH_FAILED, 26f, ""))
        assertEquals(26f, HostChecks.defaultThreshold(HostChecks.BACKUP_AGE))
        assertEquals("0m", HostChecks.defaultWindow(HostChecks.BACKUP_AGE))
        assertFalse(HostChecks.needsProbe(HostChecks.BACKUP_AGE))
        assertTrue(HostChecks.runsOnHost(HostChecks.BACKUP_AGE))
    }

    @Test
    fun timesParseWithAndWithoutAnOffset() {
        assertEquals(jan1, BackupChecks.epochOf("2026-01-01T00:00:00Z"))
        assertEquals(jan1, BackupChecks.epochOf("2026-01-01T05:30:00.5+05:30"))
        assertEquals(jan1, BackupChecks.epochOf("2025-12-31T19:00:00-0500"))
        assertNull("no offset is not guessed", BackupChecks.epochOf("2026-01-01T00:00:00"))
        assertEquals(jan1, BackupChecks.epochOf("2026-01-01T00:00:00.000000", assumeUtc = true))
        assertEquals(951_782_400L, BackupChecks.epochOf("2000-02-29T00:00:00Z"))
        assertNull(BackupChecks.epochOf("yesterday"))
    }

    /**
     * The commands in a real shell against stand-ins. Each stand-in records its arguments and
     * answers only when its own password variable holds the password: so the password reaches the
     * tool, and never its command line.
     */
    @Test
    fun theCommandsPassThePasswordOnlyThroughTheToolsOwnVariable() {
        val sh = TestShell.sh
        assumeTrue("needs a POSIX shell", sh != null)
        val bin = tmp.newFolder("bin")
        for (tool in listOf("sed", "awk", "head", "date", "cat", "ls", "sort", "tail", "grep", "timeout", "mktemp", "rm", "cut", "printf")) {
            val real = System.getenv("PATH").orEmpty().split(File.pathSeparator).map { File(it, tool) }.firstOrNull { it.canExecute() }
                ?: continue
            java.nio.file.Files.createSymbolicLink(File(bin, tool).toPath(), real.toPath())
        }
        listOf("sed", "awk", "date", "ls", "sort", "tail", "grep", "mktemp", "rm", "cut").forEach {
            assumeTrue("needs $it", File(bin, it).exists())
        }
        val args = File(tmp.root, "args")
        fun stub(name: String, variable: String, ok: String, refused: String) = File(bin, name).apply {
            writeText(
                "#!/bin/sh\nprintf '%s\\n' \"\$*\" >>'${args.path}'\n" +
                    "if [ \"\$$variable\" = 's3cret pass' ]; then printf '%s\\n' '$ok'; exit 0; fi\n" +
                    "printf '%s\\n' '$refused' >&2; exit 12\n"
            )
            setExecutable(true)
        }
        stub("restic", "RESTIC_PASSWORD", """[{"time":"2026-01-01T00:00:00Z","short_id":"718e5335"}]""", """{"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}""")
        stub("borg", "BORG_PASSPHRASE", """{"archives":[{"name":"nightly","time":"2026-01-01T00:00:00.000000"}]}""", "Passphrase supplied in BORG_PASSPHRASE is incorrect.")
        stub("proxmox-backup-client", "PBS_PASSWORD", """[{"backup-type":"vm","backup-id":"100","backup-time":$jan1}]""", "Error: authentication failed - invalid credentials")
        fun run(t: BackupChecks.Target, stdin: String) =
            BackupChecks.parse(t, TestShell.run(BackupChecks.command(t), stdin = stdin, env = mapOf("PATH" to bin.path, "TZ" to "UTC", "LC_ALL" to "C"), clean = true, shell = sh!!).output, now)!!

        for (tool in listOf(Tool.RESTIC, Tool.BORG, Tool.PBS)) {
            val t = target(tool, "/srv/it's a repo", if (tool == Tool.PBS) "vm/100" else "nas")
            assertEquals("$tool reads with the password", 30f, run(t, "s3cret pass\n").value)
            assertEquals("$tool without it", BackupChecks.AUTH_FAILED, run(t, "wrong\n").value)
        }
        val recorded = args.readText()
        assertFalse("the password is in no command line", "s3cret" in recorded)
        assertTrue("a repository with a quote reaches the tool whole", "/srv/it's a repo" in recorded)
        assertTrue("restic reads without taking a lock", "snapshots --json --no-lock --latest 1 --host nas" in recorded)
        assertTrue("borg skips the lock too", "list --json --last 1 --bypass-lock -a nas /srv/it's a repo" in recorded)

        // A settings file can name the repository and the password.
        val env = File(tmp.root, "restic.env").apply { writeText("RESTIC_REPOSITORY=/srv/from-file\nRESTIC_PASSWORD='s3cret pass'\n") }
        assertEquals(30f, run(target(Tool.RESTIC, repo = "", settings = env.path), "\n").value)
        assertEquals(BackupChecks.FAILED, run(target(Tool.RESTIC, settings = File(tmp.root, "missing.env").path), "\n").value)
        File(bin, "restic").delete()
        assertEquals(BackupChecks.TOOL_MISSING, run(target(Tool.RESTIC), "s3cret pass\n").value)
    }

    /** vzdump's own names, read as Proxmox reads them; its logs and notes are not dumps. */
    @Test
    fun theNewestVzdumpFileIsReadByItsNameInTheHostsTimeZone() {
        val sh = TestShell.sh
        assumeTrue("needs a POSIX shell", sh != null)
        assumeTrue(
            "needs a date that reads -d",
            TestShell.run("date -d '2026-01-01 00:00:00' +%s", env = mapOf("TZ" to "UTC"), shell = sh!!).output.trim() == "$jan1",
        )
        val dir = tmp.newFolder("dump")
        listOf(
            "vzdump-qemu-100-2025_12_31-00_00_00.vma.zst", "vzdump-qemu-100-2026_01_01-00_00_00.vma.zst",
            "vzdump-lxc-101-2025_12_25-00_00_00.tar.zst", "vzdump-qemu-100-2026_01_02-00_00_00.log",
            "vzdump-qemu-100-2026_01_02-00_00_00.vma.zst.notes", "other-2026_02_01.tar",
        ).forEach { File(dir, it).writeText("") }
        fun run(filter: String, tz: String = "UTC", folder: String = dir.path): BackupChecks.Outcome {
            val t = target(Tool.VZDUMP, folder, filter)
            return BackupChecks.parse(t, TestShell.run(BackupChecks.command(t), stdin = "\n", env = mapOf("TZ" to tz), shell = sh).output, now)!!
        }
        val newest = run("")
        assertEquals(30f, newest.value)
        assertEquals("vzdump-qemu-100-2026_01_01-00_00_00.vma.zst", newest.detail)
        assertEquals("guest 101's own newest", 30f + 7 * 24, run("101").value)
        assertEquals("a dump in India's time is 5.5 hours older in UTC", 35.5f, run("", tz = "IST-5:30").value)
        assertEquals(BackupChecks.NO_BACKUPS, run("102").value)
        assertEquals(BackupChecks.REPO_MISSING, run("", folder = File(tmp.root, "nope").path).value)
    }

    @Test
    fun aVzdumpRuleWithNoFolderCountsTheNewestBackupTheServerFinished() {
        fun task(id: String, start: Long, end: Long?, status: String) = Proxmox.Task("UPID:pve1:$id:$start", "pve1", "vzdump", id, "root@pam", start, end, status)
        val web = Proxmox.Guest("pve1", 100, "qemu", "web", "running", null, null, null, null, null, false)
        val job = task("", jan1, jan1 + 600, "job errors")
        val overview = Proxmox.Overview("8.4", emptyList(), listOf(web), emptyList(), listOf(
            Proxmox.BackupRun(task("101", jan1 + 3600, jan1 + 3700, "ERROR: no space"), mapOf(101 to "ERROR: no space")),
            Proxmox.BackupRun(job, mapOf(100 to null, 101 to "no space left on device")),
            Proxmox.BackupRun(task("100", jan1 - 86_400, jan1 - 86_000, "OK"), mapOf(100 to null)),
        ))
        val api = target(Tool.VZDUMP, repo = "", filter = "100")
        assertTrue(BackupChecks.readsProxmoxTasks(api))
        assertFalse("a folder is read on the host", BackupChecks.readsProxmoxTasks(target(Tool.VZDUMP)))
        // Counted from when the job finished with guest 100.
        assertEquals(BackupChecks.Outcome((now - jan1 - 600) / 3600f, "VM 100 (web) on pve1"), BackupChecks.fromProxmox(api, overview, now))
        val failedOnly = BackupChecks.fromProxmox(api.copy(filter = "101"), overview, now)
        assertEquals("a failed backup is no backup", BackupChecks.Outcome(BackupChecks.NO_BACKUPS, "no backup of guest 101 finished"), failedOnly)
        assertEquals("No Proxmox VE backup: no backup of guest 101 finished", BackupChecks.alertText(api, failedOnly.value!!, 26f, failedOnly.detail))
        assertEquals("any guest", (now - jan1 - 600) / 3600f, BackupChecks.fromProxmox(api.copy(filter = ""), overview, now).value)
    }
}
