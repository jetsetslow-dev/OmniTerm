package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Open-source flavor: no ad SDK is bundled, so the banner renders nothing. The caller in `main`
 * already only invokes this when the (always-false here) ad-removal entitlement is unmet, so this
 * is doubly inert in practice.
 */
@Composable
fun FlavorAdBanner(modifier: Modifier = Modifier) {
    // Intentionally empty — the source-available build ships no advertising.
}

/**
 * Open-source flavor: there is no ads SDK and no access to the device advertising ID, by design.
 * Returning a fixed string keeps the diagnostics layout identical across flavors without ever
 * touching an advertising identifier in this build.
 */
suspend fun flavorAdvertisingId(context: android.content.Context): String =
    "N/A (source-available build, no ads SDK)"
