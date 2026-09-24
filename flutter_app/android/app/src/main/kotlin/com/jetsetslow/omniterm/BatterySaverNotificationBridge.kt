package com.jetsetslow.omniterm

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Mirrors the Dart battery-saver prompt into Android's notification shade. */
object BatterySaverNotificationBridge {
    private const val CHANNEL = "omniterm/battery_saver"
    private const val NOTIFICATION_CHANNEL = "battery_saver"
    private const val NOTIFICATION_ID = 0x4253

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "showPrompt", "showActive" -> {
                    val percent = (call.argument<Number>("percent")?.toInt() ?: -1).coerceIn(0, 100)
                    show(app, percent, active = call.method == "showActive")
                    result.success(true)
                }
                "cancel" -> {
                    app.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun show(context: Context, percent: Int, active: Boolean) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "Battery saver",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val openApp = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentTitle(if (active) "OmniTerm battery saver on" else "Start OmniTerm battery saver?")
            .setContentText(
                if (active) {
                    "Battery at $percent% — auto-refresh paused and persistent terminals parked."
                } else {
                    "Battery at $percent%. Open OmniTerm to start saving; nothing has been interrupted."
                },
            )
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(openApp)
            .setOnlyAlertOnce(active)
            .setOngoing(active)
            .setAutoCancel(!active)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }
}
