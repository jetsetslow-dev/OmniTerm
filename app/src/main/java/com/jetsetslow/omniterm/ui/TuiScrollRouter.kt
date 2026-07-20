package com.jetsetslow.omniterm.ui

/**
 * Routes touch-scroll gestures that start at the live tail of a terminal session.
 *
 * A plain shell scrolls the LOCAL buffer (scrollback exists locally). A full-screen TUI on the
 * pane's alternate screen has no terminal-side history at all — the app owns its own scrolling,
 * and the one thing virtually every TUI understands is PageUp/PageDown (pagers, editors,
 * interactive CLIs alike). So: while a TUI owns the pane, drags are converted into page-key
 * presses; otherwise the drag falls through to the local viewport.
 *
 * Which world we're in ("TUI or shell?") can require an asynchronous answer (a side-channel tmux
 * `#{alternate_on}` query for regular-attach sessions), so the router buffers the first deltas of
 * a gesture until [resolve] is called, then either replays them into the local scroll or converts
 * them into pages. Pure and synchronous by design — the caller owns timers and I/O — so the
 * regression-prone gesture math stays unit-testable (same rationale as [TerminalViewportState]).
 *
 * Sign convention matches [TerminalViewportState.consumeScroll]: deltaPx > 0 = content pulled
 * down = revealing older content = PageUp.
 */
class TuiScrollRouter {

    sealed interface Action {
        /** Routing unresolved: the delta was buffered; caller consumes the touch event. */
        object Buffered : Action

        /** Local-shell route: the caller feeds [deltaPx] into the local viewport scroll. */
        data class Local(val deltaPx: Float) : Action

        /** TUI route: send [count] PageUp ([up] = true) or PageDown presses. Zero count = consumed. */
        data class Pages(val up: Boolean, val count: Int) : Action
    }

    private enum class Route { IDLE, PENDING, TUI, LOCAL }

    private var route = Route.IDLE
    private var bufferedPx = 0f
    private var pageRemainderPx = 0f

    /** True while a gesture is being buffered waiting on [resolve]. */
    val awaitingResolution: Boolean get() = route == Route.PENDING

    /** True while the TUI route is active (drags page the remote app, not the local buffer). */
    val routedToTui: Boolean get() = route == Route.TUI

    /** True when no gesture is in flight — the next tail delta may start a new PENDING gesture. */
    val isIdle: Boolean get() = route == Route.IDLE

    /**
     * Feed one scroll delta. Call only for gestures the caller deems eligible (session connected,
     * gesture began at the live tail). [pagePx] is how many pixels of drag equal one page press.
     * The first delta of an idle router starts a PENDING gesture; the caller must then arrange
     * for [resolve] to be called (or [reset] on timeout/failure).
     */
    fun onDelta(deltaPx: Float, pagePx: Float): Action = when (route) {
        Route.IDLE -> {
            route = Route.PENDING
            bufferedPx = deltaPx
            pageRemainderPx = 0f
            Action.Buffered
        }
        Route.PENDING -> {
            bufferedPx += deltaPx
            Action.Buffered
        }
        Route.LOCAL -> Action.Local(deltaPx)
        Route.TUI -> emitPages(deltaPx, pagePx)
    }

    /**
     * Deliver the routing answer for the pending gesture. Returns the action for the buffered
     * deltas: replay into the local viewport, or an initial batch of page presses. No-op action
     * when nothing was pending (gesture already reset).
     */
    fun resolve(tuiActive: Boolean, pagePx: Float): Action {
        if (route != Route.PENDING) return Action.Pages(up = true, count = 0)
        val pending = bufferedPx
        bufferedPx = 0f
        return if (tuiActive) {
            route = Route.TUI
            emitPages(pending, pagePx)
        } else {
            route = Route.LOCAL
            Action.Local(pending)
        }
    }

    /** End of gesture (idle timeout), resolution failure, or session switch: back to square one. */
    fun reset() {
        route = Route.IDLE
        bufferedPx = 0f
        pageRemainderPx = 0f
    }

    private fun emitPages(deltaPx: Float, pagePx: Float): Action {
        val effectivePagePx = pagePx.coerceAtLeast(1f)
        pageRemainderPx += deltaPx
        var pages = 0
        while (pageRemainderPx >= effectivePagePx) {
            pageRemainderPx -= effectivePagePx
            pages++
        }
        while (pageRemainderPx <= -effectivePagePx) {
            pageRemainderPx += effectivePagePx
            pages--
        }
        return when {
            pages > 0 -> Action.Pages(up = true, count = pages.coerceAtMost(MAX_PAGES_PER_EVENT))
            pages < 0 -> Action.Pages(up = false, count = (-pages).coerceAtMost(MAX_PAGES_PER_EVENT))
            else -> Action.Pages(up = true, count = 0)
        }
    }

    private companion object {
        /** A single event never emits a burst that could blow past the target in the TUI. */
        const val MAX_PAGES_PER_EVENT = 3
    }
}
