package com.jetsetslow.omniterm

import android.os.ParcelFileDescriptor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.BiometricCryptoGate
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in visual fixture for capturing Android's app-branded biometric prompt on a real device. */
class E2eBiometricPromptVisualTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun monochromeAdaptiveIconContainsTransparentLogoGeometry() {
        val drawable = composeRule.activity.getDrawable(R.mipmap.ic_launcher)
        assertTrue("Launcher icon is not adaptive", drawable is AdaptiveIconDrawable)
        val monochrome = requireNotNull((drawable as AdaptiveIconDrawable).monochrome)
        val bitmap = Bitmap.createBitmap(216, 216, Bitmap.Config.ARGB_8888)
        monochrome.setBounds(0, 0, bitmap.width, bitmap.height)
        monochrome.draw(Canvas(bitmap))
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val visibleFraction = pixels.count { (it ushr 24) != 0 }.toDouble() / pixels.size
        assertTrue("Monochrome icon is effectively empty: $visibleFraction", visibleFraction > 0.05)
        assertTrue("Monochrome icon is an opaque tile: $visibleFraction", visibleFraction < 0.55)
        val darkVisibleFraction = pixels.count {
            val alpha = it ushr 24
            val red = it ushr 16 and 0xff
            val green = it ushr 8 and 0xff
            val blue = it and 0xff
            alpha != 0 && red + green + blue < 3 * 64
        }.toDouble() / pixels.size
        assertTrue(
            "Monochrome mark has no untinted contrast for a light biometric surface",
            darkVisibleFraction > 0.05,
        )
    }

    @Test
    fun manifestExposesExplicitApplicationAndActivityLogos() {
        val appInfo = composeRule.activity.applicationInfo
        val activityInfo = composeRule.activity.packageManager.getActivityInfo(
            composeRule.activity.componentName,
            0,
        )
        assertEquals(R.mipmap.ic_launcher, appInfo.logo)
        assertEquals(R.mipmap.ic_launcher, activityInfo.logo)
    }

    @Test
    fun showsBrandedSystemPromptLongEnoughForVisualInspection() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_biometric_visual") == "yes")
        assumeTrue("Device has no enrolled strong biometric", BiometricCryptoGate.canAuthenticate(composeRule.activity))
        val dismissed = CompletableDeferred<Unit>()
        composeRule.runOnUiThread {
            BiometricCryptoGate.authenticate(
                activity = composeRule.activity,
                title = "Unlock OmniTerm",
                subtitle = "Confirm the OmniTerm biometric prompt",
                onAuthenticated = { dismissed.complete(Unit) },
                onUnavailable = { dismissed.complete(Unit) },
                onError = { dismissed.complete(Unit) },
            )
        }
        delay(12_000)
        if (!dismissed.isCompleted) shell("input keyevent KEYCODE_BACK")
        withTimeout(5_000) { dismissed.await() }
    }

    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }
}
