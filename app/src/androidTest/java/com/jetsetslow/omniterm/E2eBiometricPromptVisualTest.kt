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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in visual fixture for capturing Android's app-branded biometric prompt on a real device. */
class E2eBiometricPromptVisualTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    /** The home-screen icon must remain the existing adaptive infinity artwork. */
    @Test
    fun launcherIconRemainsTheExistingAdaptiveArtwork() {
        val drawable = composeRule.activity.getDrawable(R.mipmap.ic_launcher)
        assertTrue("Launcher icon is not adaptive", drawable is AdaptiveIconDrawable)
        val foreground = (drawable as AdaptiveIconDrawable).foreground
        assertTrue("Foreground is no longer the safe-zone inset", foreground is InsetDrawable)
        assertTrue(
            "Foreground no longer wraps the bitmap mark",
            (foreground as InsetDrawable).drawable is BitmapDrawable,
        )

        val pixels = renderToPixels(foreground)
        val transparentFraction = pixels.count { (it ushr 24) == 0 }.toDouble() / pixels.size
        assertTrue(
            "Adaptive foreground has a baked opaque tile again: $transparentFraction",
            transparentFraction > 0.20,
        )

        val markFraction = pixels.count { (it ushr 24) > 0x80 }.toDouble() / pixels.size
        assertTrue("Foreground mark is effectively empty: $markFraction", markFraction > 0.05)
    }

    /**
     * Android 15+ SystemUI resolves BiometricPrompt branding through
     * PackageManager.getApplicationIcon(ApplicationInfo). It does not read android:logo. Keep this
     * regression on that exact platform path and require a plain bitmap, while MainActivity keeps
     * the adaptive launcher icon above.
     */
    @Test
    fun biometricSystemPathResolvesTheOriginalBitmapArtwork() {
        val activity = composeRule.activity
        val packageManager = activity.packageManager
        val appInfo = activity.applicationInfo
        val activityInfo = packageManager.getActivityInfo(activity.componentName, 0)

        assertEquals(R.mipmap.ic_system_brand, appInfo.icon)
        assertEquals(R.mipmap.ic_launcher, activityInfo.icon)

        val systemIcon = packageManager.getApplicationIcon(appInfo)
        assertTrue(
            "Biometric system icon must bypass the adaptive wrapper",
            systemIcon is BitmapDrawable,
        )

        // Android 16's biometric prompt renders the app logo in a 32dp ImageView with fitXY.
        val promptPixels = renderToPixels(systemIcon, (32 * activity.resources.displayMetrics.density).toInt())
        val visibleFraction = promptPixels.count { (it ushr 24) > 0x80 }.toDouble() / promptPixels.size
        assertTrue("Biometric system icon is effectively transparent: $visibleFraction", visibleFraction > 0.55)

        val visibleColors = promptPixels.asSequence()
            .filter { (it ushr 24) > 0x80 }
            .map { it and 0x00ffffff }
            .distinct()
            .take(64)
            .count()
        assertTrue(
            "Biometric system icon collapsed to a blank/flat tile: $visibleColors visible colors",
            visibleColors >= 64,
        )
    }

    /** The adaptive foreground must still read as rich artwork, not collapse to a flat shape. */
    @Test
    fun adaptiveForegroundKeepsTheNeonMarkLegible() {
        val drawable = composeRule.activity.getDrawable(R.mipmap.ic_launcher) as AdaptiveIconDrawable
        val pixels = renderToPixels(drawable.foreground)
        val visibleColors = pixels.asSequence()
            .filter { (it ushr 24) > 0x40 }
            .map { it and 0x00ffffff }
            .distinct()
            .take(64)
            .count()
        assertTrue(
            "Foreground collapsed to a blank tile: $visibleColors visible colors",
            visibleColors >= 64,
        )
    }

    private fun renderToPixels(
        drawable: android.graphics.drawable.Drawable,
        size: Int = 216,
    ): IntArray {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, bitmap.width, bitmap.height)
        drawable.draw(Canvas(bitmap))
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return pixels
    }

    @Test
    fun showsBrandedSystemPromptLongEnoughForVisualInspection() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_biometric_visual") == "yes")
        assertTrue(
            "Opt-in visual fixture requires an enrolled strong biometric",
            BiometricCryptoGate.canAuthenticate(composeRule.activity),
        )
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
