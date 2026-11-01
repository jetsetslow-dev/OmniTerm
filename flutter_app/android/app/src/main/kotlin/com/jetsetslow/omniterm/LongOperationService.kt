package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.util.Locale

private data class OperationState(
    val id: String,
    val label: String,
    val bytesDone: Long,
    val totalBytes: Long,
    val destination: String,
)

/** Android's visible execution contract for Flutter work that continues after app switching. */
class LongOperationService : Service() {
    private val active = linkedMapOf<String, OperationState>()
    private var foreground = false
    private var sessionStartedAtMs = 0L
    private var completed = 0
    private var failed = 0
    private var cancelled = 0

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_OR_UPDATE -> applyUpdate(intent)
            ACTION_FINISH -> applyFinish(intent)
            ACTION_STOP -> stopNow()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun applyUpdate(intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        if (id.isBlank()) return
        if (active.isEmpty()) {
            sessionStartedAtMs = System.currentTimeMillis()
            completed = 0
            failed = 0
            cancelled = 0
        }
        val previous = active[id]
        active[id] = OperationState(
            id = id,
            label = intent.getStringExtra(EXTRA_LABEL)?.takeIf(String::isNotBlank)
                ?: previous?.label
                ?: "File operation",
            bytesDone = intent.getLongExtra(EXTRA_BYTES_DONE, previous?.bytesDone ?: 0L),
            totalBytes = intent.getLongExtra(EXTRA_TOTAL_BYTES, previous?.totalBytes ?: 0L),
            destination = intent.getStringExtra(EXTRA_DESTINATION)?.takeIf(String::isNotBlank)
                ?: previous?.destination.orEmpty(),
        )
        publishForeground()
    }

    private fun applyFinish(intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        if (id.isBlank()) return
        val removed = active.remove(id) ?: return
        completed++
        val wasCancelled = intent.getBooleanExtra(EXTRA_CANCELLED, false)
        if (wasCancelled) cancelled++
        else if (!intent.getBooleanExtra(EXTRA_SUCCESS, true)) failed++
        if (active.isNotEmpty()) {
            publishForeground()
            return
        }

        val elapsed = System.currentTimeMillis() - sessionStartedAtMs
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
        if (elapsed >= COMPLETION_MIN_DURATION_MS || failed > 0) {
            notificationManager().notify(COMPLETION_NOTIFICATION_ID, completionNotification(removed))
        }
        stopSelf()
    }

    private fun publishForeground() {
        val notification = progressNotification()
        if (!foreground) {
            runCatching {
                ServiceCompat.startForeground(
                    this,
                    PROGRESS_NOTIFICATION_ID,
                    notification,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    } else {
                        0
                    },
                )
                foreground = true
            }.onFailure {
                android.util.Log.w(TAG, "Could not start long-operation foreground service", it)
                active.clear()
                stopSelf()
            }
        } else {
            notificationManager().notify(PROGRESS_NOTIFICATION_ID, notification)
        }
    }

    private fun progressNotification(): Notification {
        val operations = active.values
        val determinate = operations.isNotEmpty() && operations.all { it.totalBytes > 0L }
        val done = operations.sumOf { it.bytesDone.coerceAtLeast(0L) }
        val total = if (determinate) operations.sumOf { it.totalBytes } else 0L
        val only = operations.singleOrNull()
        val title = only?.label ?: "${operations.size} operations"
        val text = if (determinate) {
            "${formatBytes(done)} of ${formatBytes(total)}"
        } else if (operations.size == 1) {
            "Working in the background"
        } else {
            "${operations.size} operations running in the background"
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(openOperationIntent(only?.destination.orEmpty()))
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)

        if (determinate) {
            val fraction = if (total > 0L) {
                (done.coerceIn(0L, total).toDouble() / total * 1_000).toInt()
            } else {
                0
            }
            builder.setProgress(1_000, fraction, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun completionNotification(last: OperationState): Notification {
        val title = when {
            failed > 0 -> "Operations finished with errors"
            cancelled > 0 -> "Operations cancelled"
            else -> "Operations complete"
        }
        val text = when {
            completed == 1 && cancelled == 1 -> "${last.label} cancelled"
            completed == 1 && failed == 1 -> "${last.label} failed"
            completed == 1 -> "${last.label} completed"
            failed > 0 -> "$completed finished · $failed failed · $cancelled cancelled"
            cancelled > 0 -> "$completed finished · $cancelled cancelled"
            else -> "$completed operations completed"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(openOperationIntent(last.destination))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
    }

    private fun openOperationIntent(destination: String): PendingIntent = PendingIntent.getActivity(
        this,
        destination.hashCode(),
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            if (destination.isNotBlank()) data = Uri.parse("omniterm://notification/$destination")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        },
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun stopNow() {
        active.clear()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        notificationManager().createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Long-running operations",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Progress for file transfers and other work continuing in the background"
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(NotificationManager::class.java)

    companion object {
        const val ACTION_START_OR_UPDATE = "com.jetsetslow.omniterm.operation.START_OR_UPDATE"
        const val ACTION_FINISH = "com.jetsetslow.omniterm.operation.FINISH"
        const val ACTION_STOP = "com.jetsetslow.omniterm.operation.STOP"
        const val EXTRA_ID = "operation_id"
        const val EXTRA_LABEL = "operation_label"
        const val EXTRA_BYTES_DONE = "bytes_done"
        const val EXTRA_TOTAL_BYTES = "total_bytes"
        const val EXTRA_DESTINATION = "operation_destination"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_CANCELLED = "cancelled"
        const val CHANNEL_ID = "omniterm_long_operations"
        const val PROGRESS_NOTIFICATION_ID = 0x4f50
        const val COMPLETION_NOTIFICATION_ID = 0x4f51
        private const val COMPLETION_MIN_DURATION_MS = 3_000L
        private const val TAG = "LongOperationService"
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1_024L) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = -1
    while (value >= 1_024.0 && unit < units.lastIndex) {
        value /= 1_024.0
        unit++
    }
    return String.format(Locale.US, if (value >= 10) "%.0f %s" else "%.1f %s", value, units[unit])
}
