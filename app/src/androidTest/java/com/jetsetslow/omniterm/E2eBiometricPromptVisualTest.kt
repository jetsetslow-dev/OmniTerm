package com.jetsetslow.omniterm

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.InsetDrawable
import android.os.ParcelFileDescriptor
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
    fun monochromeAdaptiveIconContainsOriginalHighContrastGeometry() {
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
        val brightVisibleFraction = pixels.count {
            val alpha = it ushr 24
            val red = it ushr 16 and 0xff
            val green = it ushr 8 and 0xff
            val blue = it and 0xff
            alpha != 0 && red + green + blue > 3 * 192
        }.toDouble() / pixels.size
        assertTrue(
            "Original high-contrast monochrome mark is missing",
            brightVisibleFraction > 0.05,
        )
    }

    @Test
    fun manifestSystemLogoUsesOriginalBitmapOutsideAdaptiveIconWrapper() {
        val appInfo = composeRule.activity.applicationInfo
        val packageManager = composeRule.activity.packageManager
        val activityInfo = packageManager.getActivityInfo(
            composeRule.activity.componentName,
            0,
        )
        assertEquals(R.mipmap.ic_launcher_fg, appInfo.logo)
        assertEquals(R.mipmap.ic_launcher_fg, activityInfo.logo)

        val launcher = composeRule.activity.getDrawable(R.mipmap.ic_launcher)
        assertTrue("Launcher icon is not adaptive", launcher is AdaptiveIconDrawable)
        val foreground = (launcher as AdaptiveIconDrawable).foreground
        assertTrue("Original inset foreground was replaced", foreground is InsetDrawable)
        assertTrue(
            "Original bitmap logo artwork was replaced",
            (foreground as InsetDrawable).drawable is BitmapDrawable,
        )

        val systemLogo = requireNotNull(activityInfo.loadLogo(packageManager))
        assertTrue(
            "System logo must bypass Android 16 adaptive-icon flattening",
            systemLogo is BitmapDrawable,
        )
        val bitmap = Bitmap.createBitmap(216, 216, Bitmap.Config.ARGB_8888)
        systemLogo.setBounds(0, 0, bitmap.width, bitmap.height)
        systemLogo.draw(Canvas(bitmap))
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val visibleColors = pixels.asSequence()
            .filter { (it ushr 24) != 0 }
            .map { it and 0x00ffffff }
            .distinct()
            .take(64)
            .count()
        assertTrue(
            "System logo collapsed to a blank tile: $visibleColors visible colors",
            visibleColors >= 64,
        )
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
