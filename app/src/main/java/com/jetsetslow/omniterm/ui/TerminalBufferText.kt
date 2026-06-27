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
fun dropBoundaryDuplication(lines: List<String>, boundary: Int): List<String> {
    if (boundary <= 0 || boundary >= lines.size) return lines

    // tmux repaints often leave a run of blank pane-padding lines between the replayed copy and the
    // live screen, so the duplicate isn't always flush against the boundary. Treat that trailing
    // blank run as part of the screen region for matching purposes: anchor the comparison at the
    // last non-blank scrollback row (`scrollEnd`) rather than at `boundary` itself. The blank gap
    // is preserved in the output — only the duplicated *content* block is dropped.
    var scrollEnd = boundary
    while (scrollEnd > 0 && lines[scrollEnd - 1].isBlank()) scrollEnd--
    if (scrollEnd <= 0) return lines

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
    if (best == 0) return lines
    // Drop the duplicated block but keep any blank gap (lines[scrollEnd until boundary]) intact.
    return lines.subList(0, scrollEnd - best) + lines.subList(scrollEnd, lines.size)
}
