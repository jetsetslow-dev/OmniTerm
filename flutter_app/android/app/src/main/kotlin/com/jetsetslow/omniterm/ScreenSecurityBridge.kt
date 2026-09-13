package com.jetsetslow.omniterm

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Applies `FLAG_SECURE` to the window, keeping the app's contents out of screenshots, screen
 * recordings and the OS task-switcher thumbnail.
 *
 * This has no Flutter-side equivalent: it is a window flag the platform enforces, and nothing Dart
 * draws can substitute for it. On a terminal app the task-switcher thumbnail is the real exposure —
 * it is captured automatically, persists after the app is backgrounded, and routinely contains a
 * live root shell.
 *
 * There is no iOS counterpart. iOS has no API to block screenshots, so the equivalent protection
 * there is covering the window on `willResignActive`; that is tracked separately rather than faked
 * here, because a channel that quietly did nothing on iOS would let the Settings screen claim a
 * protection the platform is not providing.
 */
object ScreenSecurityBridge {
    private const val CHANNEL = "omniterm/screen_security"

    /**
     * The last state Dart asked for, remembered for the life of the process.
     *
     * A window flag belongs to a window, and a recreated Activity gets a new one. The Dart side
     * caches its last applied setting and only sends a *change*, so once the engine is retained
     * across Activity instances nothing would re-send `setSecure` and the replacement window would
     * come up unprotected. On a terminal app that is the real exposure: the task-switcher thumbnail
     * is captured automatically and routinely contains a live root shell.
     */
    private var secure = false

    fun register(engine: FlutterEngine, activity: Activity) {
        // Reapplied before this Activity renders, not in response to a Dart call that will not come.
        apply(activity, secure)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    secure = call.argument<Boolean>("secure") ?: false
                    apply(activity, secure)
                    result.success(true)
                }
                // Reported honestly rather than assumed by the Dart side, so the Settings screen can
                // say the option does nothing on a platform that does not implement it.
                "isSupported" -> result.success(true)
                else -> result.notImplemented()
            }
        }
    }

    /** The flag must be set on the UI thread; `runOnUiThread` is a no-op when already there. */
    private fun apply(activity: Activity, secure: Boolean) {
        activity.runOnUiThread {
            if (secure) {
                activity.window.setFlags(
                    WindowManager.LayoutParams.FLAG_SECURE,
                    WindowManager.LayoutParams.FLAG_SECURE,
                )
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }
}
