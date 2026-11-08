package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ssh.KeyboardInteractiveUserInfo
import com.jetsetslow.omniterm.data.ssh.bannerForTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** sshd's pre-sign-in banner reaches the terminal, and nothing in it can drive the terminal. */
class SshBannerTest {

    @Test
    fun theBannerJschShowsIsKept() {
        val info = KeyboardInteractiveUserInfo(password = null, ask = null)
        info.showMessage("Authorised access only.\n")
        info.showMessage("Maintenance tonight 22:00.")
        info.showMessage("   ")
        assertEquals("Authorised access only.\nMaintenance tonight 22:00.\n", info.banner)
    }

    @Test
    fun aHugeBannerIsCut() {
        val info = KeyboardInteractiveUserInfo(password = null, ask = null)
        repeat(3) { info.showMessage("x".repeat(KeyboardInteractiveUserInfo.MAX_BANNER_CHARS)) }
        assertTrue(info.banner.length <= KeyboardInteractiveUserInfo.MAX_BANNER_CHARS + 1)
    }

    @Test
    fun linesEndInCrLfForTheTerminal() {
        assertEquals("one\r\ntwo\r\n", bannerForTerminal("one\ntwo\n")!!.toString(Charsets.UTF_8))
        assertEquals("one\r\ntwo\r\n", bannerForTerminal("one\r\ntwo")!!.toString(Charsets.UTF_8))
    }

    @Test
    fun escapeSequencesAndControlCharactersAreRemoved() {
        // Clear screen, a window-title change and a bell: a host must not do these through its banner.
        val shown = bannerForTerminal("\u001b[2J\u001b]0;pwned\u0007Hello\u009b31m\tworld")!!.toString(Charsets.UTF_8)
        assertEquals("[2J]0;pwnedHello31m\tworld\r\n", shown)
        assertTrue(shown.none { it.code < 0x20 && it != '\r' && it != '\n' && it != '\t' })
    }

    @Test
    fun nonAsciiTextSurvives() {
        assertEquals("Zugang nur für Befugte\r\n", bannerForTerminal("Zugang nur für Befugte")!!.toString(Charsets.UTF_8))
    }

    @Test
    fun aBlankBannerShowsNothing() {
        assertNull(bannerForTerminal(""))
        assertNull(bannerForTerminal("\n\n\u001b"))
    }
}
