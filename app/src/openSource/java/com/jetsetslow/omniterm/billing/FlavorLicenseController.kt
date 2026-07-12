package com.jetsetslow.omniterm.billing

import android.app.Activity
import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class FlavorLicenseController(context: Context) : LicenseController {
    override val state: StateFlow<LicenseState> = MutableStateFlow(
        LicenseState(enabled = false, loading = false, unlocked = true, adsRemoved = true)
    )

    override fun start() = Unit
    override fun refresh() = Unit
    override fun onResume() = Unit
    override fun launchPurchase(activity: Activity) = Unit
    override fun launchAdRemovalPurchase(activity: Activity) = Unit
    override fun close() = Unit
}
