package com.jetsetslow.omniterm

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Unattended entry points and backup code must never acquire interactive terminal capabilities. */
class TerminalTypingBoundaryTest {
    private val root = listOf(File("src/main/java"), File("app/src/main/java")).first { it.isDirectory }

    @Test fun onlyTerminalUiMaySelectReceiversOrTypeInteractiveInput() {
        val permitted = setOf("AppViewModel.kt", "ShellScreen.kt", "TerminalTypingUi.kt")
        val calls = Regex("""\b(selectTerminalTyping|stopTerminalTyping|typeText|pasteText|sendKey|applyLineEdit)\s*\(""")
        val offenders = root.walkTopDown().filter { it.extension == "kt" && it.name !in permitted }
            .filter { calls.containsMatchIn(it.readText()) }.map { it.name }.toList()
        assertTrue("Unattended code must use isolated command channels: $offenders", offenders.isEmpty())
    }

    @Test fun appCredentialAnswersNeverUseInteractiveInput() {
        val model = root.walkTopDown().first { it.name == "AppViewModel.kt" }.readText()
        for ((start, end) in listOf(
            "    fun answerInteractiveAuth(" to "    // Approvals beyond",
            "    private fun withSudoAuth(" to "    /** Reboot the selected host",
        )) {
            val body = model.substringAfter(start).substringBefore(end)
            assertFalse("Credential answers must stay per session",
                Regex("""\b(sendBytes|sendBytesTo|typeText|pasteText|sendKey)\s*\(""").containsMatchIn(body))
        }
    }

    @Test fun runtimeReceiverStateCannotEnterStorageOrUnattendedCode() {
        val permitted = setOf("AppViewModel.kt", "ShellScreen.kt", "TerminalSessionManager.kt", "TerminalTyping.kt", "TerminalTypingUi.kt")
        val offenders = root.walkTopDown().filter { it.extension == "kt" && it.name !in permitted }
            .filter { it.readText().contains("terminalTyping") || it.readText().contains("TerminalTyping(") }
            .map { it.name }.toList()
        assertTrue("Receiver state belongs only to the runtime terminal UI: $offenders", offenders.isEmpty())
        val model = root.walkTopDown().first { it.name == "AppViewModel.kt" }.readText()
        // Settings and backup writers use these APIs. Do not serialize typing state inline there.
        assertFalse(Regex("""(?i)(insertSetting|put|addProperty)\([^\n]*(terminalTyping|typing_receivers|typing_enabled)""").containsMatchIn(model))
    }
}
