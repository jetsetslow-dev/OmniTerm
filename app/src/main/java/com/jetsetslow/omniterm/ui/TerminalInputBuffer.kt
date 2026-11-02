package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.text.input.TextFieldValue

/**
 * What the terminal's hidden input field holds in its own edit buffer, which is what the next
 * keyboard edit is applied to.
 *
 * Compose's text field applies an edit to that buffer and reports the result through onValueChange,
 * but takes the value handed back only when it next recomposes, a frame later. Keys that arrive
 * within one frame (a hardware keyboard, a fast typist, `adb shell input text`) are applied on top
 * of text already sent. Diffing them against the field's own state sent that text again, so
 * `echo abc` reached the shell as `eecechoo aab…`. Diffing against [text] sends each key once.
 */
internal class TerminalInputBuffer {
    /** The buffer's text: the last edit reported, until the field takes the value it was handed. */
    var text = ""
        private set

    /** Bumped by every edit, so [TrackFieldValueTaken] recomposes in the frame the field does. */
    internal val edits = mutableIntStateOf(0)

    /** Records [edited] as the buffer's text; returns what the buffer held before the edit. */
    fun onEdit(edited: String): String {
        val before = text
        text = edited
        edits.intValue++
        return before
    }

    internal fun taken(value: String) {
        text = value
    }
}

/**
 * The [TerminalInputBuffer] of a hidden field showing [field]'s value; [key] starts a new one (a new
 * field, with an empty buffer).
 *
 * The field resets its buffer to the value it is handed while it recomposes after each edit. This
 * records that in the same frame, after composition and before any further key is handled.
 */
@Composable
internal fun rememberTerminalInputBuffer(key: Any?, field: State<TextFieldValue>): TerminalInputBuffer {
    val buffer = remember(key) { TerminalInputBuffer() }
    TrackFieldValueTaken(buffer, field)
    return buffer
}

/** Its own scope, so an edit recomposes only this and not the terminal around it. */
@Composable
private fun TrackFieldValueTaken(buffer: TerminalInputBuffer, field: State<TextFieldValue>) {
    buffer.edits.intValue
    val value = field.value.text
    SideEffect { buffer.taken(value) }
}
