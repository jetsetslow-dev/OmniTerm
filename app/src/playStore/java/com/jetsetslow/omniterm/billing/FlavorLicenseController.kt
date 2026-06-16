package com.jetsetslow.omniterm.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

private const val PRODUCT_ID = "omniterm_premium_unlock"
private const val AD_REMOVAL_PRODUCT_ID = "omniterm_ad_removal"
private const val PREFS = "omniterm_license"

// Acknowledgement must land within Google's 3-day window or the purchase auto-refunds, so retry
// transient failures with exponential backoff rather than giving up after one attempt.
private const val ACK_MAX_ATTEMPTS = 6
private const val ACK_MAX_BACKOFF_MS = 30_000L

class FlavorLicenseController(private val context: Context) : LicenseController, PurchasesUpdatedListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var productDetails: ProductDetails? = null
    private var adRemovalDetails: ProductDetails? = null
    private var started = false
    // Purchase tokens with an acknowledgement retry loop in flight, so a concurrent re-query that
    // sees the same unacknowledged purchase doesn't spawn a duplicate loop. Confined to the Main
    // dispatcher (the scope), so a plain set is safe.
    private val acknowledging = mutableSetOf<String>()

    private val _state = MutableStateFlow(
        LicenseState(
            enabled = true,
            loading = true,
            unlocked = false,
            adsRemoved = false,
        )
    )
    override val state: StateFlow<LicenseState> = _state

    private val billingClient: BillingClient by lazy {
        BillingClient.newBuilder(context)
            .setListener(this)
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder()
                    .enableOneTimeProducts()
                    .build()
            )
            .build()
    }

    override fun start() {
        if (started) return
        started = true
        // Ads (and their SDK init) are gated behind UMP consent, which needs an Activity and is
        // therefore driven from FlavorAdBanner, not here. This keeps billing setup independent of
        // the ad/consent flow.
        updateState(loading = true)
        connect()
    }

    override fun refresh() {
        updateState(loading = true, message = null)
        connect()
    }

    override fun onResume() {
        if (!started) {
            // First foreground before start() ran: fall through to the normal startup path.
            start()
            return
        }
        // Quiet re-query: no loading flag, so the upsell buttons don't flash "Checking…" on every
        // resume. When the client is ready we just re-pull owned purchases; otherwise reconnect
        // (connect() queries purchases on a successful connection).
        if (billingClient.isReady) {
            queryPurchases()
        } else {
            connect()
        }
    }

    override fun close() {
        scope.cancel()
        if (billingClient.isReady) {
            billingClient.endConnection()
        }
    }

    override fun launchPurchase(activity: Activity) {
        val pd = productDetails
        if (pd == null) {
            updateState(message = "Unlock purchase not available yet.")
            return
        }
        val productDetailsParamsList = listOf(
            BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(pd)
                .build()
        )
        val billingFlowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(productDetailsParamsList)
            .build()
        val result = billingClient.launchBillingFlow(activity, billingFlowParams)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            updateState(message = result.debugMessage.ifBlank { "Could not launch purchase." })
        }
    }

    override fun launchAdRemovalPurchase(activity: Activity) {
        val pd = adRemovalDetails
        if (pd == null) {
            updateState(message = "Ad removal purchase not available yet.")
            return
        }
        val productDetailsParamsList = listOf(
            BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(pd)
                .build()
        )
        val billingFlowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(productDetailsParamsList)
            .build()
        val result = billingClient.launchBillingFlow(activity, billingFlowParams)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            updateState(message = result.debugMessage.ifBlank { "Could not launch ad removal purchase." })
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            // Incremental callback: it only carries the purchase(s) just made, so merge into the
            // existing entitlement rather than recomputing absolutely (which would drop a previously
            // owned product). The authoritative full set comes from queryPurchases().
            handlePurchases(purchases, merge = true)
        } else if (result.responseCode != BillingClient.BillingResponseCode.USER_CANCELED) {
            updateState(message = result.debugMessage.ifBlank { "Purchase did not complete." })
        }
    }

    private fun connect() {
        if (billingClient.isReady) {
            queryProductDetails()
            queryPurchases()
            return
        }
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    queryProductDetails()
                    queryPurchases()
                } else {
                    updateState(loading = false, message = result.debugMessage.ifBlank { "Google Play Billing is unavailable." })
                }
            }

            override fun onBillingServiceDisconnected() {
                updateState(loading = false, message = "Google Play Billing disconnected. Use Restore Purchase to retry.")
            }
        })
    }

    private fun queryProductDetails() {
        val products = listOf(
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(PRODUCT_ID)
                .setProductType(BillingClient.ProductType.INAPP)
                .build(),
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(AD_REMOVAL_PRODUCT_ID)
                .setProductType(BillingClient.ProductType.INAPP)
                .build()
        )
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(products)
            .build()
        billingClient.queryProductDetailsAsync(params) { result, detailsResult ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                productDetails = detailsResult.productDetailsList.find { it.productId == PRODUCT_ID }
                adRemovalDetails = detailsResult.productDetailsList.find { it.productId == AD_REMOVAL_PRODUCT_ID }
                // An OK response with the products missing means Play has no active in-app product
                // for these IDs visible to this account — the usual cause of "unavailable at this
                // time" on the purchase buttons. Surface it so the dead button has a reason instead
                // of failing silently (products must be Active in Play Console and the account must
                // be a licensed tester on the track).
                if (productDetails == null && adRemovalDetails == null) {
                    updateState(
                        loading = false,
                        message = "Purchases unavailable: no active in-app products found in Google Play " +
                            "for this build. Check that the products are active and you're a licensed tester.",
                    )
                    return@queryProductDetailsAsync
                }
            } else {
                updateState(
                    loading = false,
                    message = result.debugMessage.ifBlank { "Could not load purchase options from Google Play." },
                )
                return@queryProductDetailsAsync
            }
            updateState(loading = false)
        }
    }

    private fun queryPurchases() {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
        billingClient.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                // Authoritative full set of owned purchases — replace state outright.
                handlePurchases(purchases, merge = false)
            } else {
                updateState(loading = false, message = result.debugMessage.ifBlank { "Could not restore purchases." })
            }
        }
    }

    /**
     * Apply entitlement from [purchases]. When [merge] is true the result is OR-ed with the current
     * state (incremental post-purchase callback that only carries the new product); when false it
     * replaces state (the full, authoritative list from queryPurchases).
     */
    private fun handlePurchases(purchases: List<Purchase>, merge: Boolean) {
        var unlocked = if (merge) _state.value.unlocked else false
        var adsRemoved = if (merge) _state.value.adsRemoved else false
        purchases.forEach { purchase ->
            val ownsUnlock = purchase.products.contains(PRODUCT_ID) && purchase.purchaseState == Purchase.PurchaseState.PURCHASED
            val ownsAdRemoval = purchase.products.contains(AD_REMOVAL_PRODUCT_ID) && purchase.purchaseState == Purchase.PurchaseState.PURCHASED
            if ((ownsUnlock || ownsAdRemoval) && !purchase.isAcknowledged) acknowledge(purchase)
            if (ownsUnlock) unlocked = true
            if (ownsAdRemoval) adsRemoved = true
        }
        updateState(loading = false, unlocked = unlocked, adsRemoved = adsRemoved, message = null)
    }

    /**
     * Acknowledge a PURCHASED, not-yet-acknowledged purchase, retrying with exponential backoff.
     * Acknowledgement is mandatory within 3 days of purchase or Google auto-refunds and revokes the
     * entitlement, so a transient failure (network blip, service disconnect) must not be left as a
     * one-shot. Google's guidance is to retry acknowledgements performed after a purchase/restore.
     * Guarded by [acknowledging] so a re-query that surfaces the same purchase doesn't start a
     * second concurrent retry loop for the same token.
     */
    private fun acknowledge(purchase: Purchase) {
        if (!acknowledging.add(purchase.purchaseToken)) return
        scope.launch {
            val params = AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(purchase.purchaseToken)
                .build()
            var delayMs = 1_000L
            repeat(ACK_MAX_ATTEMPTS) { attempt ->
                val result = CompletableDeferred<BillingResult>()
                billingClient.acknowledgePurchase(params) { result.complete(it) }
                val code = result.await().responseCode
                if (code == BillingClient.BillingResponseCode.OK) {
                    acknowledging.remove(purchase.purchaseToken)
                    return@launch
                }
                if (attempt < ACK_MAX_ATTEMPTS - 1) {
                    delay(delayMs)
                    delayMs = (delayMs * 2).coerceAtMost(ACK_MAX_BACKOFF_MS)
                }
            }
            // Exhausted retries — release the guard so a later resume re-query can try again, and
            // surface it so the (already-entitled) user knows acknowledgement is pending.
            acknowledging.remove(purchase.purchaseToken)
            updateState(message = "Couldn't confirm your purchase with Google Play yet. It will retry automatically.")
        }
    }

    private fun updateState(
        loading: Boolean = _state.value.loading,
        unlocked: Boolean = _state.value.unlocked,
        adsRemoved: Boolean = _state.value.adsRemoved,
        message: String? = _state.value.message,
    ) {
        // Use only the localized price Google Play returns (correct currency/format for the user's
        // country). Leave null when details aren't loaded yet — the UI shows a price-free label
        // rather than guessing a US-dollar amount.
        _state.value = _state.value.copy(
            enabled = true,
            loading = loading,
            unlocked = unlocked,
            adsRemoved = adsRemoved || unlocked, // If fully unlocked, ads are automatically removed
            productPrice = productDetails?.oneTimePurchaseOfferDetails?.formattedPrice,
            adRemovalPrice = adRemovalDetails?.oneTimePurchaseOfferDetails?.formattedPrice,
            message = message,
        )
    }
}
