package com.jetsetslow.omniterm

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong

/**
 * Carries launcher shortcuts and notification resume intents across the Flutter boundary.
 *
 * Intent values are consumed here, before they can be replayed by an Activity recreation. Dart
 * still owns the security decision: it queues every message behind the app-lock gate before doing
 * anything with the target host or share.
 */
object ExternalLaunchBridge {
    private const val METHOD_CHANNEL = "omniterm/external_launch"
    private const val EVENT_CHANNEL = "omniterm/external_launch/events"
    private val sequence = AtomicLong()
    private var events: EventChannel.EventSink? = null
    private val pending = mutableListOf<Map<String, Any?>>()

    /**
     * Event subscriptions belong to the engine, not the Activity that most recently attached.
     *
     * Flutter does not cancel an existing stream when setStreamHandler replaces its handler.
     * The replacement starts with no active sink, so Dart's next cancel fails and never clears
     * [events]. Keep the handler for the retained engine's lifetime. A new engine gets a fresh
     * registration; ownership checks prevent a late callback from its predecessor taking over.
     */
    private var eventEngine = WeakReference<FlutterEngine>(null)
    private var registrations = 0L
    private var sinkOwner = 0L


    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeInitialActions" -> result.success(consume(activity.intent))
                    else -> result.notImplemented()
                }
            }
        if (eventEngine.get() === engine) return
        eventEngine = WeakReference(engine)
        val registration = ++registrations
        events = null
        sinkOwner = 0L
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    // A registration from a superseded engine must not install a sink.
                    if (registration != registrations) return
                    sinkOwner = registration
                    events = sink
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

    fun onNewIntent(intent: Intent) {
        for (action in consume(intent)) {
            val sink = events
            if (sink == null) pending.add(action) else sink.success(action)
        }
    }

    private fun consume(intent: Intent?): List<Map<String, Any?>> {
        intent ?: return emptyList()
        val notificationPath = intent.data
            ?.takeIf { it.scheme == "omniterm" && it.host == "notification" }
            ?.pathSegments
        // SessionService uses a URI to give each PendingIntent a distinct identity. It does not
        // put the resume target in an extra; reading only extras made those real taps do nothing.
        val sessionId = intent.getStringExtra(SessionService.EXTRA_SESSION_ID)
            ?: notificationPath
                ?.takeIf { it.size == 2 && it[0] == "session" }
                ?.get(1)
                ?.takeIf { it.isNotBlank() }
        val result = buildList {
            sessionId?.let {
                add(message("resume_session", target = it))
            }
            when (intent.action) {
                "com.jetsetslow.omniterm.action.NEW_HOST" -> add(message("add_server"))
                "com.jetsetslow.omniterm.action.SFTP" -> add(message("open_sftp"))
                "com.jetsetslow.omniterm.action.NETWORK_TOOLS" -> add(message("open_network"))
            }
            if (notificationPath?.size == 1) {
                when (notificationPath[0]) {
                    "transfers" -> add(message("open_transfers"))
                    "network" -> add(message("open_network"))
                    "fleet" -> add(message("open_fleet"))
                    "infra" -> add(message("open_infra"))
                    "backup" -> add(message("open_backup"))
                }
            }
            intent.intExtra("shortcut_server_id")?.let {
                add(message("connect_server", targetId = it))
            }
            val first = intent.intExtra("shortcut_split_server1_id")
            val second = intent.intExtra("shortcut_split_server2_id")
            if (first != null && second != null) {
                add(message("open_split", targetId = first, secondId = second))
            }
            intent.intExtra("shortcut_share_id")?.let {
                add(message("open_share", targetId = it))
            }
        }

        intent.removeExtra(SessionService.EXTRA_SESSION_ID)
        intent.removeExtra("shortcut_server_id")
        intent.removeExtra("shortcut_split_server1_id")
        intent.removeExtra("shortcut_split_server2_id")
        intent.removeExtra("shortcut_share_id")
        if (intent.data?.scheme == "omniterm" && intent.data?.host == "notification") {
            intent.data = null
        }
        if (intent.action?.startsWith("com.jetsetslow.omniterm.action.") == true) {
            intent.action = Intent.ACTION_MAIN
        }
        return result
    }

    private fun Intent.intExtra(name: String): Int? =
        getIntExtra(name, 0).takeIf { hasExtra(name) && it > 0 }

    private fun message(
        type: String,
        targetId: Int? = null,
        secondId: Int? = null,
        target: String? = null,
    ): Map<String, Any?> = mapOf(
        "id" to "${System.currentTimeMillis()}-${sequence.incrementAndGet()}",
        "type" to type,
        "targetId" to targetId,
        "secondId" to secondId,
        "target" to target,
    )
}
