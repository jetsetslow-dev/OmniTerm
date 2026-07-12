package com.jetsetslow.omniterm.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent

/**
 * Single doorway for opening a URL from anywhere in the app, honouring the user's link-open
 * preference. [inApp] opens a Chrome Custom Tab: the page (rendered by the user's default browser
 * engine, with their cookies/passwords intact) slides over our task with a toolbar tinted
 * [toolbarColor], and back returns straight to the terminal — no app switch. Browsers without
 * Custom Tabs support treat the intent as a plain VIEW and open normally, and a device with no
 * browser at all falls through to the external attempt. Returns false only when nothing on the
 * device could open the URL.
 */
fun openLink(context: Context, url: String, inApp: Boolean, toolbarColor: Int): Boolean {
    val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
    if (inApp) {
        try {
            CustomTabsIntent.Builder()
                .setShowTitle(true)
                .setDefaultColorSchemeParams(
                    CustomTabColorSchemeParams.Builder().setToolbarColor(toolbarColor).build()
                )
                .build()
                .launchUrl(context, uri)
            return true
        } catch (_: ActivityNotFoundException) {
            // No Custom-Tabs-capable browser — fall through to a plain external open.
        }
    }
    return try {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
