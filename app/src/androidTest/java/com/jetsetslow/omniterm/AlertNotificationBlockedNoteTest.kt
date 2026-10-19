package com.jetsetslow.omniterm

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import com.jetsetslow.omniterm.ui.AlertNotificationBlockedNote
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Rule
import org.junit.Test

/** Alerts that fire while notifications are blocked must say so; otherwise the screen is unchanged. */
class AlertNotificationBlockedNoteTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun noteAppearsOnlyWhileAlertsAreOnAndNotificationsBlocked() {
        var alertsEnabled by mutableStateOf(true)
        var allowed by mutableStateOf(false)
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                AlertNotificationBlockedNote(alertsEnabled = alertsEnabled, notificationsAllowed = allowed)
            }
        }
        composeTestRule.onNodeWithTag("alerts.notificationWarning").assertIsDisplayed()

        allowed = true
        composeTestRule.onNodeWithTag("alerts.notificationWarning").assertDoesNotExist()

        allowed = false
        alertsEnabled = false
        composeTestRule.onNodeWithTag("alerts.notificationWarning").assertDoesNotExist()
    }
}
