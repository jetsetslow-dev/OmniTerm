package com.jetsetslow.omniterm.data.term

/**
 * A compact VT100 / xterm-subset terminal emulator.
 *
 * Pure Kotlin (no Android / Compose / java.nio deps) so it can move into a Compose
 * Multiplatform `commonMain` module untouched. It maintains a character grid + scrollback,
 * a cursor, SGR pen state, scroll regions, and an alternate screen, and parses the common
 * C0 controls, CSI and SGR sequences. Unknown sequences are skipped gracefully.
 *
 * Feed it raw bytes from the PTY via [feed]; read a render-ready [snapshot] for the UI.
 * It does NOT know about Compose colours — spans carry packed ARGB [Int]s.
 */
class TerminalEmulator(
    cols: Int = 80,
    rows: Int = 24,
    scrollbackLimit: Int = 2000,
) {
    var cols = cols.coerceAtLeast(1); private set
    var rows = rows.coerceAtLeast(1); private set
    private var scrollbackLimit: Int = scrollbackLimit.coerceAtLeast(0)

    private class Cell(
        var ch: Char = ' ',
        var fg: Int = DEFAULT_FG,
        var bg: Int = DEFAULT_BG,
        var bold: Boolean = false,
        var inverse: Boolean = false,
        var italic: Boolean = false,
        var underline: Boolean = false,
        var dim: Boolean = false,
    ) {
        fun set(
            c: Char, fg: Int, bg: Int, bold: Boolean, inverse: Boolean,
            italic: Boolean = false, underline: Boolean = false, dim: Boolean = false,
        ) {
            ch = c; this.fg = fg; this.bg = bg; this.bold = bold; this.inverse = inverse
            this.italic = italic; this.underline = underline; this.dim = dim
        }
        fun blank(fg: Int = DEFAULT_FG, bg: Int = DEFAULT_BG) = set(' ', fg, bg, false, false)
    }

    private fun blankRow(): Array<Cell> = Array(cols) { Cell() }

    private var screen: Array<Array<Cell>> = Array(this.rows) { blankRow() }
    private val scrollback = ArrayDeque<Array<Cell>>()
    private val scrollbackSpanCache = HashMap<Array<Cell>, TermRow>()

    // Rows that ended by a soft wrap (text ran off the right edge) rather than an explicit newline.
    // Keyed by row-array identity so the flag follows a row as it moves screen→scrollback by reference
    // (see scrollUp). Used by [resize] to reflow: only soft-wrapped runs are re-joined and re-wrapped,
    // so genuine line breaks are preserved. IdentityHashMap because Array has no value-based equals.
    private val softWrapped = java.util.IdentityHashMap<Array<Cell>, Boolean>()

    // alternate screen save slot
    private var savedScreen: Array<Array<Cell>>? = null
    private var altActive = false
    private var captureAlternateScreenScrollback = false

    // cursor + pen
    private var curRow = 0
    private var curCol = 0
    private var wrapPending = false
    private var penFg = DEFAULT_FG
    private var penBg = DEFAULT_BG
    private var penBold = false
    private var penInverse = false
    private var penItalic = false
    private var penUnderline = false
    private var penDim = false
    private var cursorVisible = true
    var applicationCursorKeys = false; private set

    // saved cursor (DECSC / DECRC)
    private var savedRow = 0
    private var savedCol = 0

    // scroll region (inclusive, 0-based)
    private var scrollTop = 0
    private var scrollBottom = this.rows - 1

    // ── parser state ──
    private enum class State { GROUND, ESC, CSI, OSC, CHARSET }
    private var state = State.GROUND
    private val csiParams = StringBuilder()
    private var oscEscSeen = false

    // incremental UTF-8 decode carry-over
    private var pending = ByteArray(0)

    // ─────────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────────

    fun reset() {
        screen = Array(rows) { blankRow() }
        scrollback.clear()
        scrollbackSpanCache.clear()
        softWrapped.clear()
        savedScreen = null
        altActive = false
        curRow = 0; curCol = 0; wrapPending = false
        resetPen()
        cursorVisible = true; applicationCursorKeys = false
        scrollTop = 0; scrollBottom = rows - 1
        state = State.GROUND
        csiParams.setLength(0)
        pending = ByteArray(0)
    }

    fun setCaptureAlternateScreenScrollback(enabled: Boolean) {
        captureAlternateScreenScrollback = enabled
    }

    /** Feed raw bytes from the remote. Handles UTF-8 split across chunk boundaries. */
    fun feed(bytes: ByteArray) {
        val text = decodeUtf8Incremental(bytes)
        for (c in text) processChar(c)
    }

    fun resize(newCols: Int, newRows: Int) {
        val nc = newCols.coerceAtLeast(1)
        val nr = newRows.coerceAtLeast(1)
        if (nc == cols && nr == rows) return

        // The alternate screen hosts full-screen TUIs (vim, htop, less) that own their own layout and
        // repaint on SIGWINCH. Reflowing it would scramble that, so just clip/grow the grid and let the
        // app repaint. Reflow only applies to the normal screen + scrollback (shell output history).
        if (altActive) {
            resizeGridOnly(nc, nr)
            return
        }

        // 1. Flatten scrollback + screen into logical lines, re-joining soft-wrapped runs so a line
        //    that only wrapped because it was too wide becomes one logical line again. Track where the
        //    cursor falls (as an offset within its logical line) so it can be replaced after rewrap.
        val visualRows = ArrayList<Array<Cell>>(scrollback.size + rows)
        visualRows.addAll(scrollback)
        for (r in 0 until rows) visualRows.add(screen[r])
        val cursorVisualRow = scrollback.size + curRow.coerceIn(0, rows - 1)

        val logicalLines = ArrayList<ArrayList<Cell>>()
        var cursorLine = -1
        var cursorOffset = 0
        var r = 0
        while (r < visualRows.size) {
            val line = ArrayList<Cell>(cols)
            var rr = r
            // Join this row with every following row it soft-wrapped into.
            while (true) {
                val row = visualRows[rr]
                if (rr == cursorVisualRow) { cursorLine = logicalLines.size; cursorOffset = line.size + curCol.coerceIn(0, cols - 1) }
                for (col in row.indices) line.add(row[col])
                if (softWrapped[row] == true && rr + 1 < visualRows.size) rr++ else break
            }
            logicalLines.add(line)
            r = rr + 1
        }

        // 2. Re-wrap each logical line to the new width. Trailing blanks are trimmed first so a line
        //    padded out to the old width doesn't force phantom wraps at the new width. Empty lines are
        //    preserved (a blank logical line is a real newline).
        cols = nc; rows = nr
        softWrapped.clear()
        scrollbackSpanCache.clear()
        val rewrapped = ArrayList<Array<Cell>>()
        var newCursorRow = 0
        var newCursorCol = 0
        for ((li, logical) in logicalLines.withIndex()) {
            var lastReal = logical.size - 1
            while (lastReal >= 0 && logical[lastReal].ch == ' ' && logical[lastReal].bg == DEFAULT_BG && !logical[lastReal].inverse) lastReal--
            val content = if (lastReal < 0) emptyList() else logical.subList(0, lastReal + 1)
            val firstChunkIndex = rewrapped.size
            if (content.isEmpty()) {
                rewrapped.add(blankRow())
            } else {
                var col = 0
                while (col < content.size) {
                    val end = minOf(col + nc, content.size)
                    val chunk = Array(nc) { i -> if (col + i < end) content[col + i] else Cell() }
                    rewrapped.add(chunk)
                    col = end
                    if (col < content.size) softWrapped[chunk] = true // more to come → soft wrap
                }
            }
            if (li == cursorLine) {
                // Clamp the cursor offset to the rewrapped span of this logical line so a cursor that
                // sat in the (trimmed) trailing blanks still lands on a row that actually exists.
                val chunksForLine = (rewrapped.size - firstChunkIndex).coerceAtLeast(1)
                val chunkOf = (cursorOffset / nc).coerceIn(0, chunksForLine - 1)
                newCursorRow = firstChunkIndex + chunkOf
                newCursorCol = (cursorOffset % nc).coerceIn(0, nc - 1)
            }
        }
        if (rewrapped.isEmpty()) rewrapped.add(blankRow())

        // 3. The last [nr] visual rows are the live screen; everything above is scrollback (capped).
        //    Pad with blank rows if the content is shorter than the screen.
        while (rewrapped.size < nr) rewrapped.add(blankRow())
        val screenStart = rewrapped.size - nr
        screen = Array(nr) { rewrapped[screenStart + it] }
        scrollback.clear()
        for (i in 0 until screenStart) scrollback.addLast(rewrapped[i])
        trimScrollbackToLimit()

        scrollTop = 0; scrollBottom = rows - 1
        curRow = (newCursorRow - screenStart).coerceIn(0, rows - 1)
        curCol = newCursorCol.coerceIn(0, cols - 1)
        wrapPending = false
        savedScreen = null // invalidate alt save on resize
    }

    /** Plain clip/grow resize used for the alternate screen (no reflow). */
    private fun resizeGridOnly(nc: Int, nr: Int) {
        val old = screen
        val oldRows = rows
        cols = nc; rows = nr
        screen = Array(nr) { r ->
            Array(nc) { col ->
                if (r < oldRows && col < old[r].size) old[r][col] else Cell()
            }
        }
        scrollTop = 0; scrollBottom = rows - 1
        curRow = curRow.coerceIn(0, rows - 1)
        curCol = curCol.coerceIn(0, cols - 1)
        wrapPending = false
        savedScreen = null
    }

    /** Build an immutable, render-ready snapshot (scrollback + visible screen). */
    fun snapshot(): TerminalSnapshot {
        val total = rowCount()
        val out = ArrayList<TermRow>(total)
        for (i in 0 until total) out.add(rowAt(i))
        return TerminalSnapshot(
            rows = out,
            cursorRow = scrollback.size + curRow,
            cursorCol = curCol.coerceIn(0, cols - 1),
            cursorVisible = cursorVisible,
            cols = cols,
            firstRow = 0,
            totalRows = total,
        )
    }

    /** Build a snapshot for only the requested absolute row range. */
    fun snapshotRange(firstRow: Int, count: Int): TerminalSnapshot {
        val total = rowCount()
        val start = firstRow.coerceIn(0, total)
        val end = (start + count.coerceAtLeast(0)).coerceAtMost(total)
        val out = ArrayList<TermRow>(end - start)
        for (i in start until end) out.add(rowAt(i))
        return TerminalSnapshot(
            rows = out,
            cursorRow = scrollback.size + curRow,
            cursorCol = curCol.coerceIn(0, cols - 1),
            cursorVisible = cursorVisible,
            cols = cols,
            firstRow = start,
            totalRows = total,
        )
    }

    fun rowCount(): Int = scrollback.size + rows

    fun setScrollbackLimit(limit: Int) {
        scrollbackLimit = limit.coerceAtLeast(0)
        trimScrollbackToLimit()
    }

    fun clearScrollback() {
        scrollback.forEach { softWrapped.remove(it) }
        scrollback.clear()
        scrollbackSpanCache.clear()
    }

    private fun trimScrollbackToLimit() {
        while (scrollback.size > scrollbackLimit) {
            val evicted = scrollback.removeFirst()
            scrollbackSpanCache.remove(evicted)
            softWrapped.remove(evicted)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Char processing / parser
    // ─────────────────────────────────────────────────────────────────────────

    private fun processChar(c: Char) {
        when (state) {
            State.GROUND -> ground(c)
            State.ESC -> esc(c)
            State.CSI -> csi(c)
            State.OSC -> osc(c)
            State.CHARSET -> state = State.GROUND // consume the single charset designator
        }
    }

    private fun ground(c: Char) {
        when (c.code) {
            0x07 -> {}                                  // BEL
            0x08 -> backspace()                         // BS
            0x09 -> tab()                               // HT
            0x0A, 0x0B, 0x0C -> lineFeed()              // LF / VT / FF
            0x0D -> { curCol = 0; wrapPending = false } // CR
            0x1B -> state = State.ESC                   // ESC
            0x7F -> {}                                  // DEL — ignore
            else -> if (c.code >= 0x20) putChar(c)      // other C0 controls ignored
        }
    }

    private fun esc(c: Char) {
        when (c) {
            '[' -> { csiParams.setLength(0); state = State.CSI }
            ']' -> { oscEscSeen = false; state = State.OSC }
            '(', ')', '*', '+' -> state = State.CHARSET
            '=', '>' -> state = State.GROUND       // keypad modes — ignore
            'M' -> { reverseIndex(); state = State.GROUND }
            'D' -> { lineFeed(); state = State.GROUND }
            'E' -> { curCol = 0; lineFeed(); state = State.GROUND }
            '7' -> { savedRow = curRow; savedCol = curCol; state = State.GROUND }
            '8' -> { curRow = savedRow.coerceIn(0, rows - 1); curCol = savedCol.coerceIn(0, cols - 1); wrapPending = false; state = State.GROUND }
            'c' -> reset()
            else -> state = State.GROUND
        }
    }

    private fun osc(c: Char) {
        // OSC string terminated by BEL or ST (ESC \). We ignore the payload (titles, etc.).
        when {
            c.code == 0x07 -> state = State.GROUND          // BEL
            oscEscSeen && c == '\\' -> state = State.GROUND // ST
            else -> oscEscSeen = (c.code == 0x1B)           // ESC seen → maybe ST next
        }
    }

    private fun csi(c: Char) {
        if (c.code in 0x30..0x3F || c == ' ' || c == '!') { // params + intermediates
            csiParams.append(c)
            return
        }
        if (c.code in 0x40..0x7E) {
            dispatchCsi(c)
            state = State.GROUND
            return
        }
        state = State.GROUND // anything else aborts
    }

    private fun dispatchCsi(final: Char) {
        val raw = csiParams.toString()
        val priv = raw.startsWith("?")
        val body = if (priv) raw.substring(1) else raw
        val params = body.split(';').map { it.toIntOrNull() }
        fun p(i: Int, def: Int = 0) = params.getOrNull(i) ?: def
        fun p1(i: Int) = (params.getOrNull(i) ?: 0).let { if (it == 0) 1 else it }

        when (final) {
            'A' -> moveCursor(curRow - p1(0), curCol)
            'B' -> moveCursor(curRow + p1(0), curCol)
            'C' -> moveCursor(curRow, curCol + p1(0))
            'D' -> moveCursor(curRow, curCol - p1(0))
            'E' -> moveCursor(curRow + p1(0), 0)
            'F' -> moveCursor(curRow - p1(0), 0)
            'G', '`' -> moveCursor(curRow, p1(0) - 1)
            'd' -> moveCursor(p1(0) - 1, curCol)
            'H', 'f' -> moveCursor(p1(0) - 1, p1(1) - 1)
            'J' -> eraseInDisplay(p(0))
            'K' -> eraseInLine(p(0))
            'L' -> insertLines(p1(0))
            'M' -> deleteLines(p1(0))
            'P' -> deleteChars(p1(0))
            '@' -> insertChars(p1(0))
            'X' -> eraseChars(p1(0))
            'S' -> scrollUp(p1(0))
            'T' -> scrollDown(p1(0))
            'm' -> applySgr(params)
            'r' -> {
                scrollTop = (p1(0) - 1).coerceIn(0, rows - 1)
                scrollBottom = (p(1, rows) - 1).coerceIn(scrollTop, rows - 1)
                curRow = 0; curCol = 0; wrapPending = false
            }
            'h' -> setMode(priv, params, true)
            'l' -> setMode(priv, params, false)
            's' -> { savedRow = curRow; savedCol = curCol }
            'u' -> { curRow = savedRow.coerceIn(0, rows - 1); curCol = savedCol.coerceIn(0, cols - 1) }
            else -> {} // unsupported — ignore
        }
    }

    private fun setMode(priv: Boolean, params: List<Int?>, enable: Boolean) {
        if (!priv) return
        for (code in params) {
            when (code) {
                25 -> cursorVisible = enable
                1 -> applicationCursorKeys = enable
                47, 1047 -> switchAltScreen(enable)
                1049 -> {
                    if (enable) { savedRow = curRow; savedCol = curCol }
                    switchAltScreen(enable)
                    if (!enable) { curRow = savedRow.coerceIn(0, rows - 1); curCol = savedCol.coerceIn(0, cols - 1) }
                }
                else -> {}
            }
        }
    }

    private fun switchAltScreen(toAlt: Boolean) {
        if (toAlt == altActive) return
        if (toAlt) {
            savedScreen = screen
            screen = Array(rows) { blankRow() }
            altActive = true
            curRow = 0; curCol = 0; wrapPending = false
        } else {
            screen = savedScreen ?: Array(rows) { blankRow() }
            savedScreen = null
            altActive = false
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Grid operations
    // ─────────────────────────────────────────────────────────────────────────

    private fun putChar(c: Char) {
        if (wrapPending) {
            // The previous char filled the last column and more text follows: this row continues
            // onto the next (soft wrap). Record it so resize() can reflow the joined logical line.
            if (curRow in 0 until rows) softWrapped[screen[curRow]] = true
            curCol = 0
            lineFeed()
            wrapPending = false
        }
        if (curRow !in 0 until rows || curCol !in 0 until cols) return
        screen[curRow][curCol].set(c, penFg, penBg, penBold, penInverse, penItalic, penUnderline, penDim)
        if (curCol == cols - 1) wrapPending = true else curCol++
    }

    private fun backspace() {
        if (wrapPending) { wrapPending = false; return }
        if (curCol > 0) curCol--
    }

    private fun tab() {
        wrapPending = false
        curCol = minOf(cols - 1, ((curCol / 8) + 1) * 8)
    }

    private fun lineFeed() {
        wrapPending = false
        if (curRow == scrollBottom) scrollUp(1) else if (curRow < rows - 1) curRow++
    }

    private fun reverseIndex() {
        wrapPending = false
        if (curRow == scrollTop) scrollDown(1) else if (curRow > 0) curRow--
    }

    private fun moveCursor(row: Int, col: Int) {
        curRow = row.coerceIn(0, rows - 1)
        curCol = col.coerceIn(0, cols - 1)
        wrapPending = false
    }

    private fun scrollUp(n: Int) {
        val count = n.coerceIn(1, scrollBottom - scrollTop + 1)
        repeat(count) {
            val top = screen[scrollTop]
            // Capture scrollback only when scrolling the whole screen. Ordinary alternate-screen
            // apps own their display, but tmux-backed persistent sessions need app scrollback too
            // because tmux itself runs as a full-screen terminal client.
            if ((!altActive || captureAlternateScreenScrollback) && scrollTop == 0) {
                scrollback.addLast(top)
                trimScrollbackToLimit()
            }
            for (r in scrollTop until scrollBottom) screen[r] = screen[r + 1]
            screen[scrollBottom] = blankRowWithPenBg()
        }
    }

    private fun scrollDown(n: Int) {
        val count = n.coerceIn(1, scrollBottom - scrollTop + 1)
        repeat(count) {
            for (r in scrollBottom downTo scrollTop + 1) screen[r] = screen[r - 1]
            screen[scrollTop] = blankRowWithPenBg()
        }
    }

    private fun blankRowWithPenBg(): Array<Cell> = Array(cols) { Cell(bg = penBg) }

    private fun insertLines(n: Int) {
        if (curRow < scrollTop || curRow > scrollBottom) return
        val count = n.coerceIn(1, scrollBottom - curRow + 1)
        repeat(count) {
            for (r in scrollBottom downTo curRow + 1) screen[r] = screen[r - 1]
            screen[curRow] = blankRowWithPenBg()
        }
    }

    private fun deleteLines(n: Int) {
        if (curRow < scrollTop || curRow > scrollBottom) return
        val count = n.coerceIn(1, scrollBottom - curRow + 1)
        repeat(count) {
            for (r in curRow until scrollBottom) screen[r] = screen[r + 1]
            screen[scrollBottom] = blankRowWithPenBg()
        }
    }

    private fun insertChars(n: Int) {
        val line = screen[curRow]
        val count = n.coerceIn(1, cols - curCol)
        for (col in cols - 1 downTo curCol + count) {
            val src = line[col - count]
            line[col].set(src.ch, src.fg, src.bg, src.bold, src.inverse, src.italic, src.underline, src.dim)
        }
        for (col in curCol until curCol + count) line[col].blank(bg = penBg)
    }

    private fun deleteChars(n: Int) {
        val line = screen[curRow]
        val count = n.coerceIn(1, cols - curCol)
        for (col in curCol until cols - count) {
            val src = line[col + count]
            line[col].set(src.ch, src.fg, src.bg, src.bold, src.inverse, src.italic, src.underline, src.dim)
        }
        for (col in cols - count until cols) line[col].blank(bg = penBg)
    }

    private fun eraseChars(n: Int) {
        val line = screen[curRow]
        val end = minOf(cols, curCol + n.coerceAtLeast(1))
        for (col in curCol until end) line[col].blank(bg = penBg)
    }

    private fun eraseInLine(mode: Int) {
        val line = screen[curRow]
        when (mode) {
            0 -> for (col in curCol until cols) line[col].blank(bg = penBg)
            1 -> for (col in 0..curCol.coerceAtMost(cols - 1)) line[col].blank(bg = penBg)
            2 -> for (col in 0 until cols) line[col].blank(bg = penBg)
        }
    }

    private fun eraseInDisplay(mode: Int) {
        when (mode) {
            0 -> {
                eraseInLine(0)
                for (r in curRow + 1 until rows) for (col in 0 until cols) screen[r][col].blank(bg = penBg)
            }
            1 -> {
                for (r in 0 until curRow) for (col in 0 until cols) screen[r][col].blank(bg = penBg)
                eraseInLine(1)
            }
            2, 3 -> {
                for (r in 0 until rows) for (col in 0 until cols) screen[r][col].blank(bg = penBg)
                if (mode == 3) {
                    scrollback.clear()
                    scrollbackSpanCache.clear()
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SGR (colours / attributes)
    // ─────────────────────────────────────────────────────────────────────────

    private fun applySgr(params: List<Int?>) {
        if (params.isEmpty() || (params.size == 1 && params[0] == null)) { resetPen(); return }
        var i = 0
        while (i < params.size) {
            when (val code = params[i] ?: 0) {
                0 -> resetPen()
                1 -> penBold = true
                2 -> penDim = true
                3 -> penItalic = true
                4 -> penUnderline = true
                22 -> { penBold = false; penDim = false }
                23 -> penItalic = false
                24 -> penUnderline = false
                7 -> penInverse = true
                27 -> penInverse = false
                in 30..37 -> penFg = PALETTE_256[code - 30]
                39 -> penFg = DEFAULT_FG
                in 40..47 -> penBg = PALETTE_256[code - 40]
                49 -> penBg = DEFAULT_BG
                in 90..97 -> penFg = PALETTE_256[8 + (code - 90)]
                in 100..107 -> penBg = PALETTE_256[8 + (code - 100)]
                38 -> i = parseExtendedColor(params, i) { penFg = it }
                48 -> i = parseExtendedColor(params, i) { penBg = it }
                else -> {}
            }
            i++
        }
    }

    private inline fun parseExtendedColor(params: List<Int?>, start: Int, set: (Int) -> Unit): Int {
        return when (params.getOrNull(start + 1)) {
            5 -> {
                val idx = (params.getOrNull(start + 2) ?: 0).coerceIn(0, 255)
                set(PALETTE_256[idx]); start + 2
            }
            2 -> {
                val r = (params.getOrNull(start + 2) ?: 0).coerceIn(0, 255)
                val g = (params.getOrNull(start + 3) ?: 0).coerceIn(0, 255)
                val b = (params.getOrNull(start + 4) ?: 0).coerceIn(0, 255)
                set(0xFF000000.toInt() or (r shl 16) or (g shl 8) or b); start + 4
            }
            else -> start
        }
    }

    private fun resetPen() {
        penFg = DEFAULT_FG; penBg = DEFAULT_BG; penBold = false; penInverse = false
        penItalic = false; penUnderline = false; penDim = false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rendering helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun rowToSpans(row: Array<Cell>): TermRow {
        var last = row.size - 1
        // trim trailing default blanks to keep spans compact
        while (last >= 0 && row[last].ch == ' ' && row[last].bg == DEFAULT_BG && !row[last].inverse) last--
        if (last < 0) return EMPTY_ROW
        val spans = ArrayList<TermSpan>()
        val sb = StringBuilder()
        var fg = row[0].fg; var bg = row[0].bg; var bold = row[0].bold; var inv = row[0].inverse
        var ita = row[0].italic; var und = row[0].underline; var dim = row[0].dim
        for (col in 0..last) {
            val cell = row[col]
            if (cell.fg != fg || cell.bg != bg || cell.bold != bold || cell.inverse != inv ||
                cell.italic != ita || cell.underline != und || cell.dim != dim
            ) {
                spans.add(TermSpan(sb.toString(), fg, bg, bold, inv, ita, und, dim))
                sb.setLength(0)
                fg = cell.fg; bg = cell.bg; bold = cell.bold; inv = cell.inverse
                ita = cell.italic; und = cell.underline; dim = cell.dim
            }
            sb.append(cell.ch)
        }
        spans.add(TermSpan(sb.toString(), fg, bg, bold, inv, ita, und, dim))
        return TermRow(spans)
    }

    private fun rowAt(index: Int): TermRow {
        val scrollbackRows = scrollback.size
        return if (index < scrollbackRows) {
            val row = scrollback[index]
            scrollbackSpanCache.getOrPut(row) { rowToSpans(row) }
        } else {
            rowToSpans(screen[index - scrollbackRows])
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Incremental UTF-8 decoding (pure Kotlin)
    // ─────────────────────────────────────────────────────────────────────────

    private fun decodeUtf8Incremental(bytes: ByteArray): String {
        val buf = if (pending.isEmpty()) bytes else pending + bytes
        val sb = StringBuilder(buf.size)
        var i = 0
        while (i < buf.size) {
            val b0 = buf[i].toInt() and 0xFF
            val len = when {
                b0 < 0x80 -> 1
                b0 in 0xC0..0xDF -> 2
                b0 in 0xE0..0xEF -> 3
                b0 in 0xF0..0xF7 -> 4
                else -> 1 // invalid lead
            }
            if (i + len > buf.size) break // incomplete trailing sequence — carry over
            if (len == 1) {
                sb.append(if (b0 < 0x80) b0.toChar() else REPLACEMENT)
            } else {
                var cp = when (len) {
                    2 -> b0 and 0x1F
                    3 -> b0 and 0x0F
                    else -> b0 and 0x07
                }
                var valid = true
                for (k in 1 until len) {
                    val bk = buf[i + k].toInt() and 0xFF
                    if (bk and 0xC0 != 0x80) { valid = false; break }
                    cp = (cp shl 6) or (bk and 0x3F)
                }
                when {
                    !valid -> sb.append(REPLACEMENT)
                    cp <= 0xFFFF -> sb.append(cp.toChar())
                    else -> {
                        val v = cp - 0x10000
                        sb.append((0xD800 + (v shr 10)).toChar())
                        sb.append((0xDC00 + (v and 0x3FF)).toChar())
                    }
                }
            }
            i += len
        }
        pending = if (i < buf.size) buf.copyOfRange(i, buf.size) else ByteArray(0)
        return sb.toString()
    }

    companion object {
        const val DEFAULT_FG: Int = 0xFFC8D4E8.toInt() // Nexus.textPrimary
        const val DEFAULT_BG: Int = 0xFF000000.toInt() // Nexus.bg0 (AMOLED black)
        private const val REPLACEMENT = '�'

        /** Standard xterm 256-colour palette (16 base + 6×6×6 cube + 24 greys). */
        val PALETTE_256: IntArray = buildPalette()

        private fun buildPalette(): IntArray {
            val p = IntArray(256)
            // Blue (index 4) and bright blue (index 12) are lifted well above the usual ANSI values:
            // pure-ish blue is very low luminance and reads poorly on the near-black terminal
            // background. The brighter tones keep "blue" identity while staying legible. Other 14
            // colours are the standard high-contrast xterm values.
            val base = intArrayOf(
                0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x5C82FF, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                0x4D4D4D, 0xFF4444, 0x4DFF4D, 0xFFFF4D, 0x8AB4FF, 0xFF4DFF, 0x4DFFFF, 0xFFFFFF,
            )
            for (i in 0..15) p[i] = 0xFF000000.toInt() or base[i]
            var idx = 16
            val steps = intArrayOf(0, 95, 135, 175, 215, 255)
            for (r in 0..5) for (g in 0..5) for (b in 0..5) {
                p[idx++] = 0xFF000000.toInt() or (steps[r] shl 16) or (steps[g] shl 8) or steps[b]
            }
            for (i in 0..23) {
                val v = 8 + i * 10
                p[232 + i] = 0xFF000000.toInt() or (v shl 16) or (v shl 8) or v
            }
            return p
        }

        private val EMPTY_ROW = TermRow(listOf(TermSpan("", DEFAULT_FG, DEFAULT_BG, false, false)))
    }
}

/** A run of cells sharing the same attributes. Colours are packed ARGB ([Int]). */
data class TermSpan(
    val text: String,
    val fg: Int,
    val bg: Int,
    val bold: Boolean,
    val inverse: Boolean,
    val italic: Boolean = false,
    val underline: Boolean = false,
    val dim: Boolean = false,
)

data class TermRow(val spans: List<TermSpan>)

/** Immutable render snapshot handed to the UI layer. */
data class TerminalSnapshot(
    val rows: List<TermRow>,
    val cursorRow: Int,
    val cursorCol: Int,
    val cursorVisible: Boolean,
    val cols: Int,
    val firstRow: Int = 0,
    val totalRows: Int = rows.size,
) {
    companion object {
        val EMPTY = TerminalSnapshot(emptyList(), 0, 0, true, 80, 0, 0)
    }
}
