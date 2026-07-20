package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.TuiScrollRouter
import com.jetsetslow.omniterm.ui.TuiScrollRouter.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The touch-scroll router that decides whether a tail gesture pages a full-screen TUI
 * (PageUp/PageDown) or scrolls the local buffer. Pure state machine — see TuiScrollRouter.
 */
class TuiScrollRouterTest {

    private val pagePx = 100f

    @Test
    fun firstDeltaBuffersAndMarksPending() {
        val router = TuiScrollRouter()
        assertTrue(router.isIdle)
        val action = router.onDelta(40f, pagePx)
        assertEquals(Action.Buffered, action)
        assertTrue(router.awaitingResolution)
        assertFalse(router.isIdle)
    }

    @Test
    fun localResolutionReplaysAllBufferedPixels() {
        val router = TuiScrollRouter()
        router.onDelta(40f, pagePx)
        router.onDelta(25f, pagePx)
        val action = router.resolve(tuiActive = false, pagePx = pagePx)
        assertEquals(Action.Local(65f), action)
        // Subsequent deltas pass straight through on the local route.
        assertEquals(Action.Local(10f), router.onDelta(10f, pagePx))
    }

    @Test
    fun tuiResolutionConvertsBufferedDragIntoPages() {
        val router = TuiScrollRouter()
        router.onDelta(150f, pagePx) // 1.5 pages pulled down = older = PageUp
        router.onDelta(100f, pagePx) // 2.5 total
        val action = router.resolve(tuiActive = true, pagePx = pagePx)
        assertEquals(Action.Pages(up = true, count = 2), action)
        assertTrue(router.routedToTui)
        // The 0.5-page remainder carries into the next delta.
        assertEquals(Action.Pages(up = true, count = 1), router.onDelta(50f, pagePx))
    }

    @Test
    fun tuiRouteEmitsPageDownForUpwardDrags() {
        val router = TuiScrollRouter()
        router.onDelta(-10f, pagePx)
        router.resolve(tuiActive = true, pagePx = pagePx)
        val action = router.onDelta(-95f, pagePx) // -105 total = one PageDown
        assertEquals(Action.Pages(up = false, count = 1), action)
    }

    @Test
    fun subPageDeltasAccumulateWithoutEmitting() {
        val router = TuiScrollRouter()
        router.onDelta(10f, pagePx)
        router.resolve(tuiActive = true, pagePx = pagePx)
        assertEquals(Action.Pages(up = true, count = 0), router.onDelta(30f, pagePx))
        assertEquals(Action.Pages(up = true, count = 0), router.onDelta(30f, pagePx))
        // 10+30+30+40 = 110 -> one page, 10 remainder
        assertEquals(Action.Pages(up = true, count = 1), router.onDelta(40f, pagePx))
    }

    @Test
    fun directionReversalCancelsRemainderBeforePaging() {
        val router = TuiScrollRouter()
        router.onDelta(60f, pagePx)
        router.resolve(tuiActive = true, pagePx = pagePx)
        // Reverse: 60 - 60 = 0 accumulated; nothing should fire.
        assertEquals(Action.Pages(up = true, count = 0), router.onDelta(-60f, pagePx))
        assertEquals(Action.Pages(up = false, count = 1), router.onDelta(-100f, pagePx))
    }

    @Test
    fun singleEventPageBurstIsCapped() {
        val router = TuiScrollRouter()
        router.onDelta(1_000f, pagePx) // a violent fling worth 10 pages
        val action = router.resolve(tuiActive = true, pagePx = pagePx)
        assertEquals(Action.Pages(up = true, count = 3), action)
    }

    @Test
    fun resetReturnsToIdleAndDropsState() {
        val router = TuiScrollRouter()
        router.onDelta(80f, pagePx)
        router.reset()
        assertTrue(router.isIdle)
        // A fresh gesture buffers again rather than inheriting the old 80px.
        assertEquals(Action.Buffered, router.onDelta(10f, pagePx))
        assertEquals(Action.Pages(up = true, count = 0), router.resolve(tuiActive = true, pagePx = pagePx))
    }

    @Test
    fun resolveWithoutPendingGestureIsANoOp() {
        val router = TuiScrollRouter()
        val action = router.resolve(tuiActive = true, pagePx = pagePx)
        assertEquals(Action.Pages(up = true, count = 0), action)
        assertTrue(router.isIdle)
    }

    @Test
    fun degeneratePagePxNeverDividesByZero() {
        val router = TuiScrollRouter()
        router.onDelta(5f, 0f)
        val action = router.resolve(tuiActive = true, pagePx = 0f)
        // pagePx clamps to 1px: 5px = 5 pages, capped at 3.
        assertEquals(Action.Pages(up = true, count = 3), action)
    }
}
