package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.ActionStreamDialog
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.rememberDismissKeyboard
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors

/**
 * Starting output hides the keyboard, so it does not cover the output it started. Ping in Tools left
 * it up; every action that starts output now hides it, and the shared output panel that service,
 * container, compose, process and quick-check actions open hides it for all of them.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class KeyboardHidesWhenOutputStartsRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun anActionThatStartsOutputTakesFocusFromTheField() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        composeTestRule.setContent {
            MyApplicationTheme {
                val dismissKeyboard = rememberDismissKeyboard()
                Column {
                    Field()
                    Button(onClick = dismissKeyboard) { Text("Run") }
                }
            }
        }
        focusField()

        composeTestRule.onNodeWithText("Run").performClick()
        awaitFieldUnfocused()
    }

    @Test
    fun theSharedOutputPanelTakesFocusFromTheScreenBehindIt() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val repo = AppRepository(AppDatabase.getDatabase(application))
        var id = 0
        try {
            val model = runBlocking {
                id = repo.insertServer(
                    ServerEntity(name = "Keyboard fixture", host = "fixture.invalid", username = "fixture", status = "online"),
                ).toInt()
                val model = withContext(main) { AppViewModel(application, AnsweringHost()) }
                store.put("test", model)
                waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
                model
            }
            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides AnyThreadLifecycle) {
                        Column {
                            Field()
                            ActionStreamDialog(model)
                        }
                    }
                }
            }
            focusField()

            runBlocking {
                withContext(main) {
                    model.runStreamingAction("uptime", "uptime", server = model.servers.value.first { it.id == id })
                }
            }
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithTextCount(HOST_OUTPUT) > 0
            }
            awaitFieldUnfocused()
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                    repo.getServerById(id)?.let { repo.deleteServer(it) }
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun Field() {
        var text by remember { mutableStateOf("") }
        OutlinedTextField(value = text, onValueChange = { text = it }, modifier = Modifier.testTag(FIELD))
    }

    private fun focusField() {
        composeTestRule.onNodeWithTag(FIELD).performClick()
        composeTestRule.onNodeWithTag(FIELD).assertIsFocused()
    }

    private fun awaitFieldUnfocused() {
        val focused = SemanticsMatcher.expectValue(SemanticsProperties.Focused, true)
        composeTestRule.waitUntil(10_000) {
            !focused.matches(composeTestRule.onNodeWithTag(FIELD).fetchSemanticsNode())
        }
    }

    private fun androidx.compose.ui.test.junit4.ComposeTestRule.onAllNodesWithTextCount(text: String): Int =
        onAllNodes(androidx.compose.ui.test.hasText(text, substring = true), useUnmergedTree = true)
            .fetchSemanticsNodes().size

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)

    /** A resumed lifecycle that may be observed from the test's own main thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }

    /** A host whose `uptime` prints [HOST_OUTPUT]; everything else gets nothing. */
    private class AnsweringHost : SshTransport {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            if (command != "uptime") return ""
            onChunk("$HOST_OUTPUT\n")
            return "$HOST_OUTPUT\n"
        }

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = IdleShell()
    }

    private class IdleShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }

    private companion object {
        const val FIELD = "keyboard.field"
        const val HOST_OUTPUT = "up 3 days, load 0.42"
    }
}
