package com.jetsetslow.omniterm.ui

import android.app.Activity
import android.util.DisplayMetrics
import android.util.Log
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.LoadAdError
import com.jetsetslow.omniterm.billing.AdsConsentManager

private const val ADS_TAG = "OmniTermAds"

/**
 * Play Store flavor: resolve the device advertising ID for support diagnostics. This is a blocking
 * Play Services IPC call, so it runs off the main thread. If the user has limited ad tracking the
 * SDK reports it, and any failure (no Play Services, error) degrades to a readable placeholder
 * rather than throwing.
 */
suspend fun flavorAdvertisingId(context: android.content.Context): String =
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        try {
            val info = com.google.android.gms.ads.identifier.AdvertisingIdClient.getAdvertisingIdInfo(context)
            if (info.isLimitAdTrackingEnabled) "limited by user" else (info.id ?: "unavailable")
        } catch (e: Exception) {
            "unavailable (${e.javaClass.simpleName})"
        }
    }

// AdMob banner unit, injected at build time (ADMOB_BANNER_UNIT_ID env var / gradle property).
// Local builds fall back to Google's official sample/TEST unit; playStore release builds fail at
// configuration if the sample IDs are still in place (see app/build.gradle.kts).
private val BANNER_AD_UNIT_ID = com.jetsetslow.omniterm.BuildConfig.ADMOB_BANNER_UNIT_ID

/**
 * Play Store flavor: a single anchored adaptive banner. It's deliberately the smallest standard
 * placement (one bottom banner, no interstitials/rewarded/overlays) so it stays non-intrusive. The
 * caller in `main` only mounts this when the user has NOT bought ad removal or the full unlock, so
 * a paying user never sees it.
 *
 * Ads are gated behind UMP consent (Google's EU User Consent Policy): the SDK is initialized and the
 * banner is requested only after consent has been resolved and permits ad requests. Until then this
 * renders nothing (no blank reserved space, no un-consented ad call).
 */
@Composable
fun FlavorAdBanner(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val activity = context as? Activity ?: return

    // Resolve consent once, then flip canShow so the banner composes. UMP caches across launches.
    var canShow by remember { mutableStateOf(AdsConsentManager.canRequestAds) }
    LaunchedEffect(Unit) {
        if (AdsConsentManager.canRequestAds) {
            canShow = true
        } else {
            AdsConsentManager.ensureConsentAndInit(activity) {
                canShow = AdsConsentManager.canRequestAds
            }
        }
    }

    if (!canShow) return

    // Compute the adaptive banner size once for the current screen width.
    val adSize = remember {
        val metrics: DisplayMetrics = activity.resources.displayMetrics
        val widthPx = metrics.widthPixels.toFloat()
        val widthDp = (widthPx / metrics.density).toInt().coerceAtLeast(320)
        AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(activity, widthDp)
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            // Wrap in a FrameLayout so Compose has a stable host even before the ad loads.
            FrameLayout(ctx).apply {
                layoutParams = FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                )
                val adView = AdView(ctx).apply {
                    setAdSize(adSize)
                    adUnitId = BANNER_AD_UNIT_ID
                    // Log load results so "no ad shown" is diagnosable in logcat (filter: OmniTermAds)
                    // — a failed load (e.g. no fill, wrong unit) is otherwise indistinguishable from a
                    // banner that simply hasn't been mounted.
                    adListener = object : AdListener() {
                        override fun onAdFailedToLoad(error: LoadAdError) {
                            Log.w(ADS_TAG, "Banner failed to load: code=${error.code} message=${error.message} domain=${error.domain}")
                        }

                        override fun onAdLoaded() {
                            Log.i(ADS_TAG, "Banner loaded ($BANNER_AD_UNIT_ID)")
                        }
                    }
                    loadAd(AdRequest.Builder().build())
                }
                addView(adView)
            }
        },
    )
}
