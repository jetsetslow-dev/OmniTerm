package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The terminal viewport's scroll state machine, extracted from [ShellScreen] so the one part of
 * the terminal UI that has repeatedly regressed (drag/fling anchoring, tail-follow, jump, scroll
 * re-anchoring after a history swap) is a plain testable class instead of remembered state
 * scattered through a composable.
 *
 * Invariants it owns:
 *  - While [followTail] is true the viewport pins to the newest rows on every content change.
 *  - Scrolling up detaches from the tail; scrolling back to the very bottom re-attaches.
 *  - Sub-row drag deltas accumulate in a pixel remainder so slow drags still move rows.
 *  - Fling consumption is honest: at either boundary the delta is reported unconsumed (0) so a
 *    fling decays and stops instead of appearing to scroll forever (the old "jump to oldest on
 *    short swipe" bug came from unconditional consumption).
 *  - A scrollback swap (tmux history re-sync) shifts the anchor by the row delta so the content
 *    under the user's finger stays stationary.
 */
@Stable
class TerminalViewportState {
    var firstVisibleRow by mutableStateOf(0)
        private set
    var followTail by mutableStateOf(true)
        private set
    private var remainderPx = 0f

    /** True once the user has scrolled up off the live tail (drives the jump-to-bottom control). */
    val scrolledUp: Boolean get() = !followTail

    private fun maxFirst(totalRows: Int, visibleRows: Int) = (totalRows - visibleRows).coerceAtLeast(0)

    /**
     * Re-anchor after the snapshot or the visible row count changed: keep pinning the tail while
     * following it, otherwise clamp the current position into the new valid range.
     */
    fun onContentChanged(totalRows: Int, visibleRows: Int) {
        val max = maxFirst(totalRows, visibleRows)
        firstVisibleRow = if (followTail) max else firstVisibleRow.coerceIn(0, max)
    }

    /**
     * Consume a scroll delta (px). deltaPx > 0 = content pulled down = revealing older rows.
     * Returns the consumed amount for the scrollable: the full delta when movement is possible,
     * 0 at a boundary so flings decay honestly. [onRowsScrolled] fires only when the viewport
     * actually moved by at least one row (used to publish the viewport without waiting a frame).
     */
    fun consumeScroll(
        deltaPx: Float,
        cellHeightPx: Float,
        totalRows: Int,
        visibleRows: Int,
        onRowsScrolled: () -> Unit = {},
    ): Float {
        val max = maxFirst(totalRows, visibleRows)
        val atOldest = firstVisibleRow <= 0
        val atTail = firstVisibleRow >= max
        if ((deltaPx > 0 && atOldest) || (deltaPx < 0 && atTail)) return 0f
        val rawRows = (remainderPx - deltaPx) / cellHeightPx.coerceAtLeast(1f)
        val rowDelta = rawRows.toInt()
        remainderPx = (rawRows - rowDelta) * cellHeightPx.coerceAtLeast(1f)
        if (rowDelta != 0) {
            firstVisibleRow = (firstVisibleRow + rowDelta).coerceIn(0, max)
            followTail = firstVisibleRow == max
            onRowsScrolled()
        }
        return deltaPx
    }

    /**
     * Snap to the live tail (jump-to-bottom). The caller must stop any in-flight fling first —
     * its remaining deltas would otherwise land after the jump and drag the viewport back off
     * the tail. Returns the new first visible row for immediate publishing.
     */
    fun jumpToTail(totalRows: Int, visibleRows: Int): Int {
        remainderPx = 0f
        followTail = true
        firstVisibleRow = maxFirst(totalRows, visibleRows)
        return firstVisibleRow
    }

    /**
     * Shift the anchor after a scrollback swap changed the total row count (tmux history
     * re-sync), keeping the rows in view stationary. Only meaningful while scrolled up.
     */
    fun applyRowDelta(delta: Int) {
        if (delta != 0) firstVisibleRow = (firstVisibleRow + delta).coerceAtLeast(0)
    }
}
