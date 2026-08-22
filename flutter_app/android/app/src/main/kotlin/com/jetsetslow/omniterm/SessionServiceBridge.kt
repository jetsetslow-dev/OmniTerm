package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Dart's control over [SessionService], and the shade's way back to Dart.
 *
 * Dart owns the sessions; the service owns nothing but the notification and the wake lock. A tap on
 * "Disconnect" therefore travels *up* to Dart rather than being acted on here — the service has no
 * way to close an SSH channel that lives in the Dart isolate, and pretending otherwise would leave
 * a disconnected-looking row over a session that was still running.
 */
object SessionServiceBridge {
    private const val METHOD_CHANNEL = "omniterm/session_service"
    private const val EVENT_CHANNEL = "omniterm/session_service/actions"

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    /**
     * Actions that arrive while Dart is not listening.
     *
     * The service can be woken by a notification tap before the engine has attached — dropping
     * those would make the button silently do nothing, which is the single worst outcome for a
     * control the user pressed deliberately.
     */
    private val pending = mutableListOf<Map<String, Any?>>()

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext

        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(true)
                    "sync" -> {
                        @Suppress("UNCHECKED_CAST")
                        val sessions = call.argument<List<Map<String, Any?>>>("sessions").orEmpty()
                        if (sessions.isEmpty()) {
                            stop(appContext)
                        } else {
                            val intent = Intent(appContext, SessionService::class.java).apply {
                                action = SessionService.ACTION_SYNC
                                putStringArrayListExtra(
                                    SessionService.EXTRA_SESSION_IDS,
                                    ArrayList(sessions.map { it["id"] as? String ?: "" }),
                                )
                                putStringArrayListExtra(
                                    SessionService.EXTRA_SESSION_NAMES,
                                    ArrayList(sessions.map { it["serverName"] as? String ?: "" }),
                                )
                            }
                            startService(appContext, intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stop(appContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    events = sink
                    // Anything that happened before Dart attached is delivered now, in order.
                    pending.forEach(sink::success)
                    pending.clear()
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            },
        )
    }

    /** Report a shade action to Dart, queueing it when nothing is listening yet. */
    fun emit(action: String, sessionId: String?) {
        val message = mapOf("action" to action, "session" to sessionId)
        main.post {
            val sink = events
            if (sink == null) pending.add(message) else sink.success(message)
        }
    }

    private fun startService(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun stop(context: Context) {
        context.startService(
            Intent(context, SessionService::class.java).apply {
                action = SessionService.ACTION_STOP
            },
        )
    }
}
