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
        var text: String = " ",
        /** Display columns occupied: 2 for a wide lead, 1 normal, 0 wide continuation. */
        var width: Int = 1,
        var fg: Int = DEFAULT_FG,
        var bg: Int = DEFAULT_BG,
        var bold: Boolean = false,
        var inverse: Boolean = false,
        var italic: Boolean = false,
        var underline: Boolean = false,
        var dim: Boolean = false,
        var strike: Boolean = false,
        var hidden: Boolean = false,
    ) {
        fun set(
            value: String, fg: Int, bg: Int, bold: Boolean, inverse: Boolean,
            italic: Boolean = false, underline: Boolean = false, dim: Boolean = false,
            width: Int = 1, strike: Boolean = false, hidden: Boolean = false,
        ) {
            text = value; this.width = width; this.fg = fg; this.bg = bg; this.bold = bold; this.inverse = inverse
            this.italic = italic; this.underline = underline; this.dim = dim
            this.strike = strike; this.hidden = hidden
        }

        /** This cell becomes a copy of [source], with [text] and [width] in place of its own. */
        fun setFrom(source: Cell, text: String = source.text, width: Int = source.width) = set(
            text, source.fg, source.bg, source.bold, source.inverse, source.italic, source.underline,
            source.dim, width, source.strike, source.hidden,
        )

        fun blank(fg: Int = DEFAULT_FG, bg: Int = DEFAULT_BG) = set(" ", fg, bg, false, false)
    }

    private fun blankRow(): Array<Cell> = Array(cols) { Cell() }

    private var screen: Array<Array<Cell>> = Array(this.rows) { blankRow() }
    private val scrollback = ArrayDeque<Array<Cell>>()
    private val scrollbackSpanCache = HashMap<Array<Cell>, TermRow>()

    // Rows that ended by a soft wrap (text ran off the right edge) rather than an explicit newline.
    // The value is the number of real occupied columns before the wrap. A wide glyph can pre-wrap
    // with one structural blank left at the edge; retaining this length prevents resize/copy from
    // turning that padding into a real space. Keyed by row-array identity so it follows scrollUp.
    // (see scrollUp). Used by [resize] to reflow: only soft-wrapped runs are re-joined and re-wrapped,
    // so genuine line breaks are preserved. IdentityHashMap because Array has no value-based equals.
    private val softWrapped = java.util.IdentityHashMap<Array<Cell>, Int>()

    // alternate screen save slot
    private var savedScreen: Array<Array<Cell>>? = null
    private var altSavedCursorRow = 0
    private var altSavedCursorCol = 0
    private var altSavedWrapPending = false
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
    private var penStrike = false
    private var penHidden = false
    private var cursorVisible = true
    var applicationCursorKeys = false; private set
    var bracketedPasteMode = false; private set

    // modes
    /** DECAWM: text reaching the right edge continues on the next row. */
    private var autoWrap = true
    /** IRM: printing moves the rest of the row right. */
    private var insertMode = false
    /** DECOM: cursor addresses count from the top of the scroll region and stay inside it. */
    private var originMode = false

    // character sets: G0..G3 and the one shifted in (SI selects G0, SO selects G1)
    private enum class Charset { ASCII, UK, DEC_GRAPHICS }
    private val charsets = arrayOf(Charset.ASCII, Charset.ASCII, Charset.ASCII, Charset.ASCII)
    private var shiftedSet = 0

    /** The last character printed, for REP. */
    private var lastGraphic = -1

    // saved cursor (DECSC / DECRC, CSI s / CSI u): position, pen, wrap state, origin mode, charsets
    private class SavedCursor(
        val row: Int, val col: Int, val wrapPending: Boolean,
        val fg: Int, val bg: Int, val bold: Boolean, val inverse: Boolean, val italic: Boolean,
        val underline: Boolean, val dim: Boolean, val strike: Boolean, val hidden: Boolean,
        val originMode: Boolean, val charsets: List<Charset>, val shiftedSet: Int,
    )
    private var savedCursor: SavedCursor? = null

    // scroll region (inclusive, 0-based)
    private var scrollTop = 0
    private var scrollBottom = this.rows - 1

    private var tabStops = defaultTabStops(this.cols)

    // ── parser state ──
    private enum class State { GROUND, ESC, ESC_INTERMEDIATE, CSI, CSI_IGNORE, OSC, DISCARD_STRING }
    private var state = State.GROUND
    private val csiParams = StringBuilder()
    private val intermediates = StringBuilder()
    private var oscEscSeen = false
    private var discardEscSeen = false

    private val utf8Decoder = Utf8StreamDecoder()

    // Answers to the remote's terminal queries, waiting for [takeReplies].
    private val replies = StringBuilder()

    // ─────────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────────

    fun reset() {
        screen = Array(rows) { blankRow() }
        scrollback.clear()
        scrollbackSpanCache.clear()
        softWrapped.clear()
        savedScreen = null
        altSavedCursorRow = 0; altSavedCursorCol = 0; altSavedWrapPending = false
        altActive = false
        curRow = 0; curCol = 0; wrapPending = false
        resetPen()
        cursorVisible = true; applicationCursorKeys = false; bracketedPasteMode = false
        autoWrap = true; insertMode = false; originMode = false
        charsets.fill(Charset.ASCII); shiftedSet = 0
        lastGraphic = -1
        savedCursor = null
        tabStops = defaultTabStops(cols)
        scrollTop = 0; scrollBottom = rows - 1
        state = State.GROUND
        csiParams.setLength(0)
        intermediates.setLength(0)
        utf8Decoder.reset()
        replies.setLength(0)
    }

    fun setCaptureAlternateScreenScrollback(enabled: Boolean) {
        captureAlternateScreenScrollback = enabled
    }

    /** Feed raw bytes from the remote. Handles UTF-8 split across chunk boundaries. */
    fun feed(bytes: ByteArray) {
        val text = utf8Decoder.decode(bytes)
        processDecodedText(text)
    }

    /**
     * What the terminal answers to queries in the bytes fed so far, for the caller to write back to
     * the remote; null when nothing is waiting. fish waits 10 seconds for an answer to its device
     * attributes query before it reads any input, and Windows' console host asks for the cursor
     * position, so a terminal that stays silent leaves both hanging.
     */
    fun takeReplies(): ByteArray? {
        if (replies.isEmpty()) return null
        return replies.toString().toByteArray().also { replies.setLength(0) }
    }

    /** Flush an incomplete trailing UTF-8 sequence when a transport reaches EOF. */
    fun finishInput() {
        processDecodedText(utf8Decoder.finish())
    }

    private fun processDecodedText(text: String) {
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            processCodePoint(codePoint)
            index += Character.charCount(codePoint)
        }
    }

    fun resize(newCols: Int, newRows: Int) {
        val nc = newCols.coerceAtLeast(1)
        val nr = newRows.coerceAtLeast(1)
        if (nc == cols && nr == rows) return

        // The alternate screen hosts full-screen TUIs (vim, htop, less) that own their own layout and
        // repaint on SIGWINCH. Reflowing it would scramble that, so just clip/grow the grid and let the
        // app repaint. The hidden normal screen still needs the ordinary reflow path: clipping that
        // save slot on a shrink permanently loses the right-hand side when the TUI later exits.
        if (altActive) {
            resizeWhileAlternateScreenActive(nc, nr)
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
                val rowLogicalStart = line.size
                val occupiedColumns = softWrapped[row]?.coerceIn(0, row.size) ?: row.size
                var canonicalCursorOffset = 0
                var column = 0
                while (column < occupiedColumns) {
                    val cell = row[column]
                    val expandsDowngradedWideCell = cell.width == 1 && clusterDisplayWidth(cell.text) == 2
                    if (column < curCol || (wrapPending && column <= curCol)) {
                        canonicalCursorOffset += if (expandsDowngradedWideCell) 2 else 1
                    }
                    if (expandsDowngradedWideCell) {
                        line.add(cellCopy(cell, width = 2))
                        line.add(cellCopy(cell, text = "", width = 0))
                    } else {
                        line.add(cell)
                    }
                    column++
                }
                if (rr == cursorVisualRow) {
                    cursorLine = logicalLines.size
                    cursorOffset = rowLogicalStart + canonicalCursorOffset
                }
                if (softWrapped.containsKey(row) && rr + 1 < visualRows.size) rr++ else break
            }
            logicalLines.add(line)
            r = rr + 1
        }

        // 2. Re-wrap each logical line to the new width. Trailing blanks are trimmed first so a line
        //    padded out to the old width doesn't force phantom wraps at the new width. Empty lines are
        //    preserved (a blank logical line is a real newline).
        cols = nc; rows = nr
        tabStops = resizedTabStops(tabStops, nc)
        softWrapped.clear()
        scrollbackSpanCache.clear()
        val rewrapped = ArrayList<Array<Cell>>()
        var newCursorRow = 0
        var newCursorCol = 0
        var newCursorWrapPending = false
        for ((li, logical) in logicalLines.withIndex()) {
            var lastReal = logical.size - 1
            while (lastReal >= 0 && logical[lastReal].text == " " && logical[lastReal].bg == DEFAULT_BG && !logical[lastReal].inverse) lastReal--
            val content = if (lastReal < 0) emptyList() else logical.subList(0, lastReal + 1)
            val firstChunkIndex = rewrapped.size
            if (content.isEmpty()) {
                rewrapped.add(blankRow())
            } else {
                var col = 0
                while (col < content.size) {
                    if (nc == 1 && content[col].width == 2) {
                        val src = content[col]
                        val chunk = arrayOf(Cell().also { it.setFrom(src, width = 1) })
                        rewrapped.add(chunk)
                        col += if (col + 1 < content.size && content[col + 1].width == 0) 2 else 1
                        if (col < content.size) softWrapped[chunk] = 1
                        continue
                    }
                    val start = col
                    var end = minOf(start + nc, content.size)
                    if (end < content.size && end > col && content[end - 1].width == 2 && content[end].width == 0) {
                        end-- // keep the wide lead and continuation together on the next row
                    }
                    val chunk = Array(nc) { i -> if (start + i < end) content[start + i] else Cell() }
                    rewrapped.add(chunk)
                    col = end
                    if (col < content.size) softWrapped[chunk] = end - start
                }
            }
            if (li == cursorLine) {
                // Clamp the cursor offset to the rewrapped span of this logical line so a cursor that
                // sat in the (trimmed) trailing blanks still lands on a row that actually exists.
                val chunksForLine = (rewrapped.size - firstChunkIndex).coerceAtLeast(1)
                if (cursorOffset > 0 && cursorOffset % nc == 0) {
                    val chunkOf = (cursorOffset / nc - 1).coerceIn(0, chunksForLine - 1)
                    newCursorRow = firstChunkIndex + chunkOf
                    newCursorCol = nc - 1
                    newCursorWrapPending = true
                } else {
                    val chunkOf = (cursorOffset / nc).coerceIn(0, chunksForLine - 1)
                    newCursorRow = firstChunkIndex + chunkOf
                    newCursorCol = (cursorOffset % nc).coerceIn(0, nc - 1)
                }
            }
        }
        if (rewrapped.isEmpty()) rewrapped.add(blankRow())

        // 3. Prefer the last [nr] visual rows, but never scroll the cursor's logical line off the
        //    live screen merely because default rows existed below it. A height-only shrink shifts
        //    the live window upward as needed before it moves the cursor-bearing row into scrollback.
        //    Everything above the chosen live window becomes scrollback (capped).
        //    Pad with blank rows if the content is shorter than the screen.
        while (rewrapped.size < nr) rewrapped.add(blankRow())
        val bottomAnchoredStart = rewrapped.size - nr
        val screenStart = minOf(bottomAnchoredStart, newCursorRow.coerceAtLeast(0))
        screen = Array(nr) { rewrapped[screenStart + it] }
        // Cursor-aware shrinking can discard rows below the live window; do not retain their
        // identity keys indefinitely in the soft-wrap map.
        for (i in screenStart + nr until rewrapped.size) softWrapped.remove(rewrapped[i])
        scrollback.clear()
        for (i in 0 until screenStart) scrollback.addLast(rewrapped[i])
        trimScrollbackToLimit(countTrims = false)

        scrollTop = 0; scrollBottom = rows - 1
        curRow = (newCursorRow - screenStart).coerceIn(0, rows - 1)
        curCol = newCursorCol.coerceIn(0, cols - 1)
        wrapPending = newCursorWrapPending
        savedScreen = null // invalidate alt save on resize
    }

    /**
     * Resize while a TUI owns the alternate screen. The visible TUI grid is clipped/grown because it
     * will repaint after SIGWINCH, but the hidden normal screen and shared scrollback are reflowed by
     * the same lossless path used when no alternate screen is active.
     */
    private fun resizeWhileAlternateScreenActive(nc: Int, nr: Int) {
        val alternateGrid = screen
        val alternateRows = rows
        val alternateCursorRow = curRow
        val alternateCursorCol = curCol

        screen = savedScreen ?: Array(rows) { blankRow() }
        savedScreen = null
        curRow = altSavedCursorRow.coerceIn(0, rows - 1)
        curCol = altSavedCursorCol.coerceIn(0, cols - 1)
        wrapPending = altSavedWrapPending && curCol == cols - 1
        altActive = false

        // Reflows the normal screen together with scrollback and updates cols/rows.
        resize(nc, nr)
        val resizedNormalScreen = screen
        val resizedNormalCursorRow = curRow
        val resizedNormalCursorCol = curCol
        val resizedNormalWrapPending = wrapPending

        screen = resizeGrid(alternateGrid, alternateRows, nc, nr)
            .also { grid -> grid.forEach(::normalizeWideCells) }
        savedScreen = resizedNormalScreen
        altSavedCursorRow = resizedNormalCursorRow
        altSavedCursorCol = resizedNormalCursorCol
        altSavedWrapPending = resizedNormalWrapPending
        altActive = true
        curRow = alternateCursorRow.coerceIn(0, rows - 1)
        curCol = alternateCursorCol.coerceIn(0, cols - 1)
        wrapPending = false
        scrollTop = 0
        scrollBottom = rows - 1
    }

    private fun resizeGrid(old: Array<Array<Cell>>, oldRows: Int, nc: Int, nr: Int): Array<Array<Cell>> =
        Array(nr) { r ->
            Array(nc) { col ->
                if (r < oldRows && col < old[r].size) old[r][col] else Cell()
            }
        }

    private fun cellCopy(source: Cell, text: String = source.text, width: Int = source.width): Cell =
        Cell().also { it.setFrom(source, text, width) }

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
            trimmedRows = trimmedRowCount,
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
            trimmedRows = trimmedRowCount,
        )
    }

    fun rowCount(): Int = scrollback.size + rows

    /** Number of captured scrollback rows (the rows above the live screen in a full snapshot). */
    fun scrollbackRowCount(): Int = scrollback.size

    fun setScrollbackLimit(limit: Int) {
        scrollbackLimit = limit.coerceAtLeast(0)
        trimScrollbackToLimit()
    }

    fun clearScrollback() {
        scrollback.forEach { softWrapped.remove(it) }
        scrollback.clear()
        scrollbackSpanCache.clear()
    }

    /** True while the alternate screen (full-screen TUI) is active. */
    fun isAlternateScreenActive(): Boolean = altActive

    /**
     * Replace this emulator's scrollback with [source]'s, leaving the visible screen untouched.
     * Used to re-sync a tmux session from the pane's authoritative history (`capture-pane`
     * parsed through a scratch emulator): tmux collapses output nobody viewed into a repaint,
     * so locally accumulated scrollback can have gaps that only the server side can fill.
     * Soft-wrap flags travel with the adopted rows so copy-joining and resize reflow keep
     * working. No-op if the grids' widths differ (a resize raced the capture). [source] must
     * be discarded afterwards — the row arrays are shared, not copied.
     */
    fun adoptScrollbackFrom(source: TerminalEmulator) {
        if (source.cols != cols) return
        clearScrollback()
        for (row in source.scrollback) {
            scrollback.addLast(row)
            source.softWrapped[row]?.let { softWrapped[row] = it }
        }
        trimScrollbackToLimit(countTrims = false)
    }

    /**
     * Total scrollback rows ever evicted head-first while the row coordinate space stayed linear
     * (feed-time cap trims and user limit shrinks). A scrolled-up viewport uses the delta to
     * shift its anchor so content doesn't slide underneath it while streaming output trims the
     * head. Reflow and history adoption rebuild the coordinate space and re-anchor on their own,
     * so their evictions are excluded. Monotonic.
     */
    var trimmedRowCount: Long = 0L
        private set

    private fun trimScrollbackToLimit(countTrims: Boolean = true) {
        while (scrollback.size > scrollbackLimit) {
            val evicted = scrollback.removeFirst()
            scrollbackSpanCache.remove(evicted)
            softWrapped.remove(evicted)
            if (countTrims) trimmedRowCount++
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Char processing / parser
    // ─────────────────────────────────────────────────────────────────────────

    private fun processCodePoint(codePoint: Int) {
        if (codePoint > Char.MAX_VALUE.code) {
            if (state == State.GROUND) putGraphic(codePoint)
            return
        }
        val c = codePoint.toChar()
        when (state) {
            State.GROUND -> ground(c)
            State.ESC -> esc(c)
            State.ESC_INTERMEDIATE -> escIntermediate(c)
            State.CSI -> csi(c)
            State.CSI_IGNORE -> csiIgnore(c)
            State.OSC -> osc(c)
            State.DISCARD_STRING -> discardString(c)
        }
    }

    private fun ground(c: Char) {
        when {
            c.code == 0x1B -> enterEscape()
            c.code < 0x20 -> executeControl(c)
            c.code == 0x7F -> {}                // DEL
            c.code in 0x80..0x9F -> {}          // C1 controls sent as UTF-8: nothing to draw
            else -> putGraphic(c.code)
        }
    }

    /**
     * A C0 control acts wherever it appears, inside an escape sequence too, as in xterm: a
     * sequence split by a newline still ends on the right row. ESC, CAN and SUB are the callers'.
     */
    private fun executeControl(c: Char) {
        when (c.code) {
            0x08 -> backspace()                         // BS
            0x09 -> tab(1)                              // HT
            0x0A, 0x0B, 0x0C -> lineFeed()              // LF / VT / FF
            0x0D -> { curCol = 0; wrapPending = false } // CR
            0x0E -> shiftedSet = 1                      // SO: G1
            0x0F -> shiftedSet = 0                      // SI: G0
            else -> {}                                  // BEL and the rest: nothing
        }
    }

    /** CAN and SUB cancel a sequence; ESC starts a new one. True when [c] was one of them. */
    private fun interrupts(c: Char): Boolean = when (c.code) {
        0x1B -> { enterEscape(); true }
        0x18, 0x1A -> { state = State.GROUND; true }
        else -> false
    }

    private fun enterEscape() {
        intermediates.setLength(0)
        state = State.ESC
    }

    private fun esc(c: Char) {
        when {
            interrupts(c) -> {}
            c.code < 0x20 -> executeControl(c)
            c.code in 0x20..0x2F -> { intermediates.append(c); state = State.ESC_INTERMEDIATE }
            c.code == 0x7F -> {}
            else -> {
                state = State.GROUND
                escDispatch(c)
            }
        }
    }

    private fun escDispatch(c: Char) {
        when (c) {
            '[' -> { csiParams.setLength(0); intermediates.setLength(0); state = State.CSI }
            ']' -> { oscEscSeen = false; state = State.OSC }
            'P', '_', '^', 'X' -> { discardEscSeen = false; state = State.DISCARD_STRING }
            'M' -> reverseIndex()
            'D' -> lineFeed()
            'E' -> { curCol = 0; lineFeed() }
            'H' -> if (curCol in tabStops.indices) tabStops[curCol] = true // HTS
            '7' -> saveCursor()
            '8' -> restoreCursor()
            'c' -> reset()
            else -> {} // keypad modes (= >), single shifts (N O) and the rest: nothing to do
        }
    }

    /** ESC with intermediates: a charset designation (ESC ( 0), DECALN (ESC # 8) and the like. */
    private fun escIntermediate(c: Char) {
        when {
            interrupts(c) -> {}
            c.code < 0x20 -> executeControl(c)
            c.code in 0x20..0x2F -> if (intermediates.length < MAX_INTERMEDIATES) intermediates.append(c)
            c.code == 0x7F -> {}
            else -> {
                state = State.GROUND
                val chosen = intermediates.toString()
                val set = if (chosen.length == 1) "()*+".indexOf(chosen[0]) else -1
                when {
                    set >= 0 -> charsets[set] = when (c) {
                        '0' -> Charset.DEC_GRAPHICS
                        'A' -> Charset.UK
                        else -> Charset.ASCII
                    }
                    chosen == "#" && c == '8' -> screenAlignment()
                    else -> {} // ESC % G (UTF-8), ESC SP F and others: nothing to do
                }
            }
        }
    }

    private fun osc(c: Char) {
        // OSC string terminated by BEL or ST (ESC \). We ignore the payload (titles, etc.).
        when {
            c.code == 0x07 -> state = State.GROUND          // BEL
            oscEscSeen && c == '\\' -> state = State.GROUND // ST
            c.code == 0x18 || c.code == 0x1A -> state = State.GROUND
            else -> oscEscSeen = (c.code == 0x1B)           // ESC seen → maybe ST next
        }
    }

    private fun csi(c: Char) {
        when {
            interrupts(c) -> {}
            c.code < 0x20 -> executeControl(c)
            c.code in 0x30..0x3F -> when {
                // A parameter after an intermediate, or a private marker after the first byte,
                // makes the sequence malformed: it is consumed and ignored, never printed.
                intermediates.isNotEmpty() -> state = State.CSI_IGNORE
                c in "<=>?" && csiParams.isNotEmpty() -> state = State.CSI_IGNORE
                csiParams.length >= MAX_CONTROL_SEQUENCE_CHARS -> state = State.CSI_IGNORE
                else -> csiParams.append(c)
            }
            c.code in 0x20..0x2F ->
                if (intermediates.length < MAX_INTERMEDIATES) intermediates.append(c) else state = State.CSI_IGNORE
            c.code in 0x40..0x7E -> {
                state = State.GROUND
                dispatchCsi(c)
            }
            else -> {} // DEL
        }
    }

    /** The rest of a sequence that cannot be carried out, up to and including its final byte. */
    private fun csiIgnore(c: Char) {
        when {
            interrupts(c) -> {}
            c.code < 0x20 -> executeControl(c)
            c.code in 0x40..0x7E -> state = State.GROUND
        }
    }

    private fun discardString(c: Char) {
        when {
            c.code == 0x07 -> { discardEscSeen = false; state = State.GROUND }
            discardEscSeen && c == '\\' -> { discardEscSeen = false; state = State.GROUND }
            c.code == 0x18 || c.code == 0x1A -> { discardEscSeen = false; state = State.GROUND }
            c.code == 0x1B -> discardEscSeen = true
            else -> discardEscSeen = false
        }
    }

    /**
     * Carries out a complete control sequence. Only the forms this terminal implements act; any
     * other private marker or intermediate is ignored as a whole, so xterm, kitty and DEC queries
     * a program sends to learn what the terminal supports (`CSI > 4 ; 2 m`, `CSI ? 2026 $ p`,
     * `CSI > 1 u`) change nothing and print nothing.
     */
    private fun dispatchCsi(final: Char) {
        val raw = csiParams.toString()
        val marker = raw.firstOrNull()?.takeIf { it in "<=>?" }
        val body = if (marker != null) raw.substring(1) else raw
        val chosen = intermediates.toString()
        // Each parameter, with its colon sub-parameters (`4:3`, `38:2::r:g:b`).
        val groups: List<List<Int?>> =
            if (body.isEmpty()) emptyList()
            else body.split(';').map { group -> group.split(':').map { it.toIntOrNull()?.coerceAtMost(MAX_PARAMETER) } }
        val params = groups.map { it.firstOrNull() }
        fun p(i: Int, def: Int = 0) = params.getOrNull(i) ?: def
        fun p1(i: Int) = (params.getOrNull(i) ?: 0).let { if (it == 0) 1 else it }

        if (chosen.isNotEmpty()) {
            if (marker == null && chosen == "!" && final == 'p') softReset() // DECSTR
            return // DECSCUSR (SP q), DECRQM ($ p), DECSCA (" q) and the rest: nothing to change
        }
        if (marker == '?') {
            when (final) {
                'h' -> setDecModes(params, true)
                'l' -> setDecModes(params, false)
                'J' -> eraseInDisplay(p(0)) // DECSED: nothing here is protected, so as ED
                'K' -> eraseInLine(p(0))    // DECSEL: as EL
            }
            return
        }
        if (marker != null) return // modifyOtherKeys, kitty keyboard, secondary DA, XTVERSION…

        when (final) {
            'A' -> cursorUp(p1(0))
            'B', 'e' -> cursorDown(p1(0))
            'C', 'a' -> moveCursor(curRow, curCol + p1(0))
            'D' -> moveCursor(curRow, curCol - p1(0))
            'E' -> { cursorDown(p1(0)); curCol = 0 }
            'F' -> { cursorUp(p1(0)); curCol = 0 }
            'G', '`' -> moveCursor(curRow, p1(0) - 1)
            'd' -> moveCursorAddressed(p1(0) - 1, curCol)
            'H', 'f' -> moveCursorAddressed(p1(0) - 1, p1(1) - 1)
            'I' -> tab(p1(0))
            'Z' -> backTab(p1(0))
            'g' -> when (p(0)) {
                0 -> if (curCol in tabStops.indices) tabStops[curCol] = false
                3 -> tabStops.fill(false)
            }
            'J' -> eraseInDisplay(p(0))
            'K' -> eraseInLine(p(0))
            'L' -> insertLines(p1(0))
            'M' -> deleteLines(p1(0))
            'P' -> deleteChars(p1(0))
            '@' -> insertChars(p1(0))
            'X' -> eraseChars(p1(0))
            'S' -> scrollUp(p1(0))
            'T' -> if (params.size <= 1) scrollDown(p1(0)) // five parameters: mouse highlight, unsupported
            'b' -> repeatLastGraphic(p1(0))
            'm' -> applySgr(groups)
            'r' -> {
                // DECSTBM. 0 or nothing means the screen's edge; a region of less than two rows is
                // ignored, as xterm does.
                val top = p(0).let { if (it == 0) 1 else it } - 1
                val bottom = p(1).let { if (it == 0) rows else it }.coerceAtMost(rows) - 1
                if (top < bottom) {
                    scrollTop = top; scrollBottom = bottom
                    moveCursorAddressed(0, 0)
                }
            }
            'h' -> setAnsiModes(params, true)
            'l' -> setAnsiModes(params, false)
            // Primary device attributes: a VT100 with advanced video, as xterm and tmux answer.
            'c' -> if (params.isEmpty() || params == listOf(0)) reply("\u001B[?1;2c")
            // Device status: "OK", and the cursor position (1-based; inside the region in origin mode).
            'n' -> when (p(0)) {
                5 -> reply("\u001B[0n")
                6 -> reply("\u001B[${curRow - (if (originMode) scrollTop else 0) + 1};${curCol + 1}R")
            }
            // ANSI SCOSC/SCORC are the bare CSI s/u forms. Modern interactive clients such as
            // Claude and Codex also use Kitty's keyboard protocol, whose push/pop/query controls
            // end in `u` but carry `<`, `>`, `?`, or `=` parameters (ignored above). Treating those
            // as SCORC jumps the cursor to our old save slot just before 1049 saves the
            // primary-screen cursor; when the TUI exits, the shell then resumes at the top and
            // paints over stale rows.
            's' -> if (params.isEmpty()) saveCursor()
            'u' -> if (params.isEmpty()) restoreCursor()
            else -> {} // unsupported — ignore
        }
    }

    /** A remote that floods queries and never reads the answers cannot grow this without bound. */
    private fun reply(answer: String) {
        if (replies.length + answer.length <= MAX_CONTROL_SEQUENCE_CHARS) replies.append(answer)
    }

    /** SM / RM: insert mode (IRM) is the only ANSI mode that changes what is drawn. */
    private fun setAnsiModes(params: List<Int?>, enable: Boolean) {
        for (code in params) if (code == 4) insertMode = enable
    }

    private fun setDecModes(params: List<Int?>, enable: Boolean) {
        for (code in params) {
            when (code) {
                25 -> cursorVisible = enable
                1 -> applicationCursorKeys = enable
                6 -> { originMode = enable; moveCursorAddressed(0, 0) }
                7 -> autoWrap = enable
                2004 -> bracketedPasteMode = enable
                // 47/1047 switch buffers only — they must NOT restore the cursor (that is 1048's
                // job, and 1049's as a combined op). xterm also requires clearing the alternate
                // buffer before 1047 switches back, so its content can't leak into a later entry.
                47, 1047 -> {
                    if (!enable && altActive) screen = Array(rows) { blankRow() }
                    switchAltScreen(enable, restoreCursor = false)
                }
                // 1048 = save/restore cursor only, no buffer switch. Without it a TUI that uses the
                // 1048/47 pair (rather than 1049) leaves the cursor wherever the TUI left it, so the
                // shell's next prompt paints over the restored screen from the top.
                1048 -> if (enable) {
                    altSavedCursorRow = curRow; altSavedCursorCol = curCol; altSavedWrapPending = wrapPending
                } else {
                    curRow = altSavedCursorRow.coerceIn(0, rows - 1)
                    curCol = altSavedCursorCol.coerceIn(0, cols - 1)
                    wrapPending = altSavedWrapPending && curCol == cols - 1
                }
                // 1049 = save cursor + switch + clear on entry; restore both on exit.
                // switchAltScreen owns that entry cursor save. DECSC/CSI-s inside the TUI
                // must not overwrite the cursor that 1049 restores on exit.
                1049 -> switchAltScreen(enable, restoreCursor = true)
                else -> {}
            }
        }
    }

    /**
     * Enter or leave the alternate screen.
     *
     * [restoreCursor] distinguishes 1049 (save cursor on entry, restore it on exit) from the bare
     * 47/1047 buffer switch, which must leave the cursor untouched. Restoring it for 47/1047 would
     * move the cursor somewhere the application never asked for.
     */
    private fun switchAltScreen(toAlt: Boolean, restoreCursor: Boolean) {
        if (toAlt == altActive) return
        if (toAlt) {
            savedScreen = screen
            if (restoreCursor) {
                altSavedCursorRow = curRow
                altSavedCursorCol = curCol
                altSavedWrapPending = wrapPending
            }
            screen = Array(rows) { blankRow() }
            altActive = true
            curRow = 0; curCol = 0; wrapPending = false
        } else {
            // Falling back to a blank grid would wipe the shell's scrollback-visible screen; only
            // happens if the app leaves the alt screen without ever having entered it.
            screen = savedScreen ?: Array(rows) { blankRow() }
            savedScreen = null
            altActive = false
            if (restoreCursor) {
                curRow = altSavedCursorRow.coerceIn(0, rows - 1)
                curCol = altSavedCursorCol.coerceIn(0, cols - 1)
                wrapPending = altSavedWrapPending && curCol == cols - 1
            } else {
                curRow = curRow.coerceIn(0, rows - 1)
                curCol = curCol.coerceIn(0, cols - 1)
            }
        }
    }

    /** DECSC: the position, the pen, the pending wrap, origin mode and the character sets. */
    private fun saveCursor() {
        savedCursor = SavedCursor(
            curRow, curCol, wrapPending, penFg, penBg, penBold, penInverse, penItalic, penUnderline,
            penDim, penStrike, penHidden, originMode, charsets.toList(), shiftedSet,
        )
    }

    /** DECRC: what [saveCursor] kept; with nothing saved, the home position and a plain pen. */
    private fun restoreCursor() {
        val saved = savedCursor
        if (saved == null) {
            originMode = false
            resetPen()
            charsets.fill(Charset.ASCII); shiftedSet = 0
            moveCursor(0, 0)
            return
        }
        penFg = saved.fg; penBg = saved.bg; penBold = saved.bold; penInverse = saved.inverse
        penItalic = saved.italic; penUnderline = saved.underline; penDim = saved.dim
        penStrike = saved.strike; penHidden = saved.hidden
        originMode = saved.originMode
        saved.charsets.forEachIndexed { i, set -> charsets[i] = set }
        shiftedSet = saved.shiftedSet
        curRow = saved.row.coerceIn(0, rows - 1)
        curCol = saved.col.coerceIn(0, cols - 1)
        wrapPending = saved.wrapPending && curCol == cols - 1
    }

    /** DECSTR: modes, pen, region and charsets back to their defaults; the screen is kept. */
    private fun softReset() {
        cursorVisible = true
        autoWrap = true; insertMode = false; originMode = false
        applicationCursorKeys = false
        scrollTop = 0; scrollBottom = rows - 1
        resetPen()
        charsets.fill(Charset.ASCII); shiftedSet = 0
        savedCursor = null
    }

    /** DECALN: the screen filled with E, for lining up a display. */
    private fun screenAlignment() {
        for (row in screen) {
            for (cell in row) cell.set("E", DEFAULT_FG, DEFAULT_BG, false, false)
            softWrapped.remove(row)
        }
        scrollTop = 0; scrollBottom = rows - 1
        originMode = false
        moveCursor(0, 0)
    }

    /** A printable character after the shifted-in charset has had its say (DEC line drawing). */
    private fun putGraphic(codePoint: Int) {
        val mapped = when (charsets[shiftedSet]) {
            Charset.ASCII -> codePoint
            Charset.UK -> if (codePoint == '#'.code) 0x00A3 else codePoint
            Charset.DEC_GRAPHICS ->
                if (codePoint in DEC_GRAPHICS_FIRST..0x7E) DEC_GRAPHICS[codePoint - DEC_GRAPHICS_FIRST].code else codePoint
        }
        if (codePointWidth(mapped) > 0) lastGraphic = mapped
        putCodePoint(mapped)
    }

    /** REP: the last printed character again, [count] times (bounded by one screenful). */
    private fun repeatLastGraphic(count: Int) {
        val graphic = lastGraphic
        if (graphic < 0) return
        repeat(count.coerceAtMost(cols * rows)) { putCodePoint(graphic) }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Grid operations
    // ─────────────────────────────────────────────────────────────────────────

    private fun putCodePoint(codePoint: Int) {
        val displayWidth = codePointWidth(codePoint)
        if (displayWidth == 0) {
            appendCombiningCodePoint(codePoint)
            return
        }
        if (appendJoinedCodePoint(codePoint)) return
        if (wrapPending) {
            // The previous char filled the last column and more text follows: this row continues
            // onto the next (soft wrap). Record it so resize() can reflow the joined logical line.
            if (autoWrap) {
                if (curRow in 0 until rows) softWrapped[screen[curRow]] = cols
                curCol = 0
                lineFeed()
            }
            wrapPending = false
        }
        var width = displayWidth
        if (width == 2 && cols == 1) width = 1
        if (width == 2 && curCol == cols - 1) {
            if (autoWrap) {
                // A wide glyph cannot be split. Wrap before it when only one column remains.
                if (curRow in 0 until rows) softWrapped[screen[curRow]] = curCol
                curCol = 0
                lineFeed()
            } else {
                curCol = cols - 2
            }
        }
        if (curRow !in 0 until rows || curCol !in 0 until cols) return
        // Insert mode (IRM) moves the rest of the row right instead of writing over it.
        if (insertMode) insertChars(width)
        clearWideGlyphAt(screen[curRow], curCol)
        // Terminal traffic is overwhelmingly printable ASCII. Reusing the immutable one-character
        // strings avoids allocating/classifying a fresh String for every cell while replaying a
        // large tmux history (hundreds of thousands of characters on resume).
        val value = if (codePoint in ASCII_FIRST..ASCII_LAST) {
            ASCII_GLYPHS[codePoint - ASCII_FIRST]
        } else {
            String(Character.toChars(codePoint))
        }
        screen[curRow][curCol].set(
            value, penFg, penBg, penBold, penInverse, penItalic, penUnderline, penDim, width, penStrike, penHidden,
        )
        if (width == 2) {
            clearWideGlyphAt(screen[curRow], curCol + 1)
            screen[curRow][curCol + 1].set(
                "", penFg, penBg, penBold, penInverse, penItalic, penUnderline, penDim, 0, penStrike, penHidden,
            )
        }
        val lastOccupied = curCol + width - 1
        if (lastOccupied == cols - 1) {
            curCol = cols - 1
            // With autowrap off (DECAWM reset) the next character overwrites the last column.
            wrapPending = autoWrap
        } else {
            curCol += width
        }
    }

    private fun appendCombiningCodePoint(codePoint: Int) {
        if (curRow !in screen.indices) return
        var column = when {
            wrapPending -> cols - 1
            curCol > 0 -> curCol - 1
            else -> {
                // Preserve a leading mark visibly instead of silently discarding remote output.
                putCodePoint(0x25CC) // dotted circle
                if (wrapPending) cols - 1 else (curCol - 1).coerceAtLeast(0)
            }
        }
        if (screen[curRow][column].width == 0 && column > 0) column--
        val cell = screen[curRow][column]
        if (cell.width <= 0) return
        cell.text += String(Character.toChars(codePoint))
        repairClusterWidth(column)
    }

    private fun appendJoinedCodePoint(codePoint: Int): Boolean {
        if (curRow !in screen.indices) return false
        var column = when {
            wrapPending -> cols - 1
            curCol > 0 -> curCol - 1
            else -> return false
        }
        if (screen[curRow][column].width == 0 && column > 0) column--
        val cell = screen[curRow][column]
        if (cell.width <= 0 || cell.text.isEmpty()) return false
        val last = cell.text.codePointBefore(cell.text.length)
        val first = cell.text.codePointAt(0)
        val joinsZwjSequence = last == 0x200D
        val joinsRegionalFlag = first in 0x1F1E6..0x1F1FF &&
            codePoint in 0x1F1E6..0x1F1FF && cell.text.codePointCount(0, cell.text.length) == 1
        if (!joinsZwjSequence && !joinsRegionalFlag) return false
        cell.text += String(Character.toChars(codePoint))
        repairClusterWidth(column)
        return true
    }

    /** Reconcile the occupied cells after a variation selector/joiner extends a grapheme. */
    private fun repairClusterWidth(column: Int) {
        if (curRow !in screen.indices || column !in 0 until cols) return
        val row = screen[curRow]
        val cell = row[column]
        val target = clusterDisplayWidth(cell.text).coerceAtMost(cols)
        if (target == cell.width || cell.width <= 0) return
        if (target == 2 && cell.width == 1) {
            if (column == cols - 1) {
                if (cols == 1) return
                val moved = cellCopy(cell, width = 2)
                cell.blank(bg = cell.bg)
                softWrapped[row] = column
                wrapPending = false
                curCol = 0
                lineFeed()
                val destination = screen[curRow]
                destination[0] = moved
                destination[1] = cellCopy(moved, text = "", width = 0)
                curCol = 2
                if (curCol >= cols) { curCol = cols - 1; wrapPending = true }
            } else {
                cell.width = 2
                clearWideGlyphAt(row, column + 1)
                row[column + 1] = cellCopy(cell, text = "", width = 0)
                if (curCol > column) curCol++
                if (column + 1 == cols - 1) { curCol = cols - 1; wrapPending = true }
            }
        } else if (target == 1 && cell.width == 2) {
            cell.width = 1
            if (column + 1 < cols && row[column + 1].width == 0) row[column + 1].blank(bg = cell.bg)
            if (curCol > column + 1) curCol--
            wrapPending = false
        }
    }

    private fun clearWideGlyphAt(row: Array<Cell>, column: Int) {
        if (column !in row.indices) return
        when (row[column].width) {
            0 -> {
                row[column].blank(bg = penBg)
                if (column > 0 && row[column - 1].width == 2) row[column - 1].blank(bg = penBg)
            }
            2 -> {
                row[column].blank(bg = penBg)
                if (column + 1 < row.size && row[column + 1].width == 0) row[column + 1].blank(bg = penBg)
            }
        }
    }

    private fun normalizeWideCells(row: Array<Cell>) {
        for (column in row.indices) {
            val cell = row[column]
            when (cell.width) {
                0 -> if (column == 0 || row[column - 1].width != 2) cell.blank(bg = cell.bg)
                2 -> {
                    if (column == row.lastIndex) {
                        cell.blank(bg = cell.bg)
                    } else if (row[column + 1].width != 0) {
                        row[column + 1].setFrom(cell, text = "", width = 0)
                    }
                }
            }
        }
    }

    private fun codePointWidth(codePoint: Int): Int {
        if (codePoint in ASCII_FIRST..ASCII_LAST) return 1
        val type = Character.getType(codePoint)
        if (type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt() ||
            codePoint == 0x00AD || codePoint == 0x061C ||
            codePoint in 0x1160..0x11FF || codePoint in 0x200B..0x200F ||
            codePoint in 0x202A..0x202E || codePoint in 0x2060..0x206F ||
            codePoint == 0xFEFF || codePoint == 0x200D ||
            codePoint in 0x1F3FB..0x1F3FF || codePoint in 0xE0020..0xE007F ||
            codePoint in 0xFE00..0xFE0F || codePoint in 0xE0100..0xE01EF
        ) return 0
        // The width the programs drawing here assume (Claude Code's string-width, Codex's
        // unicode-width, tmux): Unicode's wide and emoji-presentation characters. A difference of
        // one cell moves every later redraw on the row. A lone regional indicator is one cell; a
        // pair joins into a two-cell flag (see appendJoinedCodePoint).
        return if (UnicodeWidthTable.isWide(codePoint)) 2 else 1
    }

    private fun clusterDisplayWidth(text: String): Int {
        if (text.isEmpty()) return 0
        val points = text.codePoints().toArray()
        if (points.any { it == 0xFE0E }) return 1 // explicit text presentation
        if (points.any { it == 0xFE0F || it == 0x20E3 } ||
            points.count { it in 0x1F1E6..0x1F1FF } >= 2
        ) return 2
        return points.maxOfOrNull(::codePointWidth)?.coerceAtLeast(1) ?: 1
    }

    /** BS. With a wrap pending the cursor is on the last column, and moves left from there. */
    private fun backspace() {
        wrapPending = false
        if (curCol > 0) {
            curCol--
            if (screen[curRow][curCol].width == 0 && curCol > 0) curCol--
        }
    }

    /** HT / CHT: to the next tab stop, [count] times, or the last column. */
    private fun tab(count: Int) {
        wrapPending = false
        repeat(count.coerceAtMost(cols)) {
            var column = curCol + 1
            while (column < cols - 1 && !tabStops[column]) column++
            curCol = column.coerceAtMost(cols - 1)
        }
    }

    /** CBT: back to the previous tab stop, [count] times, or the first column. */
    private fun backTab(count: Int) {
        wrapPending = false
        repeat(count.coerceAtMost(cols)) {
            var column = curCol - 1
            while (column > 0 && !tabStops[column]) column--
            curCol = column.coerceAtLeast(0)
        }
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

    /** CUP / VPA: rows count from the top of the scroll region in origin mode, and stay in it. */
    private fun moveCursorAddressed(row: Int, col: Int) {
        if (originMode) {
            curRow = (scrollTop + row).coerceIn(scrollTop, scrollBottom)
            curCol = col.coerceIn(0, cols - 1)
            wrapPending = false
        } else {
            moveCursor(row, col)
        }
    }

    /** CUU: a cursor inside the scroll region stops at its top, as in xterm. */
    private fun cursorUp(n: Int) {
        val limit = if (curRow >= scrollTop) scrollTop else 0
        moveCursor((curRow - n).coerceAtLeast(limit), curCol)
    }

    /** CUD: a cursor inside the scroll region stops at its bottom. */
    private fun cursorDown(n: Int) {
        val limit = if (curRow <= scrollBottom) scrollBottom else rows - 1
        moveCursor((curRow + n).coerceAtMost(limit), curCol)
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

    /** IL. Like DL it also moves the cursor to the first column. */
    private fun insertLines(n: Int) {
        if (curRow < scrollTop || curRow > scrollBottom) return
        curCol = 0; wrapPending = false
        val count = n.coerceIn(1, scrollBottom - curRow + 1)
        repeat(count) {
            for (r in scrollBottom downTo curRow + 1) screen[r] = screen[r - 1]
            screen[curRow] = blankRowWithPenBg()
        }
    }

    private fun deleteLines(n: Int) {
        if (curRow < scrollTop || curRow > scrollBottom) return
        curCol = 0; wrapPending = false
        val count = n.coerceIn(1, scrollBottom - curRow + 1)
        repeat(count) {
            for (r in curRow until scrollBottom) screen[r] = screen[r + 1]
            screen[scrollBottom] = blankRowWithPenBg()
        }
    }

    private fun insertChars(n: Int) {
        val line = screen[curRow]
        val count = n.coerceIn(1, cols - curCol)
        clearWideGlyphAt(line, curCol)
        if (curCol + count < cols) clearWideGlyphAt(line, curCol + count)
        for (col in cols - 1 downTo curCol + count) {
            val src = line[col - count]
            line[col].setFrom(src)
        }
        for (col in curCol until curCol + count) line[col].blank(bg = penBg)
        normalizeWideCells(line)
        softWrapped.remove(line)
    }

    private fun deleteChars(n: Int) {
        val line = screen[curRow]
        val count = n.coerceIn(1, cols - curCol)
        clearWideGlyphAt(line, curCol)
        if (curCol + count < cols) clearWideGlyphAt(line, curCol + count)
        for (col in curCol until cols - count) {
            val src = line[col + count]
            line[col].setFrom(src)
        }
        for (col in cols - count until cols) line[col].blank(bg = penBg)
        normalizeWideCells(line)
        softWrapped.remove(line)
    }

    private fun eraseChars(n: Int) {
        val line = screen[curRow]
        val end = minOf(cols, curCol + n.coerceAtLeast(1))
        eraseCellRange(line, curCol, end)
        normalizeWideCells(line)
        softWrapped.remove(line)
    }

    private fun eraseInLine(mode: Int) {
        val line = screen[curRow]
        when (mode) {
            0 -> eraseCellRange(line, curCol, cols)
            1 -> eraseCellRange(line, 0, curCol.coerceAtMost(cols - 1) + 1)
            2 -> eraseCellRange(line, 0, cols)
        }
        normalizeWideCells(line)
        // Erasing through the right edge (mode 0/2) means this row no longer runs off the edge, so
        // any recorded soft wrap is stale — a repainted row must not be re-joined with the next one.
        if (mode == 0 || mode == 2) softWrapped.remove(line)
    }

    private fun eraseCellRange(line: Array<Cell>, start: Int, endExclusive: Int) {
        if (line.isEmpty()) return
        var startColumn = start.coerceIn(0, line.size)
        var endColumn = endExclusive.coerceIn(startColumn, line.size)
        if (startColumn < line.size && line[startColumn].width == 0 && startColumn > 0) startColumn--
        if (endColumn > 0 && line[endColumn - 1].width == 2 && endColumn < line.size) endColumn++
        for (column in startColumn until endColumn) line[column].blank(bg = penBg)
    }

    private fun eraseInDisplay(mode: Int) {
        when (mode) {
            0 -> {
                eraseInLine(0)
                for (r in curRow + 1 until rows) {
                    for (col in 0 until cols) screen[r][col].blank(bg = penBg)
                    softWrapped.remove(screen[r])
                }
            }
            1 -> {
                for (r in 0 until curRow) {
                    for (col in 0 until cols) screen[r][col].blank(bg = penBg)
                    softWrapped.remove(screen[r])
                }
                eraseInLine(1)
            }
            2 -> {
                for (r in 0 until rows) {
                    for (col in 0 until cols) screen[r][col].blank(bg = penBg)
                    softWrapped.remove(screen[r])
                }
            }
            // xterm's "erase saved lines": the scrollback only. `clear` sends 2J first.
            3 -> clearScrollback()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SGR (colours / attributes)
    // ─────────────────────────────────────────────────────────────────────────

    /** SGR, with each parameter's colon sub-parameters ([groups]). */
    private fun applySgr(groups: List<List<Int?>>) {
        if (groups.isEmpty()) { resetPen(); return }
        var i = 0
        while (i < groups.size) {
            val group = groups[i]
            when (val code = group.firstOrNull() ?: 0) {
                0 -> resetPen()
                1 -> penBold = true
                2 -> penDim = true
                3 -> penItalic = true
                // 4:0 is "no underline"; 4:1 to 4:5 (single, double, curly…) are drawn as one line.
                4 -> penUnderline = (group.getOrNull(1) ?: 1) != 0
                7 -> penInverse = true
                8 -> penHidden = true
                9 -> penStrike = true
                21 -> penUnderline = true // double underline, drawn single
                22 -> { penBold = false; penDim = false }
                23 -> penItalic = false
                24 -> penUnderline = false
                27 -> penInverse = false
                28 -> penHidden = false
                29 -> penStrike = false
                in 30..37 -> penFg = PALETTE_256[code - 30]
                38 -> i = parseExtendedColor(groups, i) { penFg = it }
                39 -> penFg = DEFAULT_FG
                in 40..47 -> penBg = PALETTE_256[code - 40]
                48 -> i = parseExtendedColor(groups, i) { penBg = it }
                49 -> penBg = DEFAULT_BG
                58 -> i = parseExtendedColor(groups, i) {} // underline colour: not drawn
                in 90..97 -> penFg = PALETTE_256[8 + (code - 90)]
                in 100..107 -> penBg = PALETTE_256[8 + (code - 100)]
                else -> {} // blink (5, 6) is drawn steady; overline and fonts are not drawn
            }
            i++
        }
    }

    /**
     * A 38/48/58 colour, in its colon form inside one parameter (`38:5:n`, `38:2:r:g:b`, or
     * `38:2:id:r:g:b` with an empty or given colour space), or its semicolon form over the parameters
     * that follow (`38;5;n`, `38;2;r;g;b`). Returns the index of the last parameter it used.
     */
    private fun parseExtendedColor(groups: List<List<Int?>>, start: Int, set: (Int) -> Unit): Int {
        val group = groups[start]
        if (group.size > 1) {
            when (group[1]) {
                5 -> set(PALETTE_256[(group.getOrNull(2) ?: 0).coerceIn(0, 255)])
                2 -> {
                    val rgb = if (group.size >= 6) group.subList(3, 6) else group.drop(2)
                    if (rgb.size == 3) set(rgbColor(rgb[0], rgb[1], rgb[2]))
                }
            }
            return start
        }
        fun at(offset: Int) = groups.getOrNull(start + offset)?.firstOrNull()
        return when (at(1)) {
            5 -> {
                set(PALETTE_256[(at(2) ?: 0).coerceIn(0, 255)]); start + 2
            }
            2 -> {
                set(rgbColor(at(2), at(3), at(4))); start + 4
            }
            else -> start
        }
    }

    private fun rgbColor(r: Int?, g: Int?, b: Int?): Int =
        0xFF000000.toInt() or ((r ?: 0).coerceIn(0, 255) shl 16) or ((g ?: 0).coerceIn(0, 255) shl 8) or
            (b ?: 0).coerceIn(0, 255)

    private fun resetPen() {
        penFg = DEFAULT_FG; penBg = DEFAULT_BG; penBold = false; penInverse = false
        penItalic = false; penUnderline = false; penDim = false; penStrike = false; penHidden = false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rendering helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun rowToSpans(row: Array<Cell>): TermRow {
        var last = row.size - 1
        // trim trailing default blanks to keep spans compact
        while (last >= 0 && row[last].text == " " && row[last].bg == DEFAULT_BG && !row[last].inverse) last--
        if (last < 0) return EMPTY_ROW
        val spans = ArrayList<TermSpan>()
        val sb = StringBuilder()
        val glyphs = ArrayList<String>()
        val glyphWidths = ArrayList<Int>()
        var fg = row[0].fg; var bg = row[0].bg; var bold = row[0].bold; var inv = row[0].inverse
        var ita = row[0].italic; var und = row[0].underline; var dim = row[0].dim
        var strike = row[0].strike; var hidden = row[0].hidden
        fun flushSpan() {
            spans.add(
                TermSpan(
                    sb.toString(), fg, bg, bold, inv, ita, und, dim,
                    glyphs.toList(), glyphWidths.toList(), strike, hidden,
                )
            )
            sb.setLength(0)
            glyphs.clear()
            glyphWidths.clear()
        }
        for (col in 0..last) {
            val cell = row[col]
            if (cell.fg != fg || cell.bg != bg || cell.bold != bold || cell.inverse != inv ||
                cell.italic != ita || cell.underline != und || cell.dim != dim ||
                cell.strike != strike || cell.hidden != hidden
            ) {
                flushSpan()
                fg = cell.fg; bg = cell.bg; bold = cell.bold; inv = cell.inverse
                ita = cell.italic; und = cell.underline; dim = cell.dim
                strike = cell.strike; hidden = cell.hidden
            }
            if (cell.width > 0) {
                sb.append(cell.text)
                glyphs.add(cell.text)
                glyphWidths.add(cell.width)
            }
        }
        flushSpan()
        return TermRow(spans, softWrap = softWrapped.containsKey(row))
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

    companion object {
        private const val ASCII_FIRST = 0x20
        private const val ASCII_LAST = 0x7E
        private val ASCII_GLYPHS = Array(ASCII_LAST - ASCII_FIRST + 1) { index ->
            (ASCII_FIRST + index).toChar().toString()
        }
        private const val MAX_CONTROL_SEQUENCE_CHARS = 1024
        private const val MAX_INTERMEDIATES = 4
        private const val MAX_PARAMETER = 65_535

        /** DEC Special Graphics (`ESC ( 0`) for `_` to `~`: the line drawing ncurses asks for. */
        private const val DEC_GRAPHICS_FIRST = 0x5F
        private const val DEC_GRAPHICS =
            "\u0020\u25C6\u2592\u2409\u240C\u240D\u240A\u00B0\u00B1\u2424\u240B\u2518\u2510\u250C\u2514\u253C" +
                "\u23BA\u23BB\u2500\u23BC\u23BD\u251C\u2524\u2534\u252C\u2502\u2264\u2265\u03C0\u2260\u00A3\u00B7"

        private fun defaultTabStops(columns: Int) = BooleanArray(columns) { it > 0 && it % 8 == 0 }

        /** Tab stops kept for the columns that remain; new columns get the default every 8. */
        private fun resizedTabStops(old: BooleanArray, columns: Int) =
            BooleanArray(columns) { if (it < old.size) old[it] else it > 0 && it % 8 == 0 }
        const val DEFAULT_FG: Int = 0xFFC8D4E8.toInt() // Nexus.textPrimary
        const val DEFAULT_BG: Int = 0xFF000000.toInt() // Nexus.bg0 (AMOLED black)

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
    /** Grapheme-like terminal glyphs and their display-cell widths; empty for legacy callers. */
    val glyphs: List<String> = emptyList(),
    val glyphWidths: List<Int> = emptyList(),
    /** SGR 9: struck through. */
    val strike: Boolean = false,
    /** SGR 8: concealed; the cells keep their text for copying but nothing is drawn. */
    val hidden: Boolean = false,
) {
    /**
     * The span's glyphs and the cells each one takes. A legacy span without glyphs gets one per
     * code point, and widths that do not line up with the glyphs count one cell each.
     */
    fun cellLayout(): Pair<List<String>, List<Int>> {
        val cells = glyphs.ifEmpty { text.codePoints().toArray().map { String(Character.toChars(it)) } }
        return cells to if (glyphWidths.size == cells.size) glyphWidths else List(cells.size) { 1 }
    }
}

/**
 * One visual row. [softWrap] marks a row whose text ran off the right edge and continues on the
 * next row (no newline was ever printed) — consumers that turn rows back into text should join a
 * soft-wrapped row with its successor instead of inserting a line break.
 */
data class TermRow(val spans: List<TermSpan>, val softWrap: Boolean = false)

/** Immutable render snapshot handed to the UI layer. */
data class TerminalSnapshot(
    val rows: List<TermRow>,
    val cursorRow: Int,
    val cursorCol: Int,
    val cursorVisible: Boolean,
    val cols: Int,
    val firstRow: Int = 0,
    val totalRows: Int = rows.size,
    /** Cumulative head-trimmed rows (see [TerminalEmulator.trimmedRowCount]); anchors scrolled-up viewports. */
    val trimmedRows: Long = 0L,
) {
    companion object {
        val EMPTY = TerminalSnapshot(emptyList(), 0, 0, true, 80, 0, 0)
    }
}
