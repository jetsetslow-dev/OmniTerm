package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.isLiveTerminalForNavigation
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalNavigationSessionTest {

    @Test
    fun connectedShellWithoutExitSignalStillNeedsNavigationPrompt() {
        assertTrue(
            isLiveTerminalForNavigation(
                isConnected = true,
                remoteExited = false,
                exitStatus = null,
            )
        )
    }

    @Test
    fun remoteExitIsIgnoredWhileMainThreadCleanupCatchesUp() {
        assertFalse(
            isLiveTerminalForNavigation(
                isConnected = true,
                remoteExited = true,
                exitStatus = 0,
            )
        )
    }

    @Test
    fun realExitStatusIsEnoughToIgnoreStaleConnectedFlag() {
        assertFalse(
            isLiveTerminalForNavigation(
                isConnected = true,
                remoteExited = false,
                exitStatus = 0,
            )
        )
    }

    @Test
    fun networkDropIsNotMisclassifiedAsACompletedShellExit() {
        assertTrue(
            isLiveTerminalForNavigation(
                isConnected = true,
                remoteExited = false,
                exitStatus = -1,
            )
        )
    }
}
