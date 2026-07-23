package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.term.TmuxControlCommands
import com.jetsetslow.omniterm.data.term.TmuxControlEvent
import com.jetsetslow.omniterm.data.term.TmuxControlParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fixture lines mirror REAL `tmux -C attach` output captured from tmux 3.3a on 2026-07-10
 * (see the protocol notes on TmuxControlParser): octal escapes for controls and backslash,
 * raw UTF-8 high bytes, reply bodies that themselves start with '%'.
 */
class TmuxControlTest {

    private val fixture = (
        "%begin 1783673838 263 0\n" +
            "%end 1783673838 263 0\n" +
            "%session-changed \$0 x\n" +
            "%begin 1783673838 268 1\n" +
            "%0 1\n" +
            "%end 1783673838 268 1\n" +
            "%output %0 echo \"hi✓\"\\015\\012\n" +
            "%output %0 \\033[32mgreen\\134path\\015\\012\n" +
            "%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *\n" +
            "%sessions-changed\n" +
            "%exit\n"
        ).encodeToByteArray()

    @Test
    fun parsesRealControlModeConversation() {
        val events = TmuxControlParser().feed(fixture)

        // Empty attach reply, then the list-panes style reply whose body starts with '%'.
        val replies = events.filterIsInstance<TmuxControlEvent.Reply>()
        assertEquals(2, replies.size)
        assertEquals("", replies[0].body)
        assertEquals("%0 1", replies[1].body)
        assertFalse(replies[1].isError)

        val session = events.filterIsInstance<TmuxControlEvent.SessionChanged>().single()
        assertEquals("\$0", session.sessionId)
        assertEquals("x", session.name)

        val outputs = events.filterIsInstance<TmuxControlEvent.Output>()
        assertEquals(2, outputs.size)
        assertEquals("%0", outputs[0].paneId)
        // \015\012 → CRLF; the UTF-8 check mark arrives as raw bytes.
        assertArrayEquals("echo \"hi✓\"\r\n".encodeToByteArray(), outputs[0].data)
        // \033 → ESC, \134 → backslash.
        assertArrayEquals("[32mgreen\\path\r\n".encodeToByteArray(), outputs[1].data)

        val notes = events.filterIsInstance<TmuxControlEvent.Notification>().map { it.line }
        assertTrue(notes.any { it.startsWith("%layout-change @0") })
        assertTrue("%sessions-changed" in notes)

        assertNull(events.filterIsInstance<TmuxControlEvent.Exit>().single().reason)
    }

    @Test
    fun survivesArbitraryChunkBoundaries() {
        // Feed the same conversation one byte at a time — splits land mid-line, mid-escape,
        // and mid-UTF-8; the event stream must be identical.
        val parser = TmuxControlParser()
        val events = ArrayList<TmuxControlEvent>()
        for (b in fixture) events += parser.feed(byteArrayOf(b))
        val whole = TmuxControlParser().feed(fixture)
        assertEquals(whole.size, events.size)
        val a = events.filterIsInstance<TmuxControlEvent.Output>()
        val b = whole.filterIsInstance<TmuxControlEvent.Output>()
        assertEquals(b.size, a.size)
        for (i in a.indices) assertArrayEquals(b[i].data, a[i].data)
    }

    @Test
    fun errorBlockReportsIsError() {
        val events = TmuxControlParser().feed(
            "%begin 1 5 1\nbad command: nope\n%error 1 5 1\n".encodeToByteArray()
        )
        val reply = events.filterIsInstance<TmuxControlEvent.Reply>().single()
        assertTrue(reply.isError)
        assertEquals("bad command: nope", reply.body)
    }

    @Test
    fun replyBodyStartingWithErrorTextIsNotMistakenForTerminator() {
        val events = TmuxControlParser().feed(
            "%begin 1 5 1\n%errorRate 42\n%end 1 5 1\n".encodeToByteArray()
        )
        val reply = events.filterIsInstance<TmuxControlEvent.Reply>().single()
        assertFalse(reply.isError)
        assertEquals("%errorRate 42", reply.body)
    }

    @Test
    fun exitCarriesReasonWhenPresent() {
        val events = TmuxControlParser().feed("%exit server exited\n".encodeToByteArray())
        assertEquals("server exited", events.filterIsInstance<TmuxControlEvent.Exit>().single().reason)
    }

