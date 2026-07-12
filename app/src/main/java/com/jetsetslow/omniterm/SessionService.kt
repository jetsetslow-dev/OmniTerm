package com.jetsetslow.omniterm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import com.jetsetslow.omniterm.ui.decodeSessionNotificationPayload

class SessionService : Service() {
    companion object {
        const val CHANNEL_ID = "session_channel"
        const val MAIN_NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.jetsetslow.omniterm.action.STOP_SESSION_SERVICE"
        const val ACTION_UPDATE_SESSIONS = "com.jetsetslow.omniterm.action.UPDATE_SESSIONS"
        const val ACTION_RESUME = "com.jetsetslow.omniterm.action.RESUME_SESSION"
        const val ACTION_DISCONNECT_SESSION = "com.jetsetslow.omniterm.action.DISCONNECT_SESSION"
        const val ACTION_DISCONNECT_ALL = "com.jetsetslow.omniterm.action.DISCONNECT_ALL"
        const val EXTRA_SESSIONS = "sessions" // List of "id\nname" strings
        const val EXTRA_SESSION_ID = "SESSION_ID"
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L
        private const val WAKE_LOCK_RENEW_MS = 5 * 60 * 1000L
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val activeNotificationIds = mutableSetOf<Int>()
    private var wakeLock: PowerManager.WakeLock? = null
    private val wakeLockHandler = Handler(Looper.getMainLooper())
    private val wakeLockRenewal = object : Runnable {
        override fun run() {
            refreshWakeLock()
            wakeLockHandler.postDelayed(this, WAKE_LOCK_RENEW_MS)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Guard against sticky-restart with null intent — process was killed, sessions are gone.
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()

        when (intent.action) {
            ACTION_STOP -> {
                cleanupAndStop()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT_SESSION -> {
                intent.getStringExtra(EXTRA_SESSION_ID)?.let { TerminalSessionManager.disconnectFromNotification(it) }
                updateNotifications(TerminalSessionManager.activeSessions.map { "${it.id}\n${it.serverName}" })
                if (TerminalSessionManager.activeSessions.none { it.isConnected }) cleanupAndStop()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT_ALL -> {
                TerminalSessionManager.disconnectAllFromNotification()
                cleanupAndStop()
                return START_NOT_STICKY
            }
            ACTION_UPDATE_SESSIONS -> {
                val sessions = intent.getStringArrayListExtra(EXTRA_SESSIONS) ?: arrayListOf()
                if (sessions.isEmpty()) {
                    cleanupAndStop()
                    return START_NOT_STICKY
                }
                updateNotifications(sessions)
            }
            else -> {} // First start or unrecognised action — fall through to startMainForeground
        }

        try {
            startMainForeground()
            refreshWakeLock()
        } catch (t: Throwable) {
            android.util.Log.w("SessionService", "Unable to start foreground session service", t)
            releaseWakeLock()
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    private fun cleanupAndStop() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        activeNotificationIds.forEach { nm.cancel(it) }
        activeNotificationIds.clear()
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun refreshWakeLock() {
        val lock = wakeLock ?: run {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OmniTerm:SessionWakeLock").apply {
                setReferenceCounted(false)
                wakeLock = this
            }
        }
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        wakeLockHandler.removeCallbacks(wakeLockRenewal)
        wakeLockHandler.postDelayed(wakeLockRenewal, WAKE_LOCK_RENEW_MS)
    }

    private fun releaseWakeLock() {
        wakeLockHandler.removeCallbacks(wakeLockRenewal)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun startMainForeground() {
        // Tapping the main notification brings app to foreground without attaching a specific session.
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            setPackage(packageName)
            data = Uri.parse("omniterm://notification/main")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val disconnectAllIntent = Intent(this, SessionService::class.java).apply {
            action = ACTION_DISCONNECT_ALL
            setPackage(packageName)
            data = Uri.parse("omniterm://notification/disconnect-all")
        }
        val disconnectAllPendingIntent = PendingIntent.getService(
            this, 2, disconnectAllIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("OmniTerm Service")
            .setContentText("SSH sessions are active in the background.")
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentIntent(contentPendingIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .addAction(0, "Disconnect All", disconnectAllPendingIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            androidx.core.app.ServiceCompat.startForeground(
                this,
                MAIN_NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(MAIN_NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotifications(sessions: List<String>) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val currentIds = mutableSetOf<Int>()

        for (s in sessions) {
            val payload = decodeSessionNotificationPayload(s) ?: continue
            val id = payload.id
            val name = payload.name
            val notifyId = id.hashCode()
            currentIds.add(notifyId)

            // Tap notification content → resume the session in the app.
            val resumeIntent = Intent(this, MainActivity::class.java)
            resumeIntent.setClass(this, MainActivity::class.java)
            resumeIntent.action = ACTION_RESUME
            resumeIntent.data = Uri.parse("omniterm://notification/session/$id/resume")
            resumeIntent.putExtra(EXTRA_SESSION_ID, id)
            resumeIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val resumePendingIntent = PendingIntent.getActivity(
                this, notifyId, resumeIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val disconnectIntent = Intent(this, SessionService::class.java)
            disconnectIntent.setClass(this, SessionService::class.java)
            disconnectIntent.action = ACTION_DISCONNECT_SESSION
            disconnectIntent.data = Uri.parse("omniterm://notification/session/$id/disconnect")
            disconnectIntent.putExtra(EXTRA_SESSION_ID, id)
            // Use a distinct request code offset to avoid colliding with the resume PendingIntent.
            val disconnectPendingIntent = PendingIntent.getService(
                this, notifyId + 10_000, disconnectIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val n = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Terminal: $name")
                .setContentText("Background SSH session — tap to resume.")
                .setSmallIcon(R.drawable.ic_stat_omniterm)
                .setContentIntent(resumePendingIntent)
                .setOngoing(true)
                .addAction(0, "Disconnect", disconnectPendingIntent)
                .build()

            nm.notify(notifyId, n)
        }

        // Cancel notifications for sessions that no longer exist.
        val stale = activeNotificationIds - currentIds
        stale.forEach { nm.cancel(it) }
        activeNotificationIds.clear()
        activeNotificationIds.addAll(currentIds)
    }

    override fun onDestroy() {
        super.onDestroy()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        activeNotificationIds.forEach { nm.cancel(it) }
        activeNotificationIds.clear()
        releaseWakeLock()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Swiping the app away from Recents must NOT drop active SSH sessions. The live connections
        // run on a process-scoped singleton (TerminalSessionManager.scope), so they survive Activity/
        // ViewModel death — but only while the process lives. Re-assert the foreground service + renew
        // the WakeLock here so Android keeps this process around after the task is removed.
        //
        // Honest limitation: a foreground service + WakeLock is the strongest mechanism Android
        // sanctions, but aggressive OEM battery managers (Samsung, Xiaomi, etc.) can still kill the
        // process. The user is nudged to exempt the app from battery optimization for best results.
        runCatching {
            startMainForeground()
            refreshWakeLock()
        }.onFailure {
            releaseWakeLock()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Background SSH sessions",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }
}
