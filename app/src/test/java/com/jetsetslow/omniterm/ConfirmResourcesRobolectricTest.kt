package com.jetsetslow.omniterm

import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.jetsetslow.omniterm.ui.ConfirmHost
import com.jetsetslow.omniterm.ui.rememberConfirm
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Confirmation text now comes from string resources resolved inside a click handler, through the
 * resources `rememberConfirm()` gives its controller. If that hand-over were missing, every
 * confirmation in the app would throw the moment its button was tapped.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class ConfirmResourcesRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    @Test
    fun aConfirmationQueuedFromAClickShowsItsResourceText() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        composeTestRule.setContent {
            MyApplicationTheme {
                val confirm = rememberConfirm()
                ConfirmHost(confirm)
                Button(onClick = {
                    confirm.ask(
                        confirm.str(R.string.delete_3, "notes.txt"),
                        confirm.str(R.string.removes_this_saved_share_profile_files),
                        confirmLabel = confirm.str(R.string.delete),
                    ) {}
                }) { Text("Ask") }
            }
        }

        composeTestRule.onNodeWithText("Ask").performClick()

        composeTestRule.onNodeWithText("Delete \"notes.txt\"?").assertExists()
        composeTestRule.onNodeWithText("Removes this saved share profile. Files on the share are not touched.")
            .assertExists()
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
