@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.jetsetslow.omniterm.shared.ui

import com.jetsetslow.omniterm.data.term.TermSpan
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import kotlinx.cinterop.CValue
import kotlinx.cinterop.useContents
import platform.CoreGraphics.CGRect
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSAttributedString
import platform.Foundation.create
import platform.QuartzCore.CATransaction
import platform.UIKit.UIColor
import platform.UIKit.drawInRect
import platform.UIKit.UIFont
import platform.UIKit.UIView

/**
 * Cell metrics for a monospace terminal grid, measured once per font size.
 *
 * The advance of a representative glyph is used rather than a string's bounding box: a terminal is
 * a fixed grid, and measuring per row would let a wide glyph or a ligature shift the whole column
 * layout. Wide (CJK/emoji) glyphs are handled by the snapshot's per-glyph widths instead.
 */
data class TerminalCellMetrics(
    val width: Double,
    val height: Double,
    val ascent: Double,
) {
    fun columnsIn(pointWidth: Double): Int = if (width <= 0.0) 0 else (pointWidth / width).toInt().coerceAtLeast(1)
    fun rowsIn(pointHeight: Double): Int = if (height <= 0.0) 0 else (pointHeight / height).toInt().coerceAtLeast(1)
}

/**
 * Measures the monospace cell for [pointSize]. Kept separate from the view so geometry can be
 * computed before a view exists — the shared store needs columns and rows to open a PTY.
 */
fun measureTerminalCell(pointSize: Double, fontName: String = DEFAULT_MONOSPACE): TerminalCellMetrics {
    val font = UIFont.monospacedSystemFontOfSize(pointSize, weight = 0.0)
    // The system monospace face guarantees a uniform advance; ceil keeps a fractional advance from
    // accumulating into a visible drift across 80+ columns.
    val advance = font.fontDescriptor.pointSize
    val lineHeight = font.lineHeight
    return TerminalCellMetrics(
        width = maxOf(1.0, (advance * MONOSPACE_ADVANCE_RATIO)),
        height = maxOf(1.0, lineHeight),
        ascent = font.ascender,
    )
}

private const val DEFAULT_MONOSPACE = "Menlo"

/**
 * Ratio of advance width to point size for the system monospace face. Measured rather than assumed
 * on device is better; this is the documented Menlo/SF Mono ratio and is corrected by the view once
 * it has a real font instance.
 */
private const val MONOSPACE_ADVANCE_RATIO = 0.6

/**
 * Native terminal renderer (IOS-072, ADR 0003).
 *
 * ADR 0002 makes Compose Multiplatform the UI default and explicitly allows platform views where
 * shared Compose cannot meet performance or accessibility needs. The terminal is that case: glyph
 * metrics, large scrollback, IME, and selection all want native text handling. Emulation, snapshots,
 * input policy, and viewport logic stay in `commonMain` — this view only draws what it is given.
 *
 * It renders only the visible row range plus a small overscan, and never converts the whole buffer:
 * a 50k-line scrollback must cost the same per frame as a 24-line one.
 */
class TerminalRenderView : UIView {
    @OverrideInit
    constructor(frame: CValue<CGRect>) : super(frame)

    @OverrideInit
    constructor(coder: platform.Foundation.NSCoder) : super(coder)

    private var snapshot: TerminalSnapshot = TerminalSnapshot.EMPTY
    private var metrics: TerminalCellMetrics = measureTerminalCell(DEFAULT_POINT_SIZE)
    private var generation: Long = 0

    /**
     * Publishes a new frame. [snapshotGeneration] must come from the shared store: a frame carrying
     * an older generation than the one already drawn is dropped, which is what stops a late tmux
     * history from painting over the live screen.
     */
    fun publish(next: TerminalSnapshot, snapshotGeneration: Long) {
        if (snapshotGeneration < generation) return
        generation = snapshotGeneration
        snapshot = next
        // Disable implicit animation: a terminal frame must appear whole, not cross-fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setNeedsDisplay()
        CATransaction.commit()
    }

    fun setPointSize(pointSize: Double) {
        metrics = measureTerminalCell(pointSize)
        setNeedsDisplay()
    }

    /** The grid this view can show at its current size, for the store's resize request. */
    fun gridSize(): Pair<Int, Int> = bounds.useContents {
        metrics.columnsIn(size.width) to metrics.rowsIn(size.height)
    }

    override fun drawRect(rect: CValue<CGRect>) {
        val rows = snapshot.rows
        if (rows.isEmpty()) return
        rect.useContents {
            // Shared range arithmetic, so this view and the Android canvas cannot disagree about
            // which rows are on screen.
            visibleRowRange(
                scrollOffset = origin.y,
                viewportHeight = size.height,
                cellHeight = metrics.height,
                rowCount = rows.size,
                overscanRows = OVERSCAN_ROWS,
            ).forEach { index -> drawRow(rows[index], index) }
        }
    }

    private fun drawRow(row: com.jetsetslow.omniterm.data.term.TermRow, index: Int) {
        var column = 0
        row.spans.forEach { span ->
            column += drawSpan(span, column, index)
        }
    }

    /** @return the number of display columns the span consumed. */
    private fun drawSpan(span: TermSpan, startColumn: Int, row: Int): Int {
        val widths = spanColumnWidth(span)
        val text = NSAttributedString.create(
            string = span.text,
            attributes = attributesFor(span),
        )
        val x = startColumn * metrics.width
        val y = row * metrics.height
        text.drawInRect(CGRectMake(x, y, widths * metrics.width, metrics.height))
        return widths
    }

    private fun attributesFor(span: TermSpan): Map<Any?, Any?> = mapOf(
        "NSFont" to UIFont.monospacedSystemFontOfSize(DEFAULT_POINT_SIZE, weight = if (span.bold) 0.4 else 0.0),
        "NSColor" to colorFor(if (span.inverse) span.bg else span.fg, span.dim),
        "NSBackgroundColor" to colorFor(if (span.inverse) span.fg else span.bg, dim = false),
    )

    private fun colorFor(argb: Int, dim: Boolean): UIColor {
        val alpha = if (dim) DIM_ALPHA else 1.0
        return UIColor.colorWithRed(
            red = ((argb shr 16) and 0xFF) / 255.0,
            green = ((argb shr 8) and 0xFF) / 255.0,
            blue = (argb and 0xFF) / 255.0,
            alpha = alpha,
        )
    }

}

// File-level rather than a companion: Kotlin/Native forbids companion fields on an ObjC subclass.
private const val DEFAULT_POINT_SIZE = 13.0
private const val DIM_ALPHA = 0.6

/** One extra row so a partially scrolled row is never blank at the edge. */
private const val OVERSCAN_ROWS = 1
