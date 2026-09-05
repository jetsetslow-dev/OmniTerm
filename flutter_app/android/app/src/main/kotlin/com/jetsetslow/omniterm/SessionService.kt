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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the app's process alive while SSH sessions are open in the background.
 *
 * Ported from `SessionService.kt` in the Kotlin app. Android stops scheduling a backgrounded process
 * within moments, which for a terminal app means every open shell dies the instant the user checks a
 * message. A foreground service is the only sanctioned way to say "this process is doing something
 * the user asked for".
 *
 * The visible notification is the point rather than a tax: a process holding SSH connections open —
 * and a wake lock — should be something the user can see and stop from where they see it.
 */
class SessionService : Service() {
    companion object {
        const val CHANNEL_ID = "session_channel"
        const val MAIN_NOTIFICATION_ID = 1

        const val ACTION_SYNC = "com.jetsetslow.omniterm.action.SYNC_SESSIONS"
        const val ACTION_STOP = "com.jetsetslow.omniterm.action.STOP_SESSION_SERVICE"
        const val ACTION_DISCONNECT_SESSION = "com.jetsetslow.omniterm.action.DISCONNECT_SESSION"
        const val ACTION_DISCONNECT_ALL = "com.jetsetslow.omniterm.action.DISCONNECT_ALL"

        /** Parallel arrays rather than a parcelable: the payload crosses a method channel first. */
        const val EXTRA_SESSION_IDS = "sessionIds"
        const val EXTRA_SESSION_NAMES = "sessionNames"
        const val EXTRA_SESSION_ID = "sessionId"

        private const val NOTIFICATION_GROUP = "omniterm_sessions"
        private const val MAIN_TITLE = "OmniTerm"

        /**
         * A partial wake lock, renewed rather than held open-endedly.
         *
         * Taken with a timeout so a crashed or wedged app cannot pin the CPU awake until the phone
         * is rebooted; renewed on a timer well inside that window so a legitimately long-running
         * session is not cut off mid-command.
         */
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L
        private const val WAKE_LOCK_RENEW_MS = 5 * 60 * 1000L

        /** Notification ids for per-session rows start above the main one. */
        private const val SESSION_ID_BASE = 100
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val shownSessionIds = mutableSetOf<Int>()
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val renewWakeLock = object : Runnable {
        override fun run() {
            refreshWakeLock()
            handler.postDelayed(this, WAKE_LOCK_RENEW_MS)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent means Android restarted the service after killing the process. The Dart
        // isolate — and with it every SSH session — is gone, so there is nothing left to keep alive
        // and a notification claiming otherwise would be false.
        if (intent == null) {
            stopEverything()
            return START_NOT_STICKY
        }

        createChannel()

        when (intent.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT_ALL -> {
                SessionServiceBridge.emit("disconnectAll", null)
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT_SESSION -> {
                // Reported to Dart, which owns the sessions; the shade is refreshed by the `sync`
                // that follows. Cancelling the row here instead would claim a disconnect that had
                // not happened yet.
                SessionServiceBridge.emit("disconnect", intent.getStringExtra(EXTRA_SESSION_ID))
                return START_NOT_STICKY
            }
        }

        val ids = intent.getStringArrayListExtra(EXTRA_SESSION_IDS).orEmpty()
        val names = intent.getStringArrayListExtra(EXTRA_SESSION_NAMES).orEmpty()
        if (ids.isEmpty()) {
            stopEverything()
            return START_NOT_STICKY
        }

        try {
            startForegroundWith(mainNotification(ids.size))
            refreshWakeLock()
            syncSessionRows(ids, names)
        } catch (t: Throwable) {
            // Foreground start can be refused outright (background-start restrictions, a revoked
            // notification permission). Failing loudly here would take the app down over a
            // notification; the sessions simply do not survive backgrounding.
            android.util.Log.w("SessionService", "Could not start the foreground session service", t)
            stopEverything()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundWith(notification: Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, MAIN_NOTIFICATION_ID, notification, type)
    }

    private fun mainNotification(count: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                setPackage(packageName)
                data = Uri.parse("omniterm://notification/main")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnectAll = PendingIntent.getService(
            this,
            1,
            Intent(this, SessionService::class.java).apply {
                action = ACTION_DISCONNECT_ALL
                setPackage(packageName)
                data = Uri.parse("omniterm://notification/disconnect-all")
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(MAIN_TITLE)
            // The count, not a vague "sessions are active": how many connections a phone is holding
            // open is exactly what a user checking their notification shade wants to know.
            .setContentText(
                if (count == 1) "1 SSH session running in the background."
                else "$count SSH sessions running in the background.",
            )
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setGroup(NOTIFICATION_GROUP)
            .setGroupSummary(true)
            .setOngoing(true)
            .addAction(0, "Disconnect all", disconnectAll)
            .build()
    }

    private fun syncSessionRows(ids: List<String>, names: List<String>) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val wanted = mutableSetOf<Int>()

        ids.forEachIndexed { index, sessionId ->
            val notificationId = SESSION_ID_BASE + sessionId.hashCode().and(0x0000FFFF)
            wanted.add(notificationId)
            manager.notify(
                notificationId,
                sessionNotification(sessionId, names.getOrElse(index) { sessionId }),
            )
        }

        // Rows for sessions that have since closed are removed rather than left behind: a shade
        // entry offering to resume a session that no longer exists is worse than no entry.
        shownSessionIds.filterNot(wanted::contains).forEach(manager::cancel)
        shownSessionIds.clear()
        shownSessionIds.addAll(wanted)
    }

    private fun sessionNotification(sessionId: String, serverName: String): Notification {
        val resume = PendingIntent.getActivity(
            this,
            sessionId.hashCode(),
            Intent(this, MainActivity::class.java).apply {
                setPackage(packageName)
                data = Uri.parse("omniterm://notification/session/$sessionId")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnect = PendingIntent.getService(
            this,
            sessionId.hashCode() + 1,
            Intent(this, SessionService::class.java).apply {
                action = ACTION_DISCONNECT_SESSION
                setPackage(packageName)
                data = Uri.parse("omniterm://notification/disconnect/$sessionId")
                putExtra(EXTRA_SESSION_ID, sessionId)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(serverName)
            .setContentText("Background SSH session — tap to resume.")
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(resume)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setGroup(NOTIFICATION_GROUP)
            .setOngoing(true)
            .addAction(0, "Disconnect", disconnect)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Background SSH sessions",
                // LOW: this notification is a status indicator the user can act on, not an event
                // worth a sound. Alerts have their own high-importance channel so silencing one
                // never silences the other.
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun refreshWakeLock() {
        val lock = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OmniTerm:SessionWakeLock")
            .also {
                it.setReferenceCounted(false)
                wakeLock = it
            }
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        handler.removeCallbacks(renewWakeLock)
        handler.postDelayed(renewWakeLock, WAKE_LOCK_RENEW_MS)
    }

    private fun releaseWakeLock() {
        handler.removeCallbacks(renewWakeLock)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun stopEverything() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.let { nm ->
            shownSessionIds.forEach(nm::cancel)
            // Notification ids outlive this Service instance when Android kills and recreates the
            // process, so the channel is reconciled too — otherwise a previous incarnation leaves
            // orphaned session rows that nothing will ever clean up.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                nm.activeNotifications
                    .filter { it.notification.channelId == CHANNEL_ID }
                    .forEach { nm.cancel(it.id) }
            }
        }
        shownSessionIds.clear()
        releaseWakeLock()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
