package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Logs tab's fallback chain.
 *
 * It used to branch on whether each log *binary exists* (`elif command -v logread …`). A BusyBox
 * host ships `logread` whether or not syslogd is running, and when it is not, `logread` fails to
 * stderr — swallowed by `2>/dev/null` — and exits. The chain stopped there, printed nothing, and
 * never reached the `---NOLOGS---` marker, so the tab showed an empty pane with no explanation on
 * most containers.
 *
 * Found by running the Flutter port against a real Alpine host; the same shape shipped here.
 */
class JournalCommandFallbackTest {

    private fun linux(lines: Int = 300) = RemoteCommands.journal(lines)

    @Test
    fun everySourceIsStillConsulted() {
        val command = linux()
        for (source in listOf("journalctl", "logread", "/var/log/messages", "/var/log/syslog")) {
            assertTrue("missing source: $source", command.contains(source))
        }
    }

    @Test
    fun sourcesFallThroughOnEmptyOutput() {
        val command = linux()
        assertFalse(
            "an elif chain stops at the first source that exists, not the first that works",
            command.contains("elif"),
        )
        // Every source after the first is guarded on the accumulated output still being empty.
        val guards = Regex(Regex.escape("[ -z \"\$L\" ]")).findAll(command).count()
        assertTrue("expected at least 3 emptiness guards, found $guards", guards >= 3)
    }

    @Test
    fun theMarkerIsStillReachable() {
        // This is what lets the tab say "no readable log source" instead of showing a blank pane.
        assertTrue(linux().contains("---NOLOGS---"))
    }

    @Test
    fun theCollectedOutputIsWhatGetsPrinted() {
        assertTrue(linux().contains("printf"))
    }

    @Test
    fun theLineCountIsHonoured() {
        assertTrue(linux(42).contains("-n 42"))
    }
}
