package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.VisualEditor
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ComposeBuilderStateSyncTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun addingPortAndEnvironmentRowsImmediatelyUpdatesDraft() {
        lateinit var latest: ComposeStackDraft
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                var draft by remember {
                    mutableStateOf(
                        ComposeStackDraft(
                            services = mutableListOf(
                                ComposeServiceDraft(serviceName = "web", image = "nginx", isExpanded = true),
                            ),
                        ),
                    )
                }
                latest = draft
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    VisualEditor(draft) { draft = it }
                }
            }
        }

        composeTestRule.onNodeWithContentDescription("Add Ports (host:container)")
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        composeTestRule.onNodeWithTag("compose-list-Ports (host:container)-item-0")
            .performScrollTo()
            .performTextInput("8080:80")
        composeTestRule.runOnIdle {
            assertEquals(listOf("8080:80"), latest.services.single().ports)
        }

        composeTestRule.onNodeWithContentDescription("Add Environment (KEY=VALUE)")
            .performScrollTo()
            .assertIsDisplayed()
            .performClick()
        composeTestRule.onNodeWithTag("compose-list-Environment (KEY=VALUE)-item-0")
            .performScrollTo()
            .performTextInput("NODE_ENV=production")
        composeTestRule.runOnIdle {
            assertEquals(listOf("NODE_ENV=production"), latest.services.single().environment)
        }
    }
}
