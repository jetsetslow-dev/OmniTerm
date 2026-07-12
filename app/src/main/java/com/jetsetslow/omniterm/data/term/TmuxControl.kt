package com.jetsetslow.omniterm.data.term

/**
 * tmux control mode (`tmux -C attach`) protocol core — the transport iTerm2's tmux integration
 * is built on. In control mode tmux emits structured line-based events instead of rendering a
 * text UI, and crucially it streams EVERY byte of pane output (`%output`), so the "fast output
 * is collapsed into a repaint and unseen rows are lost" problem of a regular attach cannot
 * happen by construction. Input is sent back as plain-text tmux commands (`send-keys -H`).
 *
 * Protocol facts below were verified against real `tmux -C` output from tmux 3.3a:
 *  - Command replies are wrapped in `%begin <ts> <num> <flags>` … `%end|%error <ts> <num> <flags>`.
 *    Body lines are arbitrary text and may themselves start with `%` (e.g. `list-panes` printing
 *    pane ids), so while inside a block only %end/%error terminate it.
 *  - `%output %<pane> <data>`: control bytes and backslash are escaped as exactly three octal
 *    digits (`\015\012` for CRLF, `\033` for ESC, `\134` for backslash); bytes ≥ 0x80 (UTF-8
 *    continuation bytes) pass through RAW — parsing must therefore be byte-level, never through
 *    a String decode.
 *  - Other notifications (`%session-changed`, `%layout-change`, `%sessions-changed`, …) are
 *    single lines; `%exit [reason]` ends the conversation.
 *
 * Pure Kotlin (no java.io/nio), matching [TerminalEmulator]'s portability constraint.
 */
sealed interface TmuxControlEvent {
    /** Raw terminal bytes for one pane — feed to that pane's [TerminalEmulator]. */
    class Output(val paneId: String, val data: ByteArray) : TmuxControlEvent

    /** A completed `%begin`…`%end`/`%error` command reply, body newline-joined. */
    data class Reply(val body: String, val isError: Boolean) : TmuxControlEvent

    /** `%session-changed $<id> <name>`. */
    data class SessionChanged(val sessionId: String, val name: String) : TmuxControlEvent

    /** `%exit [reason]` — the control conversation is over (detached, killed, or error). */
    data class Exit(val reason: String?) : TmuxControlEvent

    /** Any other `%`-notification (window-add, layout-change, …), passed through verbatim. */
    data class Notification(val line: String) : TmuxControlEvent
}

class TmuxControlParser {
    private var pending = ByteArray(0)
    private var inReply = false
    private val replyBody = StringBuilder()

    /** Feed raw bytes from the control-mode channel; returns the events completed by this chunk. */
    fun feed(chunk: ByteArray): List<TmuxControlEvent> {
        require(pending.size.toLong() + chunk.size <= MAX_BUFFERED_BYTES || chunk.indexOf(NL) >= 0) {
            "tmux control line exceeds $MAX_BUFFERED_BYTES bytes"
        }
        val events = ArrayList<TmuxControlEvent>()
        var buf = if (pending.isEmpty()) chunk else pending + chunk
        var start = 0
        for (i in buf.indices) {
            if (buf[i] == NL) {
                handleLine(buf, start, i, events)
                start = i + 1
            }
        }
        pending = if (start >= buf.size) ByteArray(0) else buf.copyOfRange(start, buf.size)
        require(pending.size <= MAX_BUFFERED_BYTES) { "tmux control line exceeds $MAX_BUFFERED_BYTES bytes" }
        return events
    }

    private fun handleLine(buf: ByteArray, start: Int, end: Int, out: MutableList<TmuxControlEvent>) {
        // Strip a trailing CR: tmux itself terminates lines with bare \n, but be lenient.
        val e = if (end > start && buf[end - 1] == CR) end - 1 else end
        if (inReply) {
            // Inside a reply block everything except the terminator is body — including lines
            // that start with '%' (list-panes output does).
            val text = buf.decodeToString(start, e)
            when {
                text.startsWith("%end ") -> {
                    inReply = false
                    out.add(TmuxControlEvent.Reply(replyBody.toString(), isError = false))
                }
                text.startsWith("%error ") -> {
                    inReply = false
                    out.add(TmuxControlEvent.Reply(replyBody.toString(), isError = true))
                }
                else -> {
                    require(replyBody.length + text.length + 1 <= MAX_BUFFERED_BYTES) {
                        "tmux control reply exceeds $MAX_BUFFERED_BYTES characters"
                    }
                    if (replyBody.isNotEmpty()) replyBody.append('\n')
                    replyBody.append(text)
                }
            }
            return
        }
        if (matchesPrefix(buf, start, e, OUTPUT_PREFIX)) {
            var i = start + OUTPUT_PREFIX.size
            val paneStart = i
            while (i < e && buf[i] != SP) i++
            val paneId = buf.decodeToString(paneStart, i)
            val dataStart = if (i < e) i + 1 else e
            out.add(TmuxControlEvent.Output(paneId, unescapeOctal(buf, dataStart, e)))
            return
        }
        if (matchesPrefix(buf, start, e, EXTENDED_OUTPUT_PREFIX)) {
            var i = start + EXTENDED_OUTPUT_PREFIX.size
            val paneStart = i
            while (i < e && buf[i] != SP) i++
            val paneId = buf.decodeToString(paneStart, i)
            // Arguments reserved for future tmux versions end at a standalone ':' token.
            var dataStart = e
            while (i < e) {
                while (i < e && buf[i] == SP) i++
                if (i < e && buf[i] == COLON && (i + 1 == e || buf[i + 1] == SP)) {
                    dataStart = if (i + 1 < e) i + 2 else e
                    break
                }
                while (i < e && buf[i] != SP) i++
            }
            out.add(TmuxControlEvent.Output(paneId, unescapeOctal(buf, dataStart, e)))
            return
        }
        val text = buf.decodeToString(start, e)
        when {
            text.startsWith("%begin ") -> {
                inReply = true
                replyBody.setLength(0)
            }
            text.startsWith("%session-changed ") -> {
                val rest = text.removePrefix("%session-changed ")
                val id = rest.substringBefore(' ')
                out.add(TmuxControlEvent.SessionChanged(id, rest.substringAfter(' ', "")))
            }
            text == "%exit" || text.startsWith("%exit ") -> {
                out.add(TmuxControlEvent.Exit(text.removePrefix("%exit").trim().ifEmpty { null }))
            }
            text.isNotEmpty() -> out.add(TmuxControlEvent.Notification(text))
        }
    }

