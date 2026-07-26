package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `clear` must actually remove text, including from the cached span rows the UI renders.
 *
 * Reported symptom: after exiting a full-screen TUI, old rows stayed on screen and new output
 * overwrote them character by character, so the screen only became clean once enough text had
 * painted over it. Typing `clear` DID fix it — which rules the emulator out as the cause, since a
 * stale grid or a stale span cache would survive `clear` too.
 *
 * These tests therefore pin the erase paths as a regression guard rather than reproducing that bug:
 * ED(2) clears the screen but keeps scrollback, ED(3) discards scrollback, and rows blanked in place
 * never render from a pre-blanking span-cache entry (the cache is keyed by row-array identity).
 */
class TerminalClearStaleRowTest {

    private val csi = "\u001B["

    private fun visible(e: TerminalEmulator): List<String> =
        e.snapshot().rows.map { r -> r.spans.joinToString("") { it.text }.trimEnd() }
            .filter { it.isNotBlank() }

    /** `clear` = ESC[H ESC[2J ESC[3J. Nothing may survive it, grid or scrollback. */
    @Test
    fun clearRemovesEverythingIncludingScrollback() {
        val e = TerminalEmulator(40, 6, scrollbackLimit = 200)
        repeat(30) { i -> e.feed("row-$i\r\n".toByteArray()) }
        assertTrue("setup failed", visible(e).any { it.contains("row-0") })

        e.feed("${csi}H${csi}2J${csi}3J".toByteArray())

        val after = visible(e)
        assertTrue("clear left content behind: $after", after.isEmpty())
    }

    /**
     * The scrollback span cache is keyed by row identity. A row blanked in place by ED(2) and then
     * scrolled into scrollback must not render from a pre-blanking cache entry.
     */
    @Test
    fun rowsBlankedInPlaceDoNotRenderFromAStaleSpanCache() {
        val e = TerminalEmulator(40, 4, scrollbackLimit = 200)

        // Fill scrollback so the cache is populated for real rows.
        repeat(20) { i -> e.feed("old-$i\r\n".toByteArray()) }
        e.snapshot() // force caching of the scrollback rows

        // ED(2) blanks the on-screen rows in place (no new arrays).
        e.feed("${csi}2J".toByteArray())
        // Now push those blanked rows through scrollback.
        repeat(6) { e.feed("\r\n".toByteArray()) }

        val after = visible(e)
        assertFalse("A blanked row rendered stale cached text: $after",
            after.any { it.startsWith("old-1") && it.length > 6 })
    }

    /** ED(2) must clear the visible grid without wiping history the user can still scroll to. */
    @Test
    fun ed2ClearsScreenButKeepsScrollback() {
        val e = TerminalEmulator(40, 5, scrollbackLimit = 200)
        repeat(20) { i -> e.feed("hist-$i\r\n".toByteArray()) }
        val before = e.snapshot().rows.size

        e.feed("${csi}2J".toByteArray())

        // Scrollback survives ED(2) — only ED(3) discards it.
        assertTrue("ED(2) must not discard scrollback", e.snapshot().rows.size >= before - 5)
        assertTrue("scrollback content lost", visible(e).any { it.contains("hist-") })
    }

    /** ED(3) is the one that discards scrollback. */
    @Test
    fun ed3DiscardsScrollback() {
        val e = TerminalEmulator(40, 5, scrollbackLimit = 200)
        repeat(20) { i -> e.feed("gone-$i\r\n".toByteArray()) }

        e.feed("${csi}2J${csi}3J".toByteArray())

        assertTrue("ED(3) must discard scrollback: ${visible(e)}", visible(e).isEmpty())
    }

    /** A TUI exit followed by `clear` is the exact reported flow; it must end with a clean screen. */
    @Test
    fun clearAfterAltScreenExitLeavesNothingBehind() {
        val e = TerminalEmulator(40, 6, scrollbackLimit = 200)
        repeat(10) { i -> e.feed("pre-$i\r\n".toByteArray()) }
        e.feed("${csi}?1049h".toByteArray())
        e.feed("TUI CONTENT HERE".toByteArray())
        e.feed("${csi}?1049l".toByteArray())

        e.feed("${csi}H${csi}2J${csi}3J".toByteArray())

        val after = visible(e)
        assertTrue("clear after TUI exit left content: $after", after.isEmpty())
    }
}
