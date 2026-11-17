package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.data.ssh.InteractiveAuthRequest
import com.jetsetslow.omniterm.data.ssh.AuthPrompt
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TmuxControlCommands
import com.jetsetslow.omniterm.ui.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/** Exercises the production input choke point with bounded real session queues. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalTypingInputRobolectricTest {
    @Test fun offByDefaultAndAChosenSetDoesNotIncludeAnUnselectedHost() = exercise {
        model.typeText("one")
        assertEquals("one", drain(first))
        assertEquals("", drain(second))
        model.selectTerminalTyping(setOf(second.id))
        model.typeText("two")
        assertEquals("", drain(first))
        assertEquals("two", drain(second))
        model.stopTerminalTyping()
        model.typeText("single")
        assertEquals("single", drain(first))
        assertEquals("", drain(second))
    }

    @Test fun allOpenIsAFixedSnapshotAndChangingTheSetTakesEffectImmediately() = exercise {
        all()
        val later = add("later")
        model.typeText("a")
        assertEquals("a", drain(first))
        assertEquals("a", drain(second))
        assertEquals("", drain(later))
        model.selectTerminalTyping(setOf(later.id))
        model.typeText("b")
        assertEquals("", drain(first))
        assertEquals("", drain(second))
        assertEquals("b", drain(later))
    }

    @Test fun lockedReceiverIsExcluded() = exclusion("locked")
    @Test fun disconnectedReceiverIsExcluded() = exclusion("disconnected")
    @Test fun reconnectingReceiverIsExcluded() = exclusion("reconnecting")
    @Test fun closedTransportIsExcluded() = exclusion("closed")

    private fun exclusion(reason: String) = exercise {
        all()
        second.inputLocked = reason == "locked"
        second.isConnected = reason != "disconnected"
        second.reconnecting = reason == "reconnecting"
        (second.session as TypingFixtureTransport).closed.value = reason == "closed"
        model.typeText(reason)
        assertEquals(reason, drain(first))
        assertEquals("", drain(second))
        assertNotNull(model.terminalTyping.exclusion(second))
    }

    @Test fun inputButtonLocksOnlyItsSessionAndLockedSourceCannotFanOut() = exercise {
        all()
        model.updateTerminalReadOnly(true)
        assertTrue(first.inputLocked)
        assertFalse(second.inputLocked)
        model.typeText("password")
        model.sendKey(TermKey.ENTER)
        model.pasteText("paste")
        model.applyLineEdit(1, "edit")
        assertEquals("", drain(first))
        assertEquals("", drain(second))
        model.currentSessionId = second.id
        assertFalse(model.terminalReadOnly)
        model.typeText("ok")
        assertEquals("", drain(first))
        assertEquals("ok", drain(second))
    }

    @Test fun textControlKeysExtraKeysSwipeEditsPasteAndPasswordsKeepTheirOrder() = exercise {
        all()
        model.typeText("sudo fixture")
        model.sendKey(TermKey.ENTER)
        model.typeText("fixture-password")
        model.sendKey(TermKey.ENTER)
        model.isCtrlPressed = true
        model.typeText("c")
        model.sendKey(TermKey.TAB)
        model.sendKey(TermKey.UP)
        model.applyLineEdit(2, "xy")
        model.pasteText("paste")
        val expected = "sudo fixture\rfixture-password\r\u0003\t\u001B[A\u007F\u007Fxypaste"
        assertEquals(expected, drain(first))
        assertEquals(expected, drain(second))
    }

    @Test fun eachReceiverUsesItsOwnBracketedPasteAndTmuxPane() = exercise {
        all()
        second.emulator.feed("\u001B[?2004h".toByteArray())
        second.controlMode = true
        second.controlReady = true
        second.activePaneId = "%7"
        model.pasteText("ab")
        assertEquals("ab", drain(first))
        val expected = bracketedPastePayload("ab", true).toByteArray()
        assertEquals(TmuxControlCommands.sendKeysHex("%7", expected).joinToString("") { "$it\n" }, drain(second))
    }

    @Test fun aReceiverStillWritingAnEarlierPasteDoesNotLoseTheNextPaste() = exercise {
        all()
        second.pasteFeedback = TerminalPasteFeedback("Earlier paste is still sending", busy = true)
        model.pasteText("later", model.captureTerminalPasteTarget(first), confirmed = true)
        assertEquals("later", drain(first))
        assertEquals("later", drain(second))
    }

    @Test fun multilinePasteWaitsOnceAndConfirmationKeepsEveryNewline() = exercise {
        all()
        model.pasteText("one\r\ntwo\n")
        val pending = checkNotNull(model.pendingTerminalPaste)
        assertEquals(2, pending.target.receivers!!.size)
        assertEquals("", drain(first))
        assertEquals("", drain(second))
        model.pendingTerminalPaste = null
        model.pasteText(pending.text, pending.target, confirmed = true)
        assertNull(model.pendingTerminalPaste)
        assertEquals("one\rtwo\r", drain(first))
        assertEquals("one\rtwo\r", drain(second))
    }

    @Test fun cancelledPasteSendsNothing() = exercise {
        all()
        model.pasteText("one\ntwo")
        model.cancelTerminalPaste(checkNotNull(model.pendingTerminalPaste).target)
        model.pendingTerminalPaste = null
        assertEquals("", drain(first))
        assertEquals("", drain(second))
    }

    @Test fun confirmationCannotFollowSelectionChange() = stalePaste("selection")
    @Test fun confirmationCannotFollowFocusChange() = stalePaste("focus")
    @Test fun confirmationCannotFollowConnectionChange() = stalePaste("connection")
    @Test fun confirmationCannotFollowInputLock() = stalePaste("lock")
    @Test fun confirmationCannotFollowReconnect() = stalePaste("reconnect")
    @Test fun confirmationCannotFollowTmuxPaneChange() = stalePaste("pane")

    private fun stalePaste(change: String) = exercise {
        all()
        val target = model.captureTerminalPasteTarget(first)
        when (change) {
            "selection" -> model.selectTerminalTyping(setOf(first.id))
            "focus" -> model.currentSessionId = second.id
            "connection" -> second.session = TypingFixtureTransport()
            "lock" -> second.inputLocked = true
            "reconnect" -> second.reconnecting = true
            "pane" -> second.controlMode = true
        }
        model.pasteText("must not arrive", target, confirmed = true)
        assertEquals(change, "", drain(first))
        assertEquals(change, "", drain(second))
    }

    @Test fun appPasswordAndSudoQuestionsKeepTheirOwnAnswerChannels() = exercise {
        all()
        val question = PendingInteractiveAuth("first", InteractiveAuthRequest("fixture", "", "",
            listOf(AuthPrompt("Password", false))))
        model.javaClass.getDeclaredMethod("setPendingInteractiveAuth", PendingInteractiveAuth::class.java)
            .apply { isAccessible = true }.invoke(model, question)
        model.answerInteractiveAuth(listOf("fixture-answer"))
        assertEquals(listOf("fixture-answer"), question.reply.getCompleted())
        var sudoAnswered = false
        val sudo = AppViewModel.PendingSudoAction("first") { sudoAnswered = true }
        model.javaClass.getDeclaredMethod("setPendingSudoAction", AppViewModel.PendingSudoAction::class.java)
            .apply { isAccessible = true }.invoke(model, sudo)
        model.confirmPendingSudoAction()
        assertTrue(sudoAnswered)
        assertEquals("", drain(first))
        assertEquals("", drain(second))
    }

    @Test fun appLockClearsSelectionAndPendingPasteAndBlocksInputAndEnable() = exercise {
        all()
        model.pasteText("one\ntwo")
        model.isAppLocked = true
        assertFalse(model.terminalTyping.enabled)
        assertNull(model.pendingTerminalPaste)
        all()
        assertFalse(model.terminalTyping.enabled)
        model.typeText("blocked")
        assertEquals("", drain(first))
        model.isAppLocked = false
        model.typeText("single")
        assertEquals("single", drain(first))
        assertEquals("", drain(second))
    }

    @Test fun restartingUiWithKeptAliveShellsTurnsTypingOff() = exercise {
        all()
        assertTrue(model.terminalTyping.enabled)
        val restarted = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        store.put("restarted", restarted)
        assertFalse(restarted.terminalTyping.enabled)
        assertEquals(2, restarted.activeSessions.size)
    }

    @Test fun closingLastReceiverTurnsItOffEvenWithOtherSessionsOpen() = exercise {
        model.selectTerminalTyping(setOf(second.id))
        TerminalSessionManager.cleanupSession(second)
        assertFalse(model.terminalTyping.enabled)
        assertTrue(first in model.activeSessions)
    }

    @Test fun endedReceiverIsRemovedAndNewRuntimeStateStartsOff() = exercise {
        model.selectTerminalTyping(setOf(second.id))
        TerminalSessionManager.endSessionKeepingScrollback(second, 0)
        assertFalse(model.terminalTyping.enabled)
        assertFalse(TerminalTyping().enabled)
    }

    @Test fun mouseScrollingAndResizeStayOnTheirOwnSession() = exercise {
        all()
        first.persistent = true
        model.terminalMouseWheelFor(first, wheelUp = true)
        model.terminalSendPageKeysFor(first, up = true, count = 1)
        model.resizeTerminalFor(first, 90, 30)
        assertEquals("\u001B[<64;1;1M\u001B[5~", drain(first))
        assertEquals("", drain(second))
    }

    private class Fixture(val store: ViewModelStore) {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val first = add("first")
        val second = add("second")
        init { store.put("typing", model); model.currentSessionId = first.id }
        fun add(name: String): ShellSession = ShellSession(0, name, TypingFixtureTransport(), TerminalEmulator()).apply {
            terminalInputQueue = TerminalInputQueue()
            TerminalSessionManager.addSession(this)
        }
        fun all() = model.selectTerminalTyping(model.activeSessions.map { it.id }.toSet())
        fun drain(shell: ShellSession): String = buildString {
            val queue = checkNotNull(shell.terminalInputQueue)
            while (true) {
                val bytes = queue.channel.tryReceive().getOrNull() ?: break
                append(bytes.decodeToString())
                if (queue.beginWrite(bytes)) queue.finishWrite(bytes, TerminalWriteOutcome.ACCEPTED)
            }
        }
    }

    private fun exercise(block: Fixture.() -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            withContext(main) {
                TerminalSessionManager.clearAll()
                val fixture = Fixture(store)
                fixture.block()
            }
        } finally {
            clearViewModelsAndAwaitTerminalJobs(store, main)
            Dispatchers.resetMain()
            main.close()
        }
    }

}

internal class TypingFixtureTransport : TerminalSession {
    override val output = emptyFlow<ByteArray>()
    override val closed = MutableStateFlow(false)
    override val exitStatus = MutableStateFlow<Int?>(null)
    override val remoteExited = MutableStateFlow(false)
    override suspend fun write(bytes: ByteArray) = Unit
    override suspend fun resize(cols: Int, rows: Int) = Unit
    override fun close() { closed.value = true }
}
