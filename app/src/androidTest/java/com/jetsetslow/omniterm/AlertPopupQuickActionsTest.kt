package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.data.ActiveAlertEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AlertPopupHeader
import com.jetsetslow.omniterm.ui.AlertPopupIncidentCard
import com.jetsetslow.omniterm.ui.AlertPopupIncidentList
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

    @Test
    fun multipleIncidentsRemainScrollableToTheLastAlert() {
        val alerts = (1..12).map { id ->
            alert(id = id, metricName = "Metric $id")
        }
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true) {
                Box(Modifier.height(220.dp)) {
                    AlertPopupIncidentList(
                        active = alerts,
                        muted = emptyList(),
                        servers = emptyList(),
                        onRefresh = {},
                        onAcknowledge = {},
                        onMute = {},
                        onUnmute = {},
                    )
                }
            }
        }

        composeTestRule.onNodeWithTag("alerts-popup-list").performScrollToIndex(11)
        composeTestRule.onNodeWithText("Metric 12").assertIsDisplayed()
    }

    @Test
    fun popupHeaderAndIncidentTextFollowAppFontScale() {
        val fontScale = mutableFloatStateOf(1f)
        composeTestRule.setContent {
            MyApplicationTheme(darkTheme = true, fontScale = fontScale.floatValue) {
                Column {
                    AlertPopupHeader(
                        activeCount = 1,
                        mutedCount = 0,
                        onAcknowledgeAll = {},
                        onDismiss = {},
                    )
                    AlertPopupIncidentCard(
                        alert = alert(),
                        server = null,
                        muted = false,
                        onRefresh = {},
                        onAcknowledge = {},
                        onMuteToggle = {},
                    )
                }
            }
        }

        val baseHeaderHeight = composeTestRule.onNodeWithText("Active alerts")
            .fetchSemanticsNode().boundsInRoot.height
        val baseIncidentHeight = composeTestRule.onNodeWithText("CPU Usage")
            .fetchSemanticsNode().boundsInRoot.height

        composeTestRule.runOnIdle { fontScale.floatValue = 1.5f }
        composeTestRule.waitForIdle()

        val scaledHeaderHeight = composeTestRule.onNodeWithText("Active alerts")
            .fetchSemanticsNode().boundsInRoot.height
        val scaledIncidentHeight = composeTestRule.onNodeWithText("CPU Usage")
            .fetchSemanticsNode().boundsInRoot.height
        assertTrue("Popup header ignored app font scale", scaledHeaderHeight > baseHeaderHeight)
        assertTrue("Incident text ignored app font scale", scaledIncidentHeight > baseIncidentHeight)
    }

    private fun alert(
        id: Int = 11,
        metricName: String = "CPU Usage",
    ) = ActiveAlertEntity(
        id = id,
        ruleId = 2,
        serverId = 7,
        metricName = metricName,
        currentValue = 97f,
        thresholdValue = 90f,
        severity = "CRITICAL",
        triggeredTime = 1L,
    )
}
