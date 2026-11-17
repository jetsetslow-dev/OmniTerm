package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ScriptParams
import com.jetsetslow.omniterm.data.ScriptParams.Shell
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * `{{placeholders}}` in saved scripts. The values come from a form today and from automation
 * later, so the quoting is what stands between a value and a second command on every host.
 */
class ScriptParamsTest {

    @Test
    fun placeholdersAreFoundOnceEachWithTheirDefaults() {
        val params = ScriptParams.parse("qm {{action=start}} {{vmid}} && qm status {{ vmid }}")
        assertEquals(listOf(ScriptParams.Param("action", "start"), ScriptParams.Param("vmid", "")), params)
        assertTrue(ScriptParams.hasParams("echo {{x}}"))
    }

    @Test
    fun shellSyntaxThatOnlyLooksLikeAPlaceholderIsLeftAlone() {
        // Docker's Go templates and awk blocks use braces too.
        assertFalse(ScriptParams.hasParams("docker ps --format \"table {{.Names}}\\t{{.Status}}\""))
        assertFalse(ScriptParams.hasParams("awk '{print \$1}'"))
        assertFalse(ScriptParams.hasParams("echo {{1abc}}"))
        assertEquals(
            "docker ps --format '{{.Names}}'",
            ScriptParams.fill("docker ps --format '{{.Names}}'", emptyMap(), Shell.Posix),
        )
    }

    @Test
    fun plainValuesAreInsertedAsTheyAre() {
        assertEquals("qm start 101", ScriptParams.fill("qm start {{vmid}}", mapOf("vmid" to "101"), Shell.Posix))
        assertEquals("qm start 101", ScriptParams.fill("qm start {{vmid}}", mapOf("vmid" to "101"), Shell.Windows))
        assertEquals("systemctl status nginx", ScriptParams.fill("systemctl status {{svc=nginx}}", emptyMap(), Shell.Posix))
    }

    @Test
    fun aValueCannotStartASecondCommandOnAUnixHost() {
        val filled = ScriptParams.fill("echo {{msg}}", mapOf("msg" to "x; rm -rf / \$(id) `id` 'q'"), Shell.Posix)
        assertEquals("echo 'x; rm -rf / \$(id) `id` '\\''q'\\'''", filled)
    }

    @Test
    fun emptyValuesStayOneArgument() {
        assertEquals("printf '[%s]' ''", ScriptParams.fill("printf '[%s]' {{v}}", emptyMap(), Shell.Posix))
        assertEquals("echo \"\"", ScriptParams.fill("echo {{v}}", emptyMap(), Shell.Windows))
    }

    @Test
    fun windowsValuesThatAShellWouldExpandAreRefused() {
        assertEquals("Get-Service \"My Service\"", ScriptParams.fill("Get-Service {{n}}", mapOf("n" to "My Service"), Shell.Windows))
        listOf("%PATH%", "\$env:USERNAME", "a\"b", "`whoami`", "!x!", "two\nlines").forEach { value ->
            assertThrows(value, ScriptParams.UnsafeValueException::class.java) {
                ScriptParams.fill("echo {{n}}", mapOf("n" to value), Shell.Windows)
            }
            assertNotNull(value, ScriptParams.problem("n", value, Shell.Windows))
        }
        assertNull(ScriptParams.problem("n", "%PATH%", Shell.Posix))
    }

    @Test
    fun controlCharactersAndHugeValuesAreRefusedEverywhere() {
        Shell.entries.forEach { shell ->
            assertNotNull(ScriptParams.problem("n", "a\u001b[2Jb", shell))
            assertNotNull(ScriptParams.problem("n", "x".repeat(5000), shell))
        }
    }

    @Test
    fun theOsPicksTheQuoting() {
        assertEquals(Shell.Windows, ScriptParams.shellFor("Windows"))
        assertEquals(Shell.Posix, ScriptParams.shellFor("Linux"))
        assertEquals(Shell.Posix, ScriptParams.shellFor("FreeBSD"))
        assertEquals(Shell.Posix, ScriptParams.shellFor(""))
    }

