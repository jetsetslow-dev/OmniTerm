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
    val maxOverlap = minOf(boundary, lines.size - boundary)
    var best = 0
    for (len in maxOverlap downTo 1) {
        var match = true
        for (i in 0 until len) {
            if (lines[boundary - len + i] != lines[boundary + i]) { match = false; break }
        }
        if (match && (boundary - len until boundary).any { lines[it].isNotBlank() }) { best = len; break }
    }
    if (best == 0) return lines
    return lines.subList(0, boundary - best) + lines.subList(boundary, lines.size)
}
