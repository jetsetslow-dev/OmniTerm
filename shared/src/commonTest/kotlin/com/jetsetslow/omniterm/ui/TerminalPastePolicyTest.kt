package com.jetsetslow.omniterm.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The Android fixtures from `BracketedPastePayloadTest`, run against the shared implementation both
 * platforms now use.
 *
 * A trailing Enter must land OUTSIDE the bracketed-paste markers: inside them readline treats it as
 * a literal, so a pasted command was echoed at the prompt but never executed.
 */
class TerminalPastePolicyTest {
    private val esc = "\u001B"

    @Test
    fun unbracketedPasteIsUntouched() {
        assertEquals("echo hi\r", bracketedPastePayload("echo hi\r", bracketed = false))
    }

    @Test
    fun trailingEnterMovesOutsideTheBracket() {
        assertEquals("$esc[200~echo hi$esc[201~\r", bracketedPastePayload("echo hi\r", bracketed = true))
    }

    @Test
    fun multipleTrailingEntersAllMoveOutside() {
        assertEquals("$esc[200~echo hi$esc[201~\r\r", bracketedPastePayload("echo hi\r\r", bracketed = true))
    }

    @Test
    fun interiorNewlinesStayLiteralInsideTheBracket() {
        assertEquals("$esc[200~line1\rline2$esc[201~\r", bracketedPastePayload("line1\rline2\r", bracketed = true))
    }

    @Test
    fun pasteWithoutTrailingEnterStaysFullyBracketed() {
        assertEquals("$esc[200~partial line$esc[201~", bracketedPastePayload("partial line", bracketed = true))
    }

    @Test
    fun enterOnlyPasteBecomesARealEnter() {
        assertEquals("$esc[200~$esc[201~\r", bracketedPastePayload("\r", bracketed = true))
    }

    @Test
    fun onlyASingleImeEnterCommitCountsAsEnter() {
        assertTrue(isSingleTerminalEnter("\n"))
        assertTrue(isSingleTerminalEnter("\r"))
        assertTrue(isSingleTerminalEnter("\r\n"))
        assertFalse(isSingleTerminalEnter("\n\n"))
        assertFalse(isSingleTerminalEnter("ls\n"))
        assertFalse(isSingleTerminalEnter(""))
    }

    @Test
    fun codePointPrefixNeverSplitsASurrogatePair() {
        // Same emoji: the whole pair is common. Different emoji sharing a high surrogate: neither
        // half may be reported as common, or the delta would carry a lone surrogate.
        assertEquals(2, commonCodePointPrefixIndex("😀", "😀"))
        assertEquals(0, commonCodePointPrefixIndex("😀", "😁"))
        assertEquals(2, commonCodePointPrefixIndex("hi😀", "hi😁"))
        assertEquals(0, commonCodePointPrefixIndex("a", "😀"))
    }

    @Test
    fun insertedDeltaIgnoresSharedPrefixAndSuffix() {
        assertEquals(0, insertedCodePointDelta("ls -la", "ls -la"))
        assertEquals(4, insertedCodePointDelta("ls", "ls foo"))
        assertEquals(3, insertedCodePointDelta("cat x", "cat abcx"))
        // An emoji is one code point, not two chars.
        assertEquals(1, insertedCodePointDelta("hi", "hi😀"))
        // Deleting text inserts nothing, so a backspace can never be mistaken for a paste.
        assertEquals(0, insertedCodePointDelta("ls -la", "ls"))
    }

    @Test
    fun largeImeCommitsAreTreatedAsAPaste() {
        val typed = "ls -l"
        assertFalse(isLargePaste("", typed))
        assertFalse(isLargePaste("", "x".repeat(LARGE_PASTE_CODE_POINTS)))
        assertTrue(isLargePaste("", "x".repeat(LARGE_PASTE_CODE_POINTS + 1)))
        // Editing in the middle of a long line is not a paste: the shared affix is discounted.
        val long = "x".repeat(500)
        assertFalse(isLargePaste(long, long + "y"))
    }
}
