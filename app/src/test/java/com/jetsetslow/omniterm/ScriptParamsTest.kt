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
import java.io.File
import java.util.concurrent.TimeUnit

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

    /** The quoted value reaches a real sh as exactly the text that was typed. */
    @Test
    fun aRealShellReceivesTheValueUnchanged() {
        val sh = File("/bin/sh")
        assumeTrue("needs /bin/sh", sh.canExecute())
        val tricky = listOf("plain", "two words", "it's", "\$HOME `id` \$(id)", "a;b|c&d>e", "tab\there", "line\nbreak", "ünï", "")
        tricky.forEach { value ->
            val command = ScriptParams.fill("printf '[%s]' {{v}}", mapOf("v" to value), Shell.Posix)
            val process = ProcessBuilder(sh.path, "-c", command).redirectErrorStream(true).start()
            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
            assertEquals(value, "[$value]", process.inputStream.readBytes().toString(Charsets.UTF_8))
        }
    }
}