    @Test
    fun trailingBackslashAndShortOctalPassThrough() {
        // Defensive: tmux always emits three octal digits, but a malformed tail must not crash
        // or eat bytes.
        val events = TmuxControlParser().feed("%output %0 a\\01\n".encodeToByteArray())
        val out = events.filterIsInstance<TmuxControlEvent.Output>().single()
        assertArrayEquals("a\\01".encodeToByteArray(), out.data)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsUnboundedControlLine() {
        TmuxControlParser().feed(ByteArray(1024 * 1024 + 1) { 'x'.code.toByte() })
    }

    @Test
    fun parsesBufferedExtendedOutputAfterPaneResume() {
        val event = TmuxControlParser().feed(
            "%extended-output %7 125 future : hi\\015\\012\n".encodeToByteArray()
        ).filterIsInstance<TmuxControlEvent.Output>().single()
        assertEquals("%7", event.paneId)
        assertArrayEquals("hi\r\n".encodeToByteArray(), event.data)
    }

    @Test
    fun controlOutputDrivesTheEmulatorLikeRawAnsi() {
        // The wire path in miniature: %output events for the active pane feed the emulator;
        // other panes' output and protocol metadata must leave the grid untouched.
        val emulator = com.jetsetslow.omniterm.data.term.TerminalEmulator(20, 4)
        val conversation = (
            "%begin 1 2 0\n%end 1 2 0\n" +
                "%output %0 \\033[1mhello\\033[0m\\015\\012\n" +
                "%output %9 OTHER PANE NOISE\\015\\012\n" +
                "%output %0 world\n"
            ).encodeToByteArray()
        for (event in TmuxControlParser().feed(conversation)) {
            if (event is TmuxControlEvent.Output && event.paneId == "%0") emulator.feed(event.data)
        }
        val rows = emulator.snapshot().rows
        assertEquals("hello", rows[0].spans.joinToString("") { it.text }.trimEnd())
        assertEquals("world", rows[1].spans.joinToString("") { it.text }.trimEnd())
        assertTrue(rows.none { row -> row.spans.joinToString("") { it.text }.contains("NOISE") })
    }

    @Test
    fun sendKeysHexEncodesAndChunks() {
        val cmds = TmuxControlCommands.sendKeysHex("%3", "hi\r".encodeToByteArray())
        assertEquals(listOf("send-keys -t %3 -H 68 69 0d"), cmds)
        // 300 bytes at 128/chunk → 3 commands.
        val big = TmuxControlCommands.sendKeysHex("%0", ByteArray(300) { 'a'.code.toByte() })
        assertEquals(3, big.size)
        assertTrue(big.all { it.startsWith("send-keys -t %0 -H ") })
    }

    @Test
    fun sendKeysRejectsMalformedPaneId() {
        // The pane id is interpolated into a tmux command — never let arbitrary text through.
        var threw = false
        try { TmuxControlCommands.sendKeysHex("%0; kill-server", "x".encodeToByteArray()) }
        catch (e: IllegalArgumentException) { threw = true }
        assertTrue(threw)
    }

    @Test(expected = IllegalArgumentException::class)
    fun sendKeysRejectsNonPositiveChunkSize() {
        TmuxControlCommands.sendKeysHex("%0", "x".encodeToByteArray(), chunkSize = 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun paneOutputStateRejectsMalformedPaneId() {
        TmuxControlCommands.paneOutputState("%0; kill-server", "pause")
    }

    @Test(expected = IllegalArgumentException::class)
    fun paneOutputStateRejectsUnknownState() {
        TmuxControlCommands.paneOutputState("%0", "invalid")
    }

    @Test(expected = IllegalArgumentException::class)
    fun capturePaneRejectsMalformedPaneId() {
        TmuxControlCommands.capturePane("%0; kill-server", 10, includeScreen = true)
    }

    @Test(expected = IllegalArgumentException::class)
    fun clearHistoryRejectsMalformedPaneId() {
        TmuxControlCommands.clearHistory("%0; kill-server")
    }

    @Test
    fun resizeAndCaptureCommandFormats() {
        assertEquals("refresh-client -C 100x30", TmuxControlCommands.refreshClientSize(100, 30))
        assertEquals("refresh-client -C 1x1", TmuxControlCommands.refreshClientSize(0, -1))
        // The leading percent must be escaped when followed by `:state`; bare `%0:pause`
        // produces `parse error: syntax error` in a real tmux 3.3a control client.
        assertEquals("refresh-client -A \\%0:pause", TmuxControlCommands.paneOutputState("%0", "pause"))
        assertEquals("refresh-client -A \\%0:continue", TmuxControlCommands.paneOutputState("%0", "continue"))
        assertEquals(
            "capture-pane -p -e -J -S -10000 -E -1 -t %0",
            TmuxControlCommands.capturePane("%0", 10_000, includeScreen = false),
        )
        assertEquals(
            "capture-pane -p -e -J -S -500 -t %1",
            TmuxControlCommands.capturePane("%1", 500, includeScreen = true),
        )
        assertEquals("clear-history -t %1", TmuxControlCommands.clearHistory("%1"))
    }
}
