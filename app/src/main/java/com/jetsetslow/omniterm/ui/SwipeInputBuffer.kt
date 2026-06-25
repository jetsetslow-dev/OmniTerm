package com.jetsetslow.omniterm.ui

/**
 * Pure, UI-free logic for the terminal's "smart swipe" soft-keyboard input.
 *
 * The terminal's hidden [androidx.compose.foundation.text.BasicTextField] is the only thing a
 * gesture keyboard can revise. The strict path keeps that field empty after every commit so
 * autocorrect can never replace against stale text — but an empty field also gives the keyboard
 * zero context, so swiped words come through raw and uncorrected, which is what made swipe-typing
 * feel like nonsense.
 *
 * This buffer lets the IME field *accumulate the current word* so the keyboard can self-correct it,
 * and flushes completed words to the terminal as soon as a boundary (space / newline / punctuation)
 * appears in the value. Only the still-incomplete trailing word is kept in the field.
 *
 * Guards mirror the hard-won invariants from the original empty-buffer fix:
 *  - The field only ever holds a single trailing word with no whitespace. As soon as whitespace or a
 *    non-letter/digit appears it is flushed out, so a composing/autocorrect diff can never span a
 *    word — let alone a line — boundary and fire stray backspaces at the remote.
 *  - Pastes and multi-segment commits are flushed in one go; we never re-diff across a flush.
 *  - [reset] (newline, control keys, focus loss, paste) abandons the held word so nothing leaks
 *    across a context the user clearly ended.
 *
 * The caller displays [Result.fieldText] in the field and sends [Result.emit] to the terminal.
 */
class SwipeInputBuffer {
    /** The trailing, still-incomplete word held in the IME field (never contains whitespace). */
    private var held: String = ""

    val pendingWord: String get() = held

    data class Result(
        /** Text to send to the terminal now (may be empty). Includes inter-word separators. */
        val emit: String,
        /** What the IME field should be set to after this transition. */
        val fieldText: String,
    )

    /** Abandon any half-typed word. Call on newline commit, control keys, paste, or focus loss. */
    fun reset() { held = "" }

    /**
     * Process a new IME field value [value] (the field's text after the keyboard's edit).
     *
     * The boundary rule: everything up to and including the last word-separator (any char that is not
     * a letter or digit) is *complete* and gets emitted; the clean trailing run after it stays in the
     * field as the word still being corrected. A value that is one clean word emits nothing and is
     * simply held. A value ending in a separator emits everything and clears the field.
     */
    fun onValue(value: String): Result {
        if (value.isEmpty()) {
            held = ""
            return Result(emit = "", fieldText = "")
        }

        // Find the last separator (non letter/digit). Text through it is finished; the rest is held.
        val lastSep = value.indexOfLast { !it.isLetterOrDigit() }
        if (lastSep < 0) {
            // One clean word with no separators in the field. Treat it as the latest in-place revision
            // of the word we're holding and keep it in the field so the keyboard can keep correcting
            // it — emit nothing yet.
            //
            // We deliberately do NOT try to detect "this is a brand-new word" from content: an
            // autocorrect like "teh"→"the" is a full replacement that shares no prefix, so any
            // prefix/length heuristic would mistake a correction for a new word and emit the
            // *uncorrected* text — the exact nonsense we're fixing. Modern gesture keyboards add their
            // own inter-word space (it arrives here as a separator and flushes cleanly), so the only
            // cost of always-continuation is that a rare field-clearing keyboard could run two words
            // together — strictly better than corrupting every autocorrect.
            held = value
            return Result(emit = "", fieldText = value)
        }

        val completed = value.substring(0, lastSep + 1)
        val trailing = value.substring(lastSep + 1)
        held = trailing
        return Result(emit = completed, fieldText = trailing)
    }

    /** Flush the held word with no trailing separator (e.g. on Enter, before sending the newline). */
    fun flushBare(): String {
        val out = held
        held = ""
        return out
    }
}
