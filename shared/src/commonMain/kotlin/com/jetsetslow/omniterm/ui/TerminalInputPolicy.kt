package com.jetsetslow.omniterm.ui

/**
 * Read-only terminal input policy. Paging is the one thing a read-only viewer may still send: it
 * moves the remote pager's viewport without mutating anything, and blocking it would make a
 * read-only session unable to scroll a `less`/`man` page. Every other key — and all typed or pasted
 * text — is refused.
 */
fun terminalKeyAllowedInReadOnly(key: TermKey): Boolean =
    key == TermKey.PAGE_UP || key == TermKey.PAGE_DOWN

enum class TerminalClipboardPasteAction { EMPTY, BLOCKED_READ_ONLY, SEND, CONFIRM }

/**
 * What the explicit terminal paste button should do. Read-only wins over everything, an empty
 * clipboard is reported rather than silently sent, and anything past [confirmThreshold] characters
 * asks first — a long paste into a shell is how an accidental clipboard becomes a run command.
 */
fun terminalClipboardPasteAction(
    text: String?,
    readOnly: Boolean,
    confirmThreshold: Int = LARGE_PASTE_CODE_POINTS,
): TerminalClipboardPasteAction = when {
    readOnly -> TerminalClipboardPasteAction.BLOCKED_READ_ONLY
    text.isNullOrEmpty() -> TerminalClipboardPasteAction.EMPTY
    text.length > confirmThreshold -> TerminalClipboardPasteAction.CONFIRM
    else -> TerminalClipboardPasteAction.SEND
}

/**
 * A tmux history capture is safe to adopt only into the exact grid generation it observed. Columns,
 * rows, and the generation counter must all still match: a resize back to the original size is a
 * different grid than the one captured, and only the generation records that.
 */
fun terminalGeometryMatches(
    capturedCols: Int,
    capturedRows: Int,
    capturedGeneration: Long,
    currentCols: Int,
    currentRows: Int,
    currentGeneration: Long,
): Boolean = capturedCols == currentCols &&
    capturedRows == currentRows &&
    capturedGeneration == currentGeneration
