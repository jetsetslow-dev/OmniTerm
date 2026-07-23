package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.performClick
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AlertPopupIncidentCard
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

class AlertPopupQuickActionsTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun firingIncidentExposesRefreshAcknowledgeAndMuteActions() {
        val actions = mutableListOf<String>()
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                AlertPopupIncidentCard(
                    alert = alert(),
                    server = ServerEntity(
                        id = 7,
                        name = "Edge node",
                        host = "edge.example",
                        username = "ops",
                    ),
                    muted = false,
                    onRefresh = { actions += "refresh" },
                    onAcknowledge = { actions += "acknowledge" },
                    onMuteToggle = { actions += "mute" },
                )
            }
        }

        composeTestRule.onNodeWithText("REFRESH").assertIsDisplayed().performClick()
        composeTestRule.onNodeWithText("ACKNOWLEDGE").assertIsDisplayed().performClick()
        composeTestRule.onNodeWithText("MUTE 1H").assertIsDisplayed().performClick()
        composeTestRule.runOnIdle {
            assertEquals(listOf("refresh", "acknowledge", "mute"), actions)
        }
    }

    @Test
    fun mutedIncidentOffersUnmuteWithoutAcknowledge() {
        var unmuted = false
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                AlertPopupIncidentCard(
                    alert = alert().copy(mutedUntil = Long.MAX_VALUE),
                    server = null,
                    muted = true,
                    onRefresh = {},
                    onAcknowledge = null,
                    onMuteToggle = { unmuted = true },
                )
            }
        }

        composeTestRule.onAllNodesWithText("ACKNOWLEDGE").assertCountEquals(0)
        composeTestRule.onNodeWithText("UNMUTE").assertIsDisplayed().performClick()
        composeTestRule.runOnIdle { assertTrue(unmuted) }
    }

    private fun alert() = ActiveAlertEntity(
        id = 11,
        ruleId = 2,
        serverId = 7,
        metricName = "CPU Usage",
        currentValue = 97f,
        thresholdValue = 90f,
        severity = "CRITICAL",
        triggeredTime = 1L,
    )
}
