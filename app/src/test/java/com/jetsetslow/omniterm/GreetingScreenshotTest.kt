package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = RobolectricDeviceQualifiers.Pixel8, sdk = [35])
class GreetingScreenshotTest {

  @get:Rule val composeTestRule = createComposeRule()

  @Test
  fun greeting_screenshot() {
    assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
    composeTestRule.setContent { MyApplicationTheme { androidx.compose.material3.Text("Robolectric") } }

    composeTestRule.onRoot().captureRoboImage(filePath = "src/test/screenshots/greeting.png")
  }

  private fun isLinuxAarch64(): Boolean =
    System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
      System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
