package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Test

class TerminalAdvancedResilienceTest {
    private val enterAlternate = "\u001b[?1049h"
    private val exitAlternate = "\u001b[?1049l"

    @Test
    fun alternateScreenFreezesAndRestoresPrimaryHistoryAndCursor() = runTest {
        val emulator = TerminalEmulator(cols = 24, rows = 4, scrollbackLimit = 100)
        emulator.feed("history-1\r\nhistory-2\r\nprompt> ".encodeToByteArray())
        val primaryBefore = emulator.snapshot()
        val historyRowsBefore = emulator.scrollbackRowCount()

        emulator.feed((enterAlternate + "CLAUDE\r\nworking\r\nframe-3\r\nframe-4\r\nframe-5").encodeToByteArray())

        assertThat(emulator.isAlternateScreenActive()).isTrue()
        assertThat(emulator.scrollbackRowCount()).isEqualTo(historyRowsBefore)
        assertThat(screenText(emulator)).contains("frame-5")

        emulator.feed(exitAlternate.encodeToByteArray())
        val restored = emulator.snapshot()
        assertThat(emulator.isAlternateScreenActive()).isFalse()
        assertThat(restored.rows).isEqualTo(primaryBefore.rows)
        assertThat(restored.cursorRow).isEqualTo(primaryBefore.cursorRow)
        assertThat(restored.cursorCol).isEqualTo(primaryBefore.cursorCol)
        assertThat(snapshotText(restored)).doesNotContain("CLAUDE")

        emulator.feed("echo ok\r\n".encodeToByteArray())
        assertThat(snapshotText(emulator.snapshot())).contains("prompt> echo ok")
    }

    @Test
    fun concurrentBashAndAlternatePaneStreamsNeverBleedAcrossStateFlows() = runTest {
        data class PaneChunk(val pane: Int, val bytes: ByteArray)

        val left = TerminalEmulator(32, 6, 200)
        val right = TerminalEmulator(32, 6, 200)
        val leftState = MutableStateFlow(left.snapshot())
        val rightState = MutableStateFlow(right.snapshot())
        val chunks = Channel<PaneChunk>(Channel.UNLIMITED)
        val collector = launch {
            for ((pane, bytes) in chunks) {
                val emulator = if (pane == 1) left else right
                emulator.feed(bytes)
                if (pane == 1) leftState.value = emulator.snapshot()
                else rightState.value = emulator.snapshot()
            }
        }

        chunks.send(PaneChunk(1, "bash-primary\r\n".encodeToByteArray()))
        chunks.send(PaneChunk(2, ("right-primary\r\n" + enterAlternate + "CLAUDE-CODE\r\n").encodeToByteArray()))
        repeat(250) { index ->
            chunks.send(PaneChunk(1, "LEFT-$index\r\n".encodeToByteArray()))
            chunks.send(PaneChunk(2, "RIGHT-$index\r\n".encodeToByteArray()))
        }
        chunks.close()
        collector.join()

        val leftText = snapshotText(leftState.value)
        val rightAltText = snapshotText(rightState.value)
        assertThat(leftText).contains("LEFT-249")
        assertThat(leftText).doesNotContain("RIGHT-")
        assertThat(leftText).doesNotContain("CLAUDE-CODE")
        assertThat(rightAltText).contains("RIGHT-249")
        assertThat(rightAltText).doesNotContain("LEFT-")

        right.feed(exitAlternate.encodeToByteArray())
        rightState.value = right.snapshot()
        assertThat(snapshotText(rightState.value)).contains("right-primary")
        assertThat(snapshotText(rightState.value)).doesNotContain("CLAUDE-CODE")
        assertThat(snapshotText(leftState.value)).contains("LEFT-249")
    }

    @Test(timeout = 15_000)
    fun fiftyThousandLineFloodStrictlyCapsHistoryAndRetainsNewestTail() {
        val historyCap = 2_000
        val emulator = TerminalEmulator(cols = 40, rows = 24, scrollbackLimit = historyCap)
        val payload = buildString(700_000) {
            repeat(50_000) { append("LINE-").append(it.toString().padStart(5, '0')).append("\r\n") }
        }

        emulator.feed(payload.encodeToByteArray())

        assertThat(emulator.scrollbackRowCount()).isAtMost(historyCap)
        assertThat(emulator.rowCount()).isAtMost(historyCap + emulator.rows)
        assertThat(emulator.trimmedRowCount).isGreaterThan(0L)
        val tail = snapshotText(emulator.snapshotRange(emulator.rowCount() - 30, 30))
        assertThat(tail).contains("LINE-49999")
        assertThat(tail).doesNotContain("LINE-00000")
    }

    private fun screenText(emulator: TerminalEmulator): String {
        val snapshot = emulator.snapshot()
        return snapshotText(snapshot.copy(rows = snapshot.rows.takeLast(emulator.rows)))
    }

    private fun snapshotText(snapshot: com.jetsetslow.omniterm.data.term.TerminalSnapshot): String =
        snapshot.rows.joinToString("\n") { row -> row.spans.joinToString("") { it.text } }
}
