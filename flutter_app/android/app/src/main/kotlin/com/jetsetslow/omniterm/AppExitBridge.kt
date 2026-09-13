package com.jetsetslow.omniterm

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Ends the app when the user explicitly asks to, now that finishing the Activity no longer does.
 *
 * "Terminate & Exit" tells the user that exiting terminates active background SSH sessions, and
 * that used to be true for an accidental reason: `SystemNavigator.pop()` finished the Activity, and
 * a default [io.flutter.embedding.android.FlutterActivity] destroyed its engine with it, taking the
 * Dart isolate and its sessions along. [RetainedFlutterEngine] deliberately breaks that coupling so
 * sessions survive a *recreation*, which means the exit path has to say what it means instead of
 * relying on a side effect.
 *
 * Order matters. The services are stopped first, because they are what would otherwise be left
 * showing an ongoing notification for a process the user just ended; the engine is destroyed last,
 * after the reply has been sent, because destroying it tears down the channel this call arrived on.
 */
object AppExitBridge {
    private const val CHANNEL = "omniterm/app_exit"
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "terminate" -> {
                    // Answered before anything is torn down: the destroy below closes this channel.
                    result.success(true)
                    main.post { terminate(activity) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun terminate(activity: Activity) {
        stopServices(activity.applicationContext)
        activity.finishAndRemoveTask()
        RetainedFlutterEngine.destroy()
    }

    /**
     * Stops the foreground services directly rather than through their Dart-facing bridges, which
     * are gone by the time this runs on a torn-down engine.
     */
    private fun stopServices(context: Context) {
        runCatching { context.stopService(Intent(context, SessionService::class.java)) }
        runCatching { context.stopService(Intent(context, LongOperationService::class.java)) }
    }
}
