package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.bracketedPastePayload
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A trailing Enter must land OUTSIDE the bracketed-paste markers: inside them readline treats it
 * as a literal, so a pasted command was echoed at the prompt but never executed (field report:
 * "typing/pasting stops working once the session has been open a few seconds" — i.e. once the
 * prompt's DECSET 2004 had been processed).
 */
class BracketedPastePayloadTest {
    private val esc = "\u001B"

    @Test
    fun unbracketedPasteIsUntouched() {
        assertEquals("echo hi\r", bracketedPastePayload("echo hi\r", bracketed = false))
    }

    @Test
    fun trailingEnterMovesOutsideTheBracket() {
        assertEquals(
            "$esc[200~echo hi$esc[201~\r",
            bracketedPastePayload("echo hi\r", bracketed = true),
        )
    }

    @Test
    fun multipleTrailingEntersAllMoveOutside() {
        assertEquals(
            "$esc[200~echo hi$esc[201~\r\r",
            bracketedPastePayload("echo hi\r\r", bracketed = true),
        )
    }

    @Test
    fun interiorNewlinesStayLiteralInsideTheBracket() {
        assertEquals(
            "$esc[200~line1\rline2$esc[201~\r",
            bracketedPastePayload("line1\rline2\r", bracketed = true),
        )
    }

    @Test
    fun pasteWithoutTrailingEnterStaysFullyBracketed() {
        assertEquals(
            "$esc[200~partial line$esc[201~",
            bracketedPastePayload("partial line", bracketed = true),
        )
    }

    @Test
    fun enterOnlyPasteBecomesARealEnter() {
        assertEquals("$esc[200~$esc[201~\r", bracketedPastePayload("\r", bracketed = true))
    }
}
