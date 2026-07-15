package com.jetsetslow.omniterm

import androidx.compose.ui.text.input.TextFieldValue
import com.jetsetslow.omniterm.data.RemoteParsers
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TmuxControlParser
import com.jetsetslow.omniterm.data.term.Utf8StreamDecoder
import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.findMatches
import com.jetsetslow.omniterm.ui.goToLine
import com.jetsetslow.omniterm.ui.highlightAll
import com.jetsetslow.omniterm.ui.parseDnsResponse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Deterministic malformed-input and state-transition stress coverage for shared engines used by
 * multiple app features. Seeds are fixed so any failure is exactly reproducible in CI.
 */
class RobustnessStressTest {

    @Test
    fun terminalEmulatorSurvivesRandomBytesChunkingAndResizes() {
        val random = Random(0x5445524d)
        val emulator = TerminalEmulator(cols = 80, rows = 24, scrollbackLimit = 500)

        repeat(5_000) { iteration ->
            val bytes = random.nextBytes(random.nextInt(0, 257))
            var offset = 0
            while (offset < bytes.size) {
                val end = (offset + random.nextInt(1, 24)).coerceAtMost(bytes.size)
                emulator.feed(bytes.copyOfRange(offset, end))
                offset = end
            }
            if (iteration % 17 == 0) {
                emulator.resize(random.nextInt(1, 201), random.nextInt(1, 81))
            }
            if (iteration % 31 == 0) {
                val snapshot = emulator.snapshot()
                assertEquals(snapshot.rows.size, snapshot.totalRows)
                assertTrue(snapshot.cursorRow in snapshot.rows.indices)
                assertTrue(snapshot.cursorCol in 0 until snapshot.cols)
                assertTrue(emulator.scrollbackRowCount() <= 500)
            }
        }
        emulator.finishInput()
    }

    @Test
    fun remoteOutputParsersRejectNoiseWithoutCrashing() {
        val random = Random(0x50415253)
        repeat(2_000) {
            val noise = randomText(random, random.nextInt(0, 2_049))
            RemoteParsers.parseProcesses(noise)
            RemoteParsers.parseServices(noise)
            RemoteParsers.parseJournal(noise)
            RemoteParsers.parseFleetJournal(noise, "host", 1)
            RemoteParsers.parseRuntimeList(noise)
            RemoteParsers.parseDockerPs(noise)
            RemoteParsers.parseDockerRestartCounts(noise)
            RemoteParsers.parseDockerImages(noise)
            RemoteParsers.parseDockerVolumes(noise)
            RemoteParsers.parseDockerNetworks(noise)
            RemoteParsers.parseMetrics(noise)
            RemoteParsers.parseSmart(noise)
            RemoteParsers.parseDiskIo(noise)
            RemoteParsers.parseDisks(noise)
            RemoteParsers.parseProcStat(noise)
            RemoteParsers.parseNetDev(noise)
        }
    }

    @Test
    fun dnsAndTmuxProtocolParsersSurviveRandomPackets() {
        val random = Random(0x50524f54)
        repeat(10_000) {
            val packet = random.nextBytes(random.nextInt(0, 513))
            val records = parseDnsResponse(packet, packet.size)
            assertTrue(records.isNotEmpty() || packet.size >= 12)

            val parser = TmuxControlParser()
            var offset = 0
            while (offset < packet.size) {
                val end = (offset + random.nextInt(1, 33)).coerceAtMost(packet.size)
                parser.feed(packet.copyOfRange(offset, end))
                offset = end
            }
        }
    }

    @Test
    fun utf8EditorAndHighlighterSurviveRandomUnicodeAndSelections() {
        val random = Random(0x554e4943)
        repeat(5_000) {
            val bytes = random.nextBytes(random.nextInt(0, 1_025))
            val decoder = Utf8StreamDecoder()
            var offset = 0
            val decoded = buildString {
                while (offset < bytes.size) {
                    val end = (offset + random.nextInt(1, 17)).coerceAtMost(bytes.size)
                    append(decoder.decode(bytes.copyOfRange(offset, end)))
                    offset = end
                }
                append(decoder.finish())
            }

            val query = randomText(random, random.nextInt(1, 12))
            val matches = findMatches(decoded, query, random.nextBoolean(), useRegex = false)
            matches.forEach { (start, end) ->
                assertTrue(start in 0..decoded.length)
                assertTrue(end in start..decoded.length)
            }
            val moved = goToLine(TextFieldValue(decoded), decoded, random.nextInt(-100, 10_000))
            assertTrue(moved.selection.start in 0..decoded.length)
            highlightAll(decoded.take(2_048), CodeLanguage.YAML)
            highlightAll(decoded.take(2_048), CodeLanguage.SHELL)
        }
    }

    private fun randomText(random: Random, length: Int): String = buildString(length) {
        repeat(length) {
            append(
                when (random.nextInt(8)) {
                    0 -> '\n'
                    1 -> '\t'
                    2 -> '\u0000'
                    3 -> random.nextInt(0x80, 0x800).toChar()
                    else -> random.nextInt(0x20, 0x7f).toChar()
                }
            )
        }
    }
}
