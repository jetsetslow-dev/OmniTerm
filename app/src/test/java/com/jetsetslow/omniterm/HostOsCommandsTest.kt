package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import com.jetsetslow.omniterm.data.SimService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Every host action picks the command its OS understands.
 *
 * The BSD and macOS service lists are shell logic over tools this machine does not have, so they
 * run against small fake `service`, `rcctl`, `launchctl` and `id` scripts that print what the real
 * tools print. That checks the parsing loop itself rather than only the command text.
 */
class HostOsCommandsTest {

    private fun services(output: String) = RemoteParsers.parseServices(output).associateBy { it.name }

    private fun assertService(service: SimService?, status: String, enabled: Boolean) {
        requireNotNull(service)
        assertEquals(service.name, status, service.status)
        assertEquals(service.name, enabled, service.enabled)
    }

    /** Runs [script] with only [fakes] and the base system tools on PATH. */
    private fun runWithFakes(script: String, fakes: Map<String, String>): String {
        val sh = File("/bin/sh")
        assumeTrue("POSIX sh is required to run the service scripts", sh.canExecute())
        val dir = Files.createTempDirectory("omniterm-fake-tools").toFile()
        try {
            fakes.forEach { (name, body) ->
                File(dir, name).apply { writeText("#!/bin/sh\n$body\n"); setExecutable(true) }
            }
            val process = ProcessBuilder(sh.absolutePath, "-c", script).redirectErrorStream(true)
            process.environment()["PATH"] = "${dir.absolutePath}:/usr/bin:/bin"
            val proc = process.start()
            val output = proc.inputStream.bufferedReader().readText()
            proc.waitFor()
            return output
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun eachOsGetsItsOwnServiceList() {
        assertEquals(RemoteCommands.SERVICES, RemoteCommands.servicesFor("Linux"))
        assertEquals(RemoteCommands.SERVICES_BSD, RemoteCommands.servicesFor("FreeBSD"))
        assertEquals(RemoteCommands.SERVICES_BSD, RemoteCommands.servicesFor("OpenBSD"))
        assertEquals(RemoteCommands.SERVICES_DARWIN, RemoteCommands.servicesFor("Darwin"))
        assertEquals(RemoteCommands.SERVICES_WINDOWS, RemoteCommands.servicesFor("Windows"))
    }

    @Test
    fun freeBsdServicesComeFromRcD() {
        val out = runWithFakes(
            RemoteCommands.SERVICES_BSD,
            mapOf(
                "service" to """
                    case "${'$'}1" in
                      -e) printf '/etc/rc.d/sshd\n/usr/local/etc/rc.d/nginx\n';;
                      -l) printf 'DAEMON\nLOGIN\nnginx\nntpd\nsshd\n';;
                      sshd|ntpd) [ "${'$'}2" = onestatus ] && exit 0; exit 1;;
                      *) exit 1;;
                    esac
                """.trimIndent(),
            ),
        )
        val list = services(out)
        assertEquals(setOf("nginx", "ntpd", "sshd"), list.keys)
        assertService(list["sshd"], "running", enabled = true)
        assertService(list["nginx"], "dead", enabled = true)
        assertService(list["ntpd"], "running", enabled = false)
    }

    @Test
    fun openBsdServicesComeFromRcctl() {
        val out = runWithFakes(
            RemoteCommands.SERVICES_BSD,
            mapOf(
                "rcctl" to """
                    case "${'$'}1 ${'$'}2" in
                      "ls all") printf 'ntpd\nsmtpd\nsshd\n';;
                      "ls on") printf 'smtpd\nsshd\n';;
                      "ls started") printf 'sshd\n';;
                    esac
                """.trimIndent(),
            ),
        )
        val list = services(out)
        assertService(list["sshd"], "running", enabled = true)
        assertService(list["smtpd"], "dead", enabled = true)
        assertService(list["ntpd"], "dead", enabled = false)
    }

    private val launchctl = """
        case "${'$'}1" in
          print) exit 0;;
          print-disabled) printf 'disabled services = {\n\t"com.example.off" => disabled\n\t"com.example.web" => enabled\n}\n';;
          list) printf 'PID\tStatus\tLabel\n412\t0\tcom.example.web\n-\t0\tcom.example.off\n-\t78\tcom.example.crashy\n';;
          *) echo "launchctl ${'$'}*";;
        esac
    """.trimIndent()

    @Test
    fun macServicesComeFromLaunchd() {
        val out = runWithFakes(RemoteCommands.SERVICES_DARWIN, mapOf("launchctl" to launchctl, "id" to "echo 501"))
        val list = services(out)
        assertService(list["com.example.web"], "running", enabled = true)
        assertService(list["com.example.off"], "dead", enabled = false)
        assertService(list["com.example.crashy"], "failed", enabled = true)
    }

    @Test
    fun macServiceActionsUseTheDomainTheListCameFrom() {
        val out = runWithFakes(
            RemoteCommands.serviceAction("com.example.web", "restart", os = "Darwin"),
            mapOf("launchctl" to launchctl, "id" to "echo 501"),
        )
        assertEquals("launchctl kickstart -k gui/501/com.example.web", out.trim())
        assertFalse(RemoteCommands.serviceActionUsesSudo("Darwin"))
    }

    @Test
    fun windowsServicesReadTheirStatusAndStartType() {
        val out = "---SERVICE-TABLE---\r\n" +
            "Spooler\tRunning\tAutomatic\tPrint Spooler\r\n" +
            "wuauserv\tStopped\tManual\tWindows Update\r\n" +
            "BITS\tRunning\tAutomaticDelayedStart\tBackground Intelligent Transfer Service\r\n" +
            "Fax\tStopped\tDisabled\tFax\r\n"
        val list = services(out)
        assertService(list["Spooler"], "running", enabled = true)
        assertService(list["wuauserv"], "dead", enabled = false)
        assertService(list["BITS"], "running", enabled = true)
        assertService(list["Fax"], "dead", enabled = false)
        assertEquals("Print Spooler", list["Spooler"]?.desc)
        assertTrue(RemoteCommands.SERVICES_WINDOWS.startsWith("powershell "))
    }

    @Test
    fun serviceActionsSpeakEachServiceManager() {
        val bsd = RemoteCommands.serviceAction("sshd", "start", "pw", "FreeBSD")
        assertTrue(bsd, bsd.startsWith("sudo -S -p '' sh -c "))
        assertTrue(bsd, bsd.contains("rcctl start ") && bsd.contains("service ") && bsd.contains(" onestart"))
        assertTrue(RemoteCommands.serviceActionUsesSudo("FreeBSD"))

        assertEquals(
            "powershell -NoProfile -Command \"Restart-Service -Name 'Spooler' -Force\"",
            RemoteCommands.serviceAction("Spooler", "restart", "pw", "Windows"),
        )
        assertTrue(RemoteCommands.serviceAction("it's", "stop", os = "Windows").contains("-Name 'it''s'"))
        assertFalse(RemoteCommands.serviceAction("50%", "stop", os = "Windows").contains("powershell"))
        assertFalse(RemoteCommands.serviceActionUsesSudo("Windows"))

        val linux = RemoteCommands.serviceAction("nginx", "restart", "", "Linux")
        // sudoShWrap quotes the whole script again, so the name's own quotes come out as '\''.
        assertTrue(linux, linux.contains("systemctl restart ") && linux.contains("nginx") && linux.contains("rc-service"))
    }

    @Test
    fun rebootUsesEachOsShutdown() {
        assertEquals("shutdown /r /t 0 2>&1", RemoteCommands.reboot("pw", "Windows"))
        assertFalse(RemoteCommands.rebootUsesSudo("Windows"))
        assertTrue(RemoteCommands.reboot("pw", "FreeBSD").startsWith("sudo -S -p '' shutdown -r now"))
        assertTrue(RemoteCommands.reboot("", "Darwin").startsWith("sudo -n shutdown -r now"))
        assertTrue(RemoteCommands.reboot("", "Linux").startsWith("sudo -n reboot"))
        assertEquals("sudo reboot", RemoteCommands.rebootLabel("Linux"))
        assertEquals("sudo shutdown -r now", RemoteCommands.rebootLabel("FreeBSD"))
        assertEquals("shutdown /r /t 0", RemoteCommands.rebootLabel("Windows"))
    }

    @Test
    fun endingAProcessUsesTaskkillOnWindows() {
        assertEquals("taskkill /PID 42", RemoteCommands.killProcess(42, 15, "Windows"))
        assertEquals("taskkill /PID 42 /F", RemoteCommands.killProcess(42, 9, "Windows"))
        assertEquals("kill -9 42", RemoteCommands.killProcess(42, 9, "Linux"))
        assertEquals("kill -15 42", RemoteCommands.killProcess(42, 15, "Darwin"))
    }

    @Test
    fun fleetChecksAskWindowsInPowerShell() {
        RemoteCommands.QuickCheck.entries.forEach { check ->
            assertTrue(check.name, RemoteCommands.quickCheck(check, "Windows").startsWith("powershell -NoProfile -Command \""))
        }
        assertEquals("uptime", RemoteCommands.quickCheck(RemoteCommands.QuickCheck.Uptime, "FreeBSD"))
        assertEquals("df -h", RemoteCommands.quickCheck(RemoteCommands.QuickCheck.Disk, "Linux"))
    }

    @Test
    fun onlyWindowsLacksAUnixShell() {
        assertFalse(RemoteCommands.hasUnixShell("Windows"))
        listOf("Linux", "FreeBSD", "Darwin", "").forEach { assertTrue(it, RemoteCommands.hasUnixShell(it)) }
    }

    @Test
    fun aPowerShellLoginShellIsRecognisedAsWindows() {
        val parseError = """
            At line:1 char:22
            + uname -s 2>/dev/null || echo Windows
            +                      ~~
            The token '||' is not a valid statement separator in this version.
                + CategoryInfo          : ParserError: (:) [], ParentContainsErrorRecordException
        """.trimIndent()
        assertEquals("Windows", RemoteCommands.normaliseOs(parseError))
    }
}
