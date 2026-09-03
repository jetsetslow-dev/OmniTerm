package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Device proof that a refused force-connect cannot collapse back into an unexplained empty page. */
class E2eDirectSshFailureFeedbackTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun refusedOfflineSshStaysVisibleAndRetryable() {
        runBlocking {
            assumeTrue(
                InstrumentationRegistry.getArguments().getString("omniterm_e2e_ssh_failure") == "yes",
            )
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val repository = AppRepository(AppDatabase.getDatabase(context))
            val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
            val name = "E2E Refused SSH"

            repository.getAllServers().filter { it.name == name }
                .forEach { repository.deleteServerAndDependents(it.id) }
            val id = repository.insertServer(
                ServerEntity(
                    name = name,
                    host = "127.0.0.1",
                    port = 1,
                    username = "root",
                    status = "offline",
                ),
            ).toInt()

            try {
                composeRule.waitUntil(10_000) { vm.servers.value.any { it.id == id } }
                composeRule.runOnUiThread {
                    vm.isAppLocked = false
                    vm.selectedServerId = id
                    vm.probedServerIds[id] = true
                    vm.navigateTo(Screen.Shell)
                    vm.connectTerminal()
                }
                composeRule.waitUntil(5_000) { vm.offlineConnectPromptServer?.id == id }
                composeRule.runOnUiThread { vm.connectTerminalConfirmedOffline() }
                composeRule.waitUntil(15_000) {
                    !vm.isTerminalConnecting && !vm.terminalConnectError.isNullOrBlank()
                }

                composeRule.onNodeWithText("CONNECTION FAILED").assertExists()
                composeRule.onNodeWithText("Retry").assertExists()
            } finally {
                repository.deleteServerAndDependents(id)
            }
        }
    }
}
