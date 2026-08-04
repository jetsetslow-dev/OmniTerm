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

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    val secure = call.argument<Boolean>("secure") ?: false
                    // The flag must be set on the UI thread; `runOnUiThread` is a no-op when the
                    // call already arrives there, which it does for a normal method channel.
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
                    result.success(true)
                }
                // Reported honestly rather than assumed by the Dart side, so the Settings screen can
                // say the option does nothing on a platform that does not implement it.
                "isSupported" -> result.success(true)
                else -> result.notImplemented()
            }
        }
    }
}
