package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.TerminalViewportState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The terminal viewport state machine, extracted from ShellScreen because drag/fling anchoring
 * regressed repeatedly while it lived inline in the composable. Cell height 10px throughout.
 */
class TerminalViewportStateTest {

    private fun tailFollowing(totalRows: Int = 100, visibleRows: Int = 20) =
        TerminalViewportState().apply { onContentChanged(totalRows, visibleRows) }

    @Test
    fun followsTailWhileAttached() {
        val v = tailFollowing(totalRows = 100, visibleRows = 20)
        assertEquals(80, v.firstVisibleRow)
        v.onContentChanged(150, 20) // new output arrives
        assertEquals(130, v.firstVisibleRow)
        assertTrue(v.followTail)
        assertFalse(v.scrolledUp)
    }

    @Test
    fun scrollingUpDetachesFromTail() {
        val v = tailFollowing()
        // +100px content pull-down = 10 rows toward older content.
        val consumed = v.consumeScroll(100f, 10f, 100, 20)
        assertEquals(100f, consumed)
        assertEquals(70, v.firstVisibleRow)
        assertTrue(v.scrolledUp)
        // New output must NOT yank the viewport back to the tail while scrolled up.
        v.onContentChanged(200, 20)
        assertEquals(70, v.firstVisibleRow)
    }

    @Test
    fun scrollingBackToBottomReattachesTail() {
        val v = tailFollowing()
        v.consumeScroll(100f, 10f, 100, 20)   // up 10 rows
        v.consumeScroll(-100f, 10f, 100, 20)  // back down 10 rows
        assertEquals(80, v.firstVisibleRow)
        assertTrue(v.followTail)
    }

    @Test
    fun subRowDeltasAccumulateInRemainder() {
        val v = tailFollowing()
        // Three 4px drags at 10px cells: no movement, no movement, then one row.
        v.consumeScroll(4f, 10f, 100, 20)
        assertEquals(80, v.firstVisibleRow)
        v.consumeScroll(4f, 10f, 100, 20)
        assertEquals(80, v.firstVisibleRow)
        v.consumeScroll(4f, 10f, 100, 20)
        assertEquals(79, v.firstVisibleRow)
    }

    @Test
    fun boundaryConsumptionIsHonest() {
        val v = tailFollowing()
        // At the tail, further downward scroll is unconsumed so a fling decays.
        assertEquals(0f, v.consumeScroll(-50f, 10f, 100, 20))
        // Scroll all the way to the oldest row; upward scroll is then unconsumed too.
        v.consumeScroll(10_000f, 10f, 100, 20)
        assertEquals(0, v.firstVisibleRow)
        assertEquals(0f, v.consumeScroll(50f, 10f, 100, 20))
        // But downward from the oldest row still consumes.
        assertEquals(-50f, v.consumeScroll(-50f, 10f, 100, 20))
    }

    @Test
    fun jumpToTailReattachesAndClearsRemainder() {
        val v = tailFollowing()
        v.consumeScroll(105f, 10f, 100, 20) // up 10 rows + 5px remainder
        assertEquals(80, v.jumpToTail(100, 20))
        assertTrue(v.followTail)
        // Remainder was cleared: a 5px drag after the jump moves nothing (5px < one row).
        v.consumeScroll(5f, 10f, 100, 20)
        assertEquals(80, v.firstVisibleRow)
    }

    @Test
    fun rowDeltaShiftsAnchorAfterHistorySwap() {
        val v = tailFollowing()
        v.consumeScroll(100f, 10f, 100, 20) // scrolled up to row 70
        // tmux re-sync grows scrollback by 500 rows; the same content is now 500 rows lower.
        v.applyRowDelta(500)
        assertEquals(570, v.firstVisibleRow)
        // A shrinking swap can't push the anchor negative.
        v.applyRowDelta(-1000)
        assertEquals(0, v.firstVisibleRow)
    }

    @Test
    fun capTrimDriftShiftsAnchorSoContentStaysStationary() {
        val v = tailFollowing()
        v.consumeScroll(100f, 10f, 100, 20) // scrolled up to row 70
        // Streaming output at the scrollback cap trimmed 7 head rows: the same content now sits
        // 7 indices earlier, so the anchor must move back with it instead of sliding tailward.
        v.applyRowDelta(-7)
        assertEquals(63, v.firstVisibleRow)
        assertTrue(v.scrolledUp)
    }

    @Test
    fun contentShrinkClampsScrolledUpViewport() {
        val v = tailFollowing()
        v.consumeScroll(100f, 10f, 100, 20)
        v.onContentChanged(30, 20) // e.g. clear-scrollback while scrolled up
        assertEquals(10, v.firstVisibleRow)
    }
}
