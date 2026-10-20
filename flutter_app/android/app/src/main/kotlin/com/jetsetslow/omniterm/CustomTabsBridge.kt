package com.jetsetslow.omniterm

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Opens a link in a Custom Tab tinted to the app's own theme, ported from `ui/LinkOpener.kt`.
 *
 * `url_launcher` cannot express two things the Kotlin app does. Its `InAppBrowserConfiguration` has
 * exactly one field — `showTitle` — so there is no way to set the toolbar colour, and a link opened
 * from OmniTerm arrives in a browser chrome that belongs to nobody. And where no Custom Tabs
 * provider exists it falls back to its own bundled WebView, while Kotlin falls back to the user's
 * real browser via `ACTION_VIEW`; those are different products, and the second is the one a terminal
 * user asked for when they tapped a URL in their own shell output.
 *
 * Returning false rather than throwing keeps the caller's contract: the screen shows "No app could
 * open that link" instead of an error dialog about an intent.
 */
object CustomTabsBridge {
    private const val CHANNEL = "omniterm/custom_tabs"

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call,
            result ->
            when (call.method) {
                "open" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val inApp = call.argument<Boolean>("inApp") ?: true
                    // Arrives as a Long because Dart has no unsigned 32-bit type and 0xFF……
                    // exceeds a signed Int; the narrowing is what makes it an ARGB colour again.
                    val toolbarColor = call.argument<Number>("toolbarColor")?.toInt()
                    result.success(open(activity, url, inApp, toolbarColor))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(activity: Activity, url: String, inApp: Boolean, toolbarColor: Int?): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        if (inApp) {
            try {
                val builder = CustomTabsIntent.Builder().setShowTitle(true)
                if (toolbarColor != null) {
                    builder.setDefaultColorSchemeParams(
                        CustomTabColorSchemeParams.Builder().setToolbarColor(toolbarColor).build()
                    )
                }
                builder.build().launchUrl(activity, uri)
                return true
            } catch (_: ActivityNotFoundException) {
                // No Custom-Tabs-capable browser — fall through to a plain external open, exactly
                // as `ui/LinkOpener.kt:31` does.
            }
        }
        return try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, uri))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
