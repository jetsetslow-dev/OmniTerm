package com.jetsetslow.omniterm

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.PodmanModifiersEditor
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class PodmanModifiersUiTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun togglesSynchronizeKeepIdAndPodSettingsImmediately() {
        lateinit var latest: ComposeStackDraft
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                var draft by remember {
                    mutableStateOf(
                        ComposeStackDraft(
                            runtime = "podman",
                            services = mutableListOf(
                                ComposeServiceDraft(serviceName = "api", image = "api:latest"),
                                ComposeServiceDraft(serviceName = "worker", image = "worker:latest"),
                            ),
                        ),
                    )
                }
                latest = draft
                PodmanModifiersEditor(draft = draft) { draft = it }
            }
        }

        composeTestRule.onNodeWithTag("podman-modifiers").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("Rootless keep-ID mapping").performClick()
        composeTestRule.runOnIdle {
            assertEquals(listOf("keep-id", "keep-id"), latest.services.map { it.usernsMode })
        }

        composeTestRule.onNodeWithContentDescription("Group services in a Podman pod").performClick()
        composeTestRule.onNodeWithTag("podman-pod-name").performTextInput("edge-pod")
        composeTestRule.runOnIdle {
            assertTrue(latest.podmanPodEnabled)
            assertEquals("edge-pod", latest.podmanPodName)
        }
    }
}
