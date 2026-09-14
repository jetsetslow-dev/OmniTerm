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
     * Which `register` call installed the sink in [events], and how many have run.
     *
     * Same reasoning as `ExternalLaunchBridge`: this object now outlives the Activity it was
     * registered against, Flutter's teardown of the previous stream delivers `onCancel` *after* the
     * replacement has attached, and an unguarded clear would leave shade actions — Disconnect,
     * Disconnect all, Resume — queued forever after the first Activity recreation.
     */
    private var registrations = 0L
    private var sinkOwner = 0L


    /**
     * Actions that arrive while Dart is not listening.
     *
     * The service can be woken by a notification tap before the engine has attached — dropping
     * those would make the button silently do nothing, which is the single worst outcome for a
     * control the user pressed deliberately.
     */
    private val pending = mutableListOf<Map<String, Any?>>()

    fun register(engine: FlutterEngine, context: Context) {
        val registration = ++registrations
        val appContext = context.applicationContext

        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(true)
                    "sync" -> {
                        @Suppress("UNCHECKED_CAST")
                        val sessions = call.argument<List<Map<String, Any?>>>("sessions").orEmpty()
                        // Reported, not thrown. startForegroundService throws
                        // ForegroundServiceStartNotAllowedException on Android 12+ when the app is
                        // already in the background, and letting that escape the handler loses the
                        // reason on the way across the channel — which is the one thing the caller
                        // needs in order to tell the user their sessions are not protected.
                        reporting(result) {
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
                        }
                    }
                    "stop" -> reporting(result) { stop(appContext) }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    // A registration already replaced by a newer Activity must not install a sink.
                    if (registration != registrations) return
                    sinkOwner = registration
                    events = sink
                    // Anything that happened before Dart attached is delivered now, in order.
                    pending.forEach(sink::success)
                    pending.clear()
                }

                override fun onCancel(arguments: Any?) {
                    // Only whoever installed the current sink may clear it; see [sinkOwner].
                    if (sinkOwner != registration) return
                    events = null
                    sinkOwner = 0L
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

    /**
     * Runs [block] and answers the channel with what actually happened.
     *
     * Success is `true`; a refusal becomes an error carrying the platform's own message, so Dart
     * can tell "this device said no" apart from "this platform has no such service at all".
     */
    private inline fun reporting(result: MethodChannel.Result, block: () -> Unit) {
        try {
            block()
            result.success(true)
        } catch (e: Exception) {
            result.error(
                "session_service_failed",
                e.message ?: e::class.java.simpleName,
                null,
            )
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
        // Match Kotlin's TerminalSessionManager: cancel the service itself, including a pending
        // foreground start. Enqueuing STOP via startService can race a following SYNC and let an
        // older stopSelf() tear down the new foreground start before it is acknowledged.
        context.stopService(Intent(context, SessionService::class.java))
    }
}
