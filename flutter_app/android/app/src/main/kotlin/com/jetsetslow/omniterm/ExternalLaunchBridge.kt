package com.jetsetslow.omniterm

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
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

    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeInitialActions" -> result.success(consume(activity.intent))
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    events = sink
                    pending.forEach(sink::success)
                    pending.clear()
                }

                override fun onCancel(arguments: Any?) {
                    events = null
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
        val result = buildList {
            intent.getStringExtra(SessionService.EXTRA_SESSION_ID)?.let {
                add(message("resume_session", target = it))
            }
            when (intent.action) {
                "com.jetsetslow.omniterm.action.NEW_HOST" -> add(message("add_server"))
                "com.jetsetslow.omniterm.action.SFTP" -> add(message("open_sftp"))
                "com.jetsetslow.omniterm.action.NETWORK_TOOLS" -> add(message("open_network"))
            }
            if (intent.data?.scheme == "omniterm" && intent.data?.host == "notification") {
                when (intent.data?.lastPathSegment) {
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
