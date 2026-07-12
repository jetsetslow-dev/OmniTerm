package com.jetsetslow.omniterm.ui

/**
 * Pure helpers for turning a terminal snapshot into copyable text. Kept free of Android/JSch deps so
 * the de-duplication logic is unit-testable in plain JVM tests.
 */

/**
 * Remove the longest run at the end of the captured-scrollback region (`lines[0 until boundary]`)
 * that exactly matches the run at the start of the live-screen region (`lines[boundary until end]`).
 *
 * Why: tmux and other full-screen apps we capture scrollback from often replay the visible pane
 * right after a scroll, so the tail of captured scrollback repeats the head of the live screen
 * verbatim — which made the "Full buffer" copy show duplicated content. This collapses only that
 * exact overlap at the scrollback↔screen boundary; genuinely repeated output elsewhere is untouched.
 *
 * The overlap must contain at least one non-blank line to count, so runs of blank padding (which are
 * legitimately part of both regions) are never collapsed.
 */
fun dropBoundaryDuplication(lines: List<String>, boundary: Int): List<String> =
    dropBoundaryDuplication(lines, boundary) { it }

/**
 * Generic variant: rows of any type, compared via [text]. Lets the caller de-duplicate a list of
 * rendered terminal rows (keeping per-row metadata like soft-wrap flags) with the same textual
 * overlap rule as the plain-string version above.
 */
fun <T> dropBoundaryDuplication(rows: List<T>, boundary: Int, text: (T) -> String): List<T> {
    val lines = rows.map(text)
    if (boundary <= 0 || boundary >= lines.size) return rows

    // tmux repaints often leave a run of blank pane-padding lines between the replayed copy and the
    // live screen, so the duplicate isn't always flush against the boundary. Treat that trailing
    // blank run as part of the screen region for matching purposes: anchor the comparison at the
    // last non-blank scrollback row (`scrollEnd`) rather than at `boundary` itself. The blank gap
    // is preserved in the output — only the duplicated *content* block is dropped.
    var scrollEnd = boundary
    while (scrollEnd > 0 && lines[scrollEnd - 1].isBlank()) scrollEnd--
    if (scrollEnd <= 0) return rows

    val maxOverlap = minOf(scrollEnd, lines.size - boundary)
    var best = 0
    for (len in maxOverlap downTo 1) {
        var match = true
        for (i in 0 until len) {
            if (lines[scrollEnd - len + i] != lines[boundary + i]) { match = false; break }
        }
        // The overlap must carry real content (not just blank padding) to count, so legitimate
        // runs of blank lines that appear in both regions are never collapsed.
        if (match && (scrollEnd - len until scrollEnd).any { lines[it].isNotBlank() }) { best = len; break }
    }
    if (best == 0) return rows
    // Drop the duplicated block but keep any blank gap (rows[scrollEnd until boundary]) intact.
    return rows.subList(0, scrollEnd - best) + rows.subList(scrollEnd, rows.size)
}

/**
 * Join rendered terminal rows back into copyable text. Rows flagged [TermRow.softWrap] continue on
 * the next row (the text only broke because it hit the right edge), so they're concatenated without
 * a line break — copying a long word-wrapped command yields one logical line, not one line per
 * visual row. Hard line breaks (unflagged rows) still become newlines; each logical line is
 * right-trimmed since grid padding cells aren't real content.
 */
/**
 * The logical line containing visual row [rowIdx], rebuilt by joining the run of soft-wrapped
 * rows around it, plus the offset of [rowIdx]'s column 0 within that joined text. Lets tap-to-open
 * resolve a URL that wraps across visual rows: match against the logical line, tap column =
 * offset + column. Best effort — a wrap run cut off by the snapshot's edge joins only the rows
 * that are present. Returns null when [rowIdx] is out of bounds.
 */
fun logicalLineAt(rows: List<com.jetsetslow.omniterm.data.term.TermRow>, rowIdx: Int): Pair<String, Int>? {
    if (rowIdx !in rows.indices) return null
    var start = rowIdx
    while (start > 0 && rows[start - 1].softWrap) start--
    var end = rowIdx
    while (end < rows.size - 1 && rows[end].softWrap) end++
    val sb = StringBuilder()
    var offset = 0
    for (i in start..end) {
        if (i == rowIdx) offset = sb.length
        sb.append(rows[i].spans.joinToString("") { it.text })
    }
    return sb.toString() to offset
}

/** Map a visual terminal column to a UTF-16 text index, accounting for wide/combined glyphs. */
fun terminalColumnToTextIndex(
    row: com.jetsetslow.omniterm.data.term.TermRow,
    targetColumn: Int,
): Int {
    if (targetColumn <= 0) return 0
    var terminalColumn = 0
    var textIndex = 0
    for (span in row.spans) {
        val glyphs = if (span.glyphs.isNotEmpty()) span.glyphs else
            span.text.codePoints().toArray().map { String(Character.toChars(it)) }
        val widths = if (span.glyphWidths.size == glyphs.size) span.glyphWidths else List(glyphs.size) { 1 }
        for (index in glyphs.indices) {
            val nextColumn = terminalColumn + widths[index].coerceIn(1, 2)
            if (targetColumn < nextColumn) return textIndex
            terminalColumn = nextColumn
            textIndex += glyphs[index].length
        }
    }
    return textIndex
}

fun joinRowsRespectingWraps(rows: List<com.jetsetslow.omniterm.data.term.TermRow>): String {
    val lines = ArrayList<String>(rows.size)
    val current = StringBuilder()
    for (row in rows) {
        current.append(row.spans.joinToString("") { it.text })
        if (!row.softWrap) {
            lines.add(current.toString().trimEnd(' '))
            current.setLength(0)
        }
    }
    if (current.isNotEmpty()) lines.add(current.toString().trimEnd(' '))
    return lines.joinToString("\n").trimEnd('\n')
}
