package com.jetsetslow.omniterm.billing

import android.app.Activity
import android.content.Context
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.RequestConfiguration
import com.google.android.ump.ConsentInformation
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Wraps Google's User Messaging Platform (UMP) so ads are only requested once the user's consent
 * state has been resolved. This satisfies Google's EU User Consent Policy: for EEA/UK users a
 * consent form is shown before any ad loads; elsewhere consent is "not required" and ads load
 * straight away. The Mobile Ads SDK is initialized only after [canRequestAds] becomes true.
 *
 * Process-wide singleton: consent is gathered once per launch, not per banner.
 */
object AdsConsentManager {
    @Volatile
    var canRequestAds: Boolean = false
        private set

    private val mobileAdsInitialized = AtomicBoolean(false)

    /**
     * Gather consent (showing the form if required) and, once resolved, initialize the Mobile Ads
     * SDK. Safe to call repeatedly; UMP caches state. [activity] is needed to present the form.
     */
    fun ensureConsentAndInit(activity: Activity, onUpdated: () -> Unit = {}) {
        val consentInfo = UserMessagingPlatform.getConsentInformation(activity)
        val params = ConsentRequestParameters.Builder().build()
        consentInfo.requestConsentInfoUpdate(
            activity,
            params,
            {
                UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) {
                    // Form flow done (or not needed). Reflect whatever consent allows.
                    refreshAndInit(activity, consentInfo, onUpdated)
                }
            },
            {
                // Consent info update failed (offline, etc.). Fall back to whatever is cached so a
                // returning user who already consented isn't blocked from ads.
                refreshAndInit(activity, consentInfo, onUpdated)
            },
        )
    }

    private fun refreshAndInit(context: Context, consentInfo: ConsentInformation, onUpdated: () -> Unit) {
        canRequestAds = consentInfo.canRequestAds()
        if (canRequestAds) initMobileAds(context)
        onUpdated()
    }

    private fun initMobileAds(context: Context) {
        if (!mobileAdsInitialized.compareAndSet(false, true)) return
        // Keep ad content family-friendly so the banner can't surface inappropriate creatives.
        val configBuilder = RequestConfiguration.Builder()
            .setMaxAdContentRating(RequestConfiguration.MAX_AD_CONTENT_RATING_G)
        // Optional test devices (injected at build time, empty in production). On the internal-test
        // track a brand-new real ad unit often returns "no fill"; registering the tester's device
        // makes Google serve test ads so the placement can be verified. The hashed device ID is
        // printed in logcat on the first ad request ("Use RequestConfiguration...addTestDeviceIds").
        val testDeviceIds = com.jetsetslow.omniterm.BuildConfig.ADMOB_TEST_DEVICE_IDS
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        if (testDeviceIds.isNotEmpty()) {
            configBuilder.setTestDeviceIds(testDeviceIds)
        }
        MobileAds.setRequestConfiguration(configBuilder.build())
        runCatching { MobileAds.initialize(context) {} }
    }
}