    private val web = ScriptParams.HostVars("web 1", "10.0.0.5", "deploy", 2222, "Linux", "prod")

    @Test
    fun eachHostFillsInItsOwnDetailsAndNoneIsAsked() {
        val command = "echo {{host.name}} {{host.address}}:{{host.port}} {{host.user}} {{host.os}} {{host.group}} {{svc=nginx}}"
        assertEquals("only the value is asked", listOf(ScriptParams.Param("svc", "nginx")), ScriptParams.parse(command))
        assertTrue(ScriptParams.usesHostVars(command))
        assertTrue(ScriptParams.needsFill("uptime; echo {{host.name}}"))
        assertFalse(ScriptParams.hasParams("uptime; echo {{host.name}}"))
        assertEquals(
            "echo 'web 1' 10.0.0.5:2222 deploy linux prod nginx",
            ScriptParams.fill(command, emptyMap(), Shell.Posix, web),
        )
        assertEquals(
            listOf("windows", "macos", "bsd", "linux"),
            listOf("Windows", "Darwin", "FreeBSD", "Linux").map { ScriptParams.fill("{{host.os}}", emptyMap(), Shell.Posix, web.copy(os = it)) },
        )
    }

    @Test
    fun aHostsDetailIsQuotedLikeAnyValue() {
        assertEquals(
            "echo 'x; id'",
            ScriptParams.fill("echo {{host.name}}", emptyMap(), Shell.Posix, web.copy(name = "x; id")),
        )
        val error = assertThrows(ScriptParams.UnsafeValueException::class.java) {
            ScriptParams.fill("echo {{host.name}}", emptyMap(), Shell.Windows, web.copy(name = "50% off"))
        }
        assertEquals("host.name", error.param)
        assertEquals("a group-less host gives an empty word", "echo ''", ScriptParams.fill("echo {{host.group}}", emptyMap(), Shell.Posix, web.copy(group = "")))
    }

    @Test
    fun aValueWrittenLikeAHostVariableStaysThatText() {
        assertEquals(
            "echo '{{host.name}}' 'web 1'",
            ScriptParams.fill("echo {{msg}} {{host.name}}", mapOf("msg" to "{{host.name}}"), Shell.Posix, web),
        )
    }

    @Test
    fun withoutAHostOrForAnUnknownNameAHostVariableIsLeftAsWritten() {
        assertEquals("echo {{host.name}} 1", ScriptParams.fill("echo {{host.name}} {{n}}", mapOf("n" to "1"), Shell.Posix))
        assertEquals("echo {{host.addr}} {{host.Name}}", ScriptParams.fill("echo {{host.addr}} {{host.Name}}", emptyMap(), Shell.Posix, web))
        assertFalse(ScriptParams.usesHostVars("echo {{host.addr}}"))
        // A placeholder called host is still the user's own.
        assertEquals(listOf(ScriptParams.Param("host", "")), ScriptParams.parse("ping {{host}}"))
        assertEquals("ping db", ScriptParams.fill("ping {{host}}", mapOf("host" to "db"), Shell.Posix, web))
    }

    /** The quoted value reaches a real sh as exactly the text that was typed. */
    @Test
    fun aRealShellReceivesTheValueUnchanged() {
        assumeTrue("needs sh", TestShell.sh != null)
        val tricky = listOf("plain", "two words", "it's", "\$HOME `id` \$(id)", "a;b|c&d>e", "tab\there", "line\nbreak", "ünï", "")
        tricky.forEach { value ->
            val command = ScriptParams.fill("printf '[%s]' {{v}}", mapOf("v" to value), Shell.Posix)
            assertEquals(value, "[$value]", TestShell.run(command, timeoutSeconds = 10).output)
        }
    }
}
