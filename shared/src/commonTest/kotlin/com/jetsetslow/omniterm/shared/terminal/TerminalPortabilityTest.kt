package com.jetsetslow.omniterm.shared.terminal

import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TmuxControlEvent
import com.jetsetslow.omniterm.data.term.TmuxControlParser
import com.jetsetslow.omniterm.data.term.Utf8StreamDecoder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TerminalPortabilityTest {
    @Test
    fun utf8SurvivesEveryReadBoundary() {
        val expected = "ascii € ✓ 😀 tail"
        val bytes = expected.encodeToByteArray()
        for (split in 0..bytes.size) {
            val decoder = Utf8StreamDecoder()
            val actual = decoder.decode(bytes.copyOfRange(0, split)) +
                decoder.decode(bytes.copyOfRange(split, bytes.size)) + decoder.finish()
            assertEquals(expected, actual, "split=$split")
        }
    }

    @Test
    fun kittyKeyboardControlNeverActsAsAnsiRestoreCursor() {
        val emulator = TerminalEmulator(cols = 20, rows = 3)
        emulator.feed("first\r\nsecond\u001B[>1uX".encodeToByteArray())
        val snapshot = emulator.snapshot()
        val visible = snapshot.rows.map { row -> row.spans.joinToString("") { it.text } }
        assertTrue(visible[1].startsWith("secondX"), visible.joinToString("|"))
    }

    @Test
    fun largeTmuxHistoryReplaysAcrossArbitraryChunks() {
        val payload = buildString {
            repeat(2_000) { line -> append("line-").append(line).append("\\015\\012") }
            append("tail")
        }
        val transcript = "%output %1 $payload\n".encodeToByteArray()
        val parser = TmuxControlParser()
        val emulator = TerminalEmulator(cols = 40, rows = 8, scrollbackLimit = 2_500)
        var offset = 0
        while (offset < transcript.size) {
            val end = (offset + 37).coerceAtMost(transcript.size)
            parser.feed(transcript.copyOfRange(offset, end)).forEach { event ->
                if (event is TmuxControlEvent.Output) emulator.feed(event.data)
            }
            offset = end
        }
        val snapshot = emulator.snapshot()
        assertTrue(snapshot.totalRows >= 2_000)
        assertTrue(snapshot.rows.last().spans.joinToString("") { it.text }.contains("tail"))
    }
}
