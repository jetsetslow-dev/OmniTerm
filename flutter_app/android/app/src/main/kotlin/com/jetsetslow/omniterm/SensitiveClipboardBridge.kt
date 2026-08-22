package com.jetsetslow.omniterm

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Copies a secret to the clipboard with the platform's "this is sensitive" marker set.
 *
 * Flutter's `Clipboard.setData` cannot express this: it writes a plain clip, and from Android 13 the
 * system shows a preview of whatever was copied. For the one thing this app copies that is a secret
 * — a freshly generated private key — that preview puts the key on screen next to the button the
 * user pressed to keep it private. `ClipDescription.EXTRA_IS_SENSITIVE` replaces the preview with a
 * neutral placeholder.
 *
 * Ported from `copySensitiveClipboard` in `ui/ToolsScreen.kt:115`. The 60-second clear that helper
 * also performs lives in Dart, where it can be tested; only the part that needs a platform API is
 * here.
 */
object SensitiveClipboardBridge {
    private const val CHANNEL = "omniterm/sensitive_clipboard"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call,
            result ->
            when (call.method) {
                "copy" -> {
                    val label = call.argument<String>("label") ?: "OmniTerm"
                    val text = call.argument<String>("text") ?: ""
                    result.success(copy(context, label, text))
                }
                // Reads back only to decide whether the clipboard still holds what we put there.
                // The value never leaves the platform side except as this boolean.
                "holds" -> {
                    val text = call.argument<String>("text") ?: ""
                    result.success(holds(context, text))
                }
                "clear" -> result.success(clear(context))
                else -> result.notImplemented()
            }
        }
    }

    private fun manager(context: Context): ClipboardManager? =
        context.getSystemService(ClipboardManager::class.java)

    private fun copy(context: Context, label: String, text: String): Boolean {
        val manager = manager(context) ?: return false
        val clip = ClipData.newPlainText(label, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        manager.setPrimaryClip(clip)
        return true
    }

    private fun holds(context: Context, text: String): Boolean {
        val manager = manager(context) ?: return false
        return runCatching {
            manager.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString() == text
        }.getOrDefault(false)
    }

    private fun clear(context: Context): Boolean {
        val manager = manager(context) ?: return false
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                manager.clearPrimaryClip()
            } else {
                manager.setPrimaryClip(ClipData.newPlainText("", ""))
            }
            true
        }.getOrDefault(false)
    }
}
