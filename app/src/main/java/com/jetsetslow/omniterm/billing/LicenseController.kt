package com.jetsetslow.omniterm.billing

import android.app.Activity
import android.content.Context
import kotlinx.coroutines.flow.StateFlow

data class LicenseState(
    val enabled: Boolean = false,
    val loading: Boolean = false,
    val unlocked: Boolean = true,
    val adsRemoved: Boolean = true,
    // Localized, Play-provided price strings (formattedPrice) — correct currency and formatting for
    // the user's Play country. Null until Google Play Billing returns product details; the UI must
    // NOT substitute a hardcoded amount (Play best practice + policy: never show a price the billing
    // library didn't give you).
    val productPrice: String? = null,
    val adRemovalPrice: String? = null,
    val message: String? = null,
)

interface LicenseController {
    val state: StateFlow<LicenseState>
    fun start()
    fun refresh()
    /**
     * Quietly re-query owned purchases (no loading spinner / "Checking…" UI). Called when the app
     * returns to the foreground so entitlement reflects purchases finalized while backgrounded,
     * out-of-app purchases, refunds, and Play-side revocations — per Google's guidance to query
     * purchases on every resume, not only at launch. [refresh] remains the explicit user-driven
     * "Restore" path that does show progress.
     */
    fun onResume()
    fun launchPurchase(activity: Activity)
    fun launchAdRemovalPurchase(activity: Activity)
    fun close()
}

fun createLicenseController(context: Context): LicenseController =
    FlavorLicenseController(context.applicationContext)
