package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test

class GlobalAlertsPopupTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun popupOverlaysEveryTabWithoutChangingNavigation() {
        val viewModel = ViewModelProvider(composeTestRule.activity)[AppViewModel::class.java]

        listOf(Screen.Servers, Screen.Infra, Screen.Shell).forEach { screen ->
            composeTestRule.runOnUiThread {
                viewModel.navigateTo(screen)
                // On Shell this makes ordinary navigation enter the disconnect gate, proving the
                // popup intent takes the navigation-free path even during a connect attempt.
                viewModel.isTerminalConnecting = screen == Screen.Shell
                viewModel.openAlertsPopup()
            }

            composeTestRule.onNodeWithText("Active alerts").assertIsDisplayed()
            composeTestRule.onNodeWithText("No active alert incidents.").assertIsDisplayed()
            assertEquals(screen, viewModel.currentScreen)
            assertFalse(viewModel.showDisconnectTerminalDialog)

            composeTestRule.onNodeWithContentDescription("Close alerts popup").performClick()
            composeTestRule.waitForIdle()
            assertFalse(viewModel.showAlertsPopup)
            assertEquals(screen, viewModel.currentScreen)
        }

        composeTestRule.runOnUiThread { viewModel.isTerminalConnecting = false }
    }
}
