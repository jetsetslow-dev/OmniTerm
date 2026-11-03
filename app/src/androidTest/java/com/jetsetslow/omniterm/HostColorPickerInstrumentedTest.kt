package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.theme.OmniColors
import org.junit.Rule
import org.junit.Test

/** Exercise the real host form; no server is saved or contacted by this check. */
class HostColorPickerInstrumentedTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun namedChoicesWrapAndAutomaticCanBeRestoredInBothThemes() {
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val originalTheme = vm.isDarkModeEnabled
        try {
            for (dark in listOf(true, false)) {
                composeRule.runOnUiThread {
                    vm.isAppLocked = false
                    vm.saveDarkModeToggle(dark)
                    vm.navigateTo(Screen.Servers)
                }
                composeRule.waitUntil(10_000) { vm.isDarkModeEnabled == dark }
                composeRule.onNodeWithContentDescription("Add server").performClick()
                composeRule.onNodeWithText("Automatic").performScrollTo().assertIsDisplayed()
                composeRule.onNodeWithTag("host.color.Default").assertIsSelected()
                for ((name, _) in OmniColors.namedColors) {
                    val chip = composeRule.onNodeWithTag("host.color.$name")
                    chip.performScrollTo().assertIsDisplayed().performClick().assertIsSelected()
                    composeRule.onNodeWithTag("host.color.Default").assertIsNotSelected()
                }
                composeRule.onNodeWithTag("host.color.Default").performScrollTo().performClick().assertIsSelected()
                composeRule.onNodeWithTag("host.color.Ocean").assertIsNotSelected()
                composeRule.onNodeWithText("Cancel").performClick()
            }
        } finally {
            composeRule.runOnUiThread { vm.saveDarkModeToggle(originalTheme) }
        }
    }
}
