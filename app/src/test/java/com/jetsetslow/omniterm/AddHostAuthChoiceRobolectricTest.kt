package com.jetsetslow.omniterm

import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.ui.AddServerSheet
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
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

/** Adding a host, the sign-in method's label picks it, not only the small circle beside it. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class AddHostAuthChoiceRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun tappingALabelPicksThatSignInMethod() {
        assumeFalse(
            "Robolectric native runtime is not available on Linux aarch64 hosts.",
            System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
                System.getProperty("os.arch").equals("aarch64", ignoreCase = true),
        )
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val model = runBlocking { withContext(main) { AppViewModel(application) } }
            store.put("test", model)
            composeTestRule.setContent {
                MyApplicationTheme {
                    CompositionLocalProvider(LocalLifecycleOwner provides AnyThreadLifecycle) {
                        AddServerSheet(model, serverToEdit = null, onDismiss = {})
                    }
                }
            }
            composeTestRule.onNodeWithText("Credentials").performClick()
            composeTestRule.waitUntil(10_000) { composeTestRule.onAllNodesWithText("SSH Private Key").fetchSemanticsNodes().isNotEmpty() }
            // Password is picked to start with, so its field shows; picking a key replaces it.
            check(composeTestRule.onAllNodesWithText("SSH Password").fetchSemanticsNodes().isNotEmpty())

            composeTestRule.onNodeWithText("SSH Private Key").performClick()
            composeTestRule.waitUntil(10_000) {
                composeTestRule.onAllNodesWithText("SSH Password").fetchSemanticsNodes().isEmpty()
            }
        } finally {
            runBlocking {
                try {
                    clearViewModelsAndAwaitTerminalJobs(store, main)
                } finally {
                    Dispatchers.resetMain()
                    main.close()
                }
            }
        }
    }

    /** A resumed lifecycle that may be observed from any thread, as the view model's main is a test thread. */
    private object AnyThreadLifecycle : LifecycleOwner {
        override val lifecycle: Lifecycle = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.RESUMED }
    }
}
