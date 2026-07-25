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
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in visual fixture for capturing Android's app-branded biometric prompt on a real device. */
class E2eBiometricPromptVisualTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    /**
     * Android 15+ BiometricPrompt derives its branding thumbnail from the adaptive launcher icon and
     * composites background + foreground. It does NOT read `android:logo`; androidx.biometric only
     * forwards a logo when the app calls `PromptInfo.Builder.setLogoRes/setLogoBitmap`, which need
     * SET_BIOMETRIC_DIALOG_ADVANCED (internal|role) and are therefore unavailable to us.
     *
     * So the only lever we have is the foreground layer's own alpha: with the mark's baked tile
     * stripped, there is nothing left for the prompt to flatten into an opaque block.
     */
    @Test
    fun adaptiveForegroundIsTransparentSoTheBiometricPromptCannotFlattenIt() {
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
            "Foreground has a baked opaque tile again; the prompt will flatten it: $transparentFraction",
            transparentFraction > 0.20,
        )

        val markFraction = pixels.count { (it ushr 24) > 0x80 }.toDouble() / pixels.size
        assertTrue("Foreground mark is effectively empty: $markFraction", markFraction > 0.05)
    }

    /** The mark must still read as artwork (many distinct colours), not collapse to a flat shape. */
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

    private fun renderToPixels(drawable: android.graphics.drawable.Drawable): IntArray {
        val bitmap = Bitmap.createBitmap(216, 216, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, bitmap.width, bitmap.height)
        drawable.draw(Canvas(bitmap))
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return pixels
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
