package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.isLiveTerminalForNavigation
import com.jetsetslow.omniterm.ui.TerminalNavigationCandidate
import com.jetsetslow.omniterm.ui.terminalNavigationSessionIds
import com.jetsetslow.omniterm.ui.terminalLeaveAction
import com.jetsetslow.omniterm.ui.TerminalLeaveAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

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

    @Test
    fun everyConnectionStatePermutationMatchesTheNavigationPolicy() {
        val exitStatuses = listOf<Int?>(null, -1, 0, 1, 130)
        for (isConnected in listOf(false, true)) {
            for (reconnecting in listOf(false, true)) {
                for (userClosed in listOf(false, true)) {
                    for (remoteExited in listOf(false, true)) {
                        for (exitStatus in exitStatuses) {
                            val candidate = candidate(
                                id = "session",
                                isConnected = isConnected,
                                reconnecting = reconnecting,
                                userClosed = userClosed,
                                remoteExited = remoteExited,
                                exitStatus = exitStatus,
                            )
                            val expected = !userClosed && !remoteExited &&
                                (exitStatus == null || exitStatus < 0) &&
                                (isConnected || reconnecting)

                            assertEquals(
                                "connected=$isConnected reconnecting=$reconnecting userClosed=$userClosed " +
                                    "remoteExited=$remoteExited exitStatus=$exitStatus",
                                if (expected) listOf("session") else emptyList(),
                                terminalNavigationSessionIds(listOf("session"), listOf(candidate)),
                            )
                        }
                    }
                }
            }
        }
    }

    @Test
    fun splitPaneSelectionIsOrderedDeduplicatedAndExcludesBackgroundSessions() {
        val sessions = listOf(
            candidate("pane-1", isConnected = true),
            candidate("pane-2", reconnecting = true),
            candidate("background", isConnected = true),
        )

        assertEquals(
            listOf("pane-2", "pane-1"),
            terminalNavigationSessionIds(
                attachedIds = listOf("pane-2", "pane-1", "pane-2", null),
                candidates = sessions,
            ),
        )
    }

    @Test
    fun mixedPaneTypesMapToTheirOwnLifecycleActionInEitherOrder() {
        val paneTypes = listOf(false, true)
        for (orderedTypes in listOf(paneTypes, paneTypes.reversed())) {
            assertEquals(
                orderedTypes.map {
                    if (it) TerminalLeaveAction.LEAVE_RESUMABLE
                    else TerminalLeaveAction.SEND_TO_BACKGROUND
                },
                orderedTypes.map { terminalLeaveAction(persistent = it, disconnect = false) },
            )
            assertEquals(
                listOf(TerminalLeaveAction.DISCONNECT, TerminalLeaveAction.DISCONNECT),
                orderedTypes.map { terminalLeaveAction(persistent = it, disconnect = true) },
            )
        }
    }

    @Test
    fun exitedPaneIsDroppedWhileRemainingPaneGetsOneTransaction() {
        val sessions = listOf(
            candidate("exited", isConnected = true, remoteExited = true, exitStatus = 0),
            candidate("live", isConnected = true),
        )

        assertEquals(
            listOf("live"),
            terminalNavigationSessionIds(listOf("exited", "live"), sessions),
        )
    }

    @Test
    fun randomizedSplitStatesAlwaysPreserveCoreInvariants() {
        val random = Random(0x4f4d4e49)
        repeat(10_000) { iteration ->
            val candidates = List(random.nextInt(0, 8)) { index ->
                candidate(
                    id = "s$index",
                    isConnected = random.nextBoolean(),
                    reconnecting = random.nextBoolean(),
                    userClosed = random.nextBoolean(),
                    remoteExited = random.nextBoolean(),
                    exitStatus = listOf<Int?>(null, -1, 0, 1, 130).random(random),
                )
            }
            val attached = List(random.nextInt(0, 8)) {
                if (random.nextInt(5) == 0) null else "s${random.nextInt(0, 10)}"
            }
            val result = terminalNavigationSessionIds(attached, candidates)
            val byId = candidates.associateBy { it.id }

            assertEquals("iteration=$iteration must not duplicate ids", result.distinct(), result)
            assertTrue("iteration=$iteration must remain pane ordered", isSubsequence(result, attached.filterNotNull()))
            result.forEach { id ->
                val session = requireNotNull(byId[id])
                assertFalse(session.userClosed)
                assertFalse(session.remoteExited)
                assertTrue(session.exitStatus == null || session.exitStatus < 0)
                assertTrue(session.isConnected || session.reconnecting)
            }
        }
    }

    private fun candidate(
        id: String,
        isConnected: Boolean = false,
        reconnecting: Boolean = false,
        userClosed: Boolean = false,
        remoteExited: Boolean = false,
        exitStatus: Int? = null,
    ) = TerminalNavigationCandidate(
        id = id,
        isConnected = isConnected,
        reconnecting = reconnecting,
        userClosed = userClosed,
        remoteExited = remoteExited,
        exitStatus = exitStatus,
    )

    private fun isSubsequence(values: List<String>, source: List<String>): Boolean {
        var cursor = 0
        for (value in source) {
            if (cursor < values.size && values[cursor] == value) cursor++
        }
        return cursor == values.size
    }
}
