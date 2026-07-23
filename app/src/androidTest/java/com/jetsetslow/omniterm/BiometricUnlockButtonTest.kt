package com.jetsetslow.omniterm

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.ui.BiometricUnlockButton
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class BiometricUnlockButtonTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun fingerprintAffordanceIsVisibleAccessibleAndClickableOnLockBackground() {
        var clicked = false
        composeTestRule.setContent {
            MaterialTheme {
                Box(Modifier.background(Color.Black).padding(24.dp)) {
                    BiometricUnlockButton { clicked = true }
                }
            }
        }

        composeTestRule.onNodeWithContentDescription("Use fingerprint to unlock")
            .assertIsDisplayed()
            .performClick()
        composeTestRule.onNodeWithText("Use biometrics").assertIsDisplayed()
        composeTestRule.runOnIdle { assertTrue(clicked) }
    }
}