    /** Decode `%output` payload: `\NNN` (exactly three octal digits) → byte; all else verbatim. */
    private fun unescapeOctal(buf: ByteArray, from: Int, to: Int): ByteArray {
        val out = ByteArray(to - from)
        var n = 0
        var i = from
        while (i < to) {
            val b = buf[i]
            if (b == BACKSLASH && i + 3 < to && isOctal(buf[i + 1]) && isOctal(buf[i + 2]) && isOctal(buf[i + 3])) {
                out[n++] = (((buf[i + 1] - ZERO) shl 6) or ((buf[i + 2] - ZERO) shl 3) or (buf[i + 3] - ZERO)).toByte()
                i += 4
            } else {
                out[n++] = b
                i++
            }
        }
        return if (n == out.size) out else out.copyOf(n)
    }

    private fun isOctal(b: Byte) = b >= ZERO && b <= SEVEN

    private fun matchesPrefix(buf: ByteArray, start: Int, end: Int, prefix: ByteArray): Boolean {
        if (end - start < prefix.size) return false
        for (i in prefix.indices) if (buf[start + i] != prefix[i]) return false
        return true
    }

    private companion object {
        const val NL = '\n'.code.toByte()
        const val CR = '\r'.code.toByte()
        const val SP = ' '.code.toByte()
        const val BACKSLASH = '\\'.code.toByte()
        const val COLON = ':'.code.toByte()
        const val ZERO = '0'.code.toByte()
        const val SEVEN = '7'.code.toByte()
        val OUTPUT_PREFIX = "%output ".encodeToByteArray()
        val EXTENDED_OUTPUT_PREFIX = "%extended-output ".encodeToByteArray()
        const val MAX_BUFFERED_BYTES = 1024 * 1024
    }
}

/** Commands sent TO tmux on the control channel (plain text lines). */
object TmuxControlCommands {
    /**
     * Keystrokes/paste as hex bytes (`send-keys -H`), chunked so a large paste never exceeds
     * tmux's command-line limits. Bytes are passed through exactly — no shell, no escaping.
     */
    fun sendKeysHex(paneId: String, data: ByteArray, chunkSize: Int = 128): List<String> {
        require(paneId.matches(Regex("%\\d+"))) { "invalid tmux pane id: $paneId" }
        if (data.isEmpty()) return emptyList()
        val hex = StringBuilder()
        val commands = ArrayList<String>()
        var inChunk = 0
        for (b in data) {
            hex.append(' ').append(HEX[(b.toInt() shr 4) and 0xF]).append(HEX[b.toInt() and 0xF])
            if (++inChunk == chunkSize) {
                commands.add("send-keys -t $paneId -H$hex")
                hex.setLength(0)
                inChunk = 0
            }
        }
        if (hex.isNotEmpty()) commands.add("send-keys -t $paneId -H$hex")
        return commands
    }

    /** Tell tmux the control client's pane size (XxY form, verified on tmux 3.3a). */
    fun refreshClientSize(cols: Int, rows: Int): String =
        "refresh-client -C ${cols.coerceAtLeast(1)}x${rows.coerceAtLeast(1)}"

    /** Pause/resume one pane's control-mode output while taking an atomic screen snapshot. */
    fun paneOutputState(paneId: String, state: String): String {
        require(paneId.matches(Regex("%\\d+"))) { "invalid tmux pane id: $paneId" }
        require(state in setOf("on", "off", "pause", "continue")) { "invalid pane output state: $state" }
        return "refresh-client -A $paneId:$state"
    }

    /** Pane history + visible screen come back as a [TmuxControlEvent.Reply] body. */
    fun capturePane(paneId: String, historyLines: Int, includeScreen: Boolean): String {
        require(paneId.matches(Regex("%\\d+"))) { "invalid tmux pane id: $paneId" }
        val tail = if (includeScreen) "" else " -E -1"
        return "capture-pane -p -e -J -S -${historyLines.coerceAtLeast(0)}$tail -t $paneId"
    }

    /** Active pane id + cursor for the initial repaint seed (reply body: `%N x y`). */
    fun activePaneQuery(): String =
        "display-message -p '#{pane_id} #{cursor_x} #{cursor_y}'"

    private val HEX = "0123456789abcdef".toCharArray()
}
