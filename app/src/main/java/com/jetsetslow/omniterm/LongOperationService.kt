package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** One user-started operation whose progress should remain visible while OmniTerm is backgrounded. */
internal data class LongOperationState(
    val id: String,
    val label: String,
    val bytesDone: Long,
    val totalBytes: Long,
    val destination: String = "",
)

/** Honest aggregate progress: determinate only when every active operation has a known size. */
internal data class LongOperationSummary(
    val count: Int,
    val bytesDone: Long,
    val totalBytes: Long,
    val determinate: Boolean,
)

internal fun summarizeLongOperations(operations: Collection<LongOperationState>): LongOperationSummary {
    val determinate = operations.isNotEmpty() && operations.all { it.totalBytes > 0L }
    return LongOperationSummary(
        count = operations.size,
        bytesDone = operations.sumOf { it.bytesDone.coerceAtLeast(0L) },
        totalBytes = if (determinate) operations.sumOf { it.totalBytes } else 0L,
        determinate = determinate,
    )
}

/**
 * Low-importance data-sync foreground service for file and other long-running operations.
 *
 * The work remains owned by the app/ViewModel; this service supplies Android's required visible
 * execution contract and aggregates concurrent operations into one notification. It is separate
 * from [SessionService] so a file copy is never mislabeled as an interactive SSH session.
 */
class LongOperationService : Service() {
    private val active = linkedMapOf<String, LongOperationState>()
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
        active[id] = LongOperationState(
            id = id,
            label = intent.getStringExtra(EXTRA_LABEL)?.takeIf { it.isNotBlank() }
                ?: previous?.label
                ?: "File operation",
            bytesDone = intent.getLongExtra(EXTRA_BYTES_DONE, previous?.bytesDone ?: 0L),
            totalBytes = intent.getLongExtra(EXTRA_TOTAL_BYTES, previous?.totalBytes ?: 0L),
            destination = intent.getStringExtra(EXTRA_DESTINATION)?.takeIf { it.isNotBlank() }
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
        val summary = summarizeLongOperations(active.values)
        val only = active.values.singleOrNull()
        val title = only?.label ?: "${summary.count} operations"
        val text = if (summary.determinate) {
            "${formatBytes(summary.bytesDone)} of ${formatBytes(summary.totalBytes)}"
        } else if (summary.count == 1) {
            "Working in the background"
        } else {
            "${summary.count} operations running in the background"
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

        if (summary.determinate) {
            val fraction = if (summary.totalBytes > 0L) {
                (summary.bytesDone.coerceIn(0L, summary.totalBytes).toDouble() / summary.totalBytes * 1_000)
                    .toInt()
            } else {
                0
            }
            builder.setProgress(1_000, fraction, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun completionNotification(last: LongOperationState): Notification {
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
            .setContentIntent(openOperationIntent(activeDestination = last.destination))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
    }

    private fun openOperationIntent(activeDestination: String): PendingIntent = PendingIntent.getActivity(
        this,
        activeDestination.hashCode(),
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            if (activeDestination.isNotBlank()) {
                data = Uri.parse("omniterm://notification/$activeDestination")
            }
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

/** Process-local controller used by the Kotlin ViewModel. */
object LongOperationNotifications {
    private val activeIds = ConcurrentHashMap.newKeySet<String>()

    fun start(
        context: Context,
        id: String,
        label: String,
        totalBytes: Long = 0L,
        destination: String = "transfers",
    ) {
        if (id.isBlank()) return
        activeIds.add(id)
        dispatch(context, updateIntent(context, id, label, 0L, totalBytes, destination), foreground = true)
    }

    fun update(
        context: Context,
        id: String,
        label: String,
        bytesDone: Long,
        totalBytes: Long,
        destination: String = "",
    ) {
        if (id !in activeIds) return
        dispatch(context, updateIntent(context, id, label, bytesDone, totalBytes, destination), foreground = false)
    }

    fun finish(context: Context, id: String, success: Boolean, cancelled: Boolean = false) {
        if (!activeIds.remove(id)) return
        dispatch(
            context,
            Intent(context, LongOperationService::class.java).apply {
                action = LongOperationService.ACTION_FINISH
                putExtra(LongOperationService.EXTRA_ID, id)
                putExtra(LongOperationService.EXTRA_SUCCESS, success)
                putExtra(LongOperationService.EXTRA_CANCELLED, cancelled)
            },
            foreground = false,
        )
    }

    fun stopAll(context: Context) {
        activeIds.clear()
        dispatch(
            context,
            Intent(context, LongOperationService::class.java).apply {
                action = LongOperationService.ACTION_STOP
            },
            foreground = false,
        )
    }

    private fun updateIntent(
        context: Context,
        id: String,
        label: String,
        bytesDone: Long,
        totalBytes: Long,
        destination: String,
    ) = Intent(context, LongOperationService::class.java).apply {
        action = LongOperationService.ACTION_START_OR_UPDATE
        putExtra(LongOperationService.EXTRA_ID, id)
        putExtra(LongOperationService.EXTRA_LABEL, label)
        putExtra(LongOperationService.EXTRA_BYTES_DONE, bytesDone.coerceAtLeast(0L))
        putExtra(LongOperationService.EXTRA_TOTAL_BYTES, totalBytes.coerceAtLeast(0L))
        putExtra(LongOperationService.EXTRA_DESTINATION, destination)
    }

    private fun dispatch(context: Context, intent: Intent, foreground: Boolean) {
        runCatching {
            if (foreground) ContextCompat.startForegroundService(context, intent)
            else context.startService(intent)
        }.onFailure { android.util.Log.w("LongOperationNotifications", "Could not update notification", it) }
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
