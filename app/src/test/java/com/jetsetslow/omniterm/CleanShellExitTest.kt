package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.isCleanShellExit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the clean-exit-vs-reconnect decision. A real `exit` (status 0) must tear the session down;
 * a transport loss (status -1 / null, which a network change produces) must NOT be treated as a
 * clean exit, or the terminal would be killed instead of auto-reconnected.
 */
class CleanShellExitTest {

    @Test
    fun statusZeroIsCleanExit() {
        assertTrue(isCleanShellExit(0))
    }

    @Test
    fun minusOneIsNotCleanExit_networkDropReconnects() {
        // JSch leaves the status at -1 when the socket dies before an exit-status message arrives.
        assertFalse(isCleanShellExit(-1))
    }

    @Test
    fun nullIsNotCleanExit_networkDropReconnects() {
        assertFalse(isCleanShellExit(null))
    }

    @Test
    fun nonZeroExitCodeIsStillACleanExit() {
        // `exit 1`, a failed last command, Ctrl-D after a non-zero status, etc. The shell exited
        // deliberately (JSch reports a real >= 0 code), so the session tears down — it must NOT be
        // mistaken for a network drop and reconnected.
        assertTrue(isCleanShellExit(1))
        assertTrue(isCleanShellExit(130))
    }
}
