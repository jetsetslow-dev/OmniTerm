package com.jetsetslow.omniterm.automation

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.ui.NotificationLinks

/**
 * The notification of one run another app or an AI assistant started, as its token's [RunNotify]
 * choice says: progress while it runs, then the result, or nothing once every host succeeded. A
 * tap opens the run in Fleet's history. [by] names who started it ("Tasker", "Claude Code").
 * Without the notification permission nothing shows, and the run is still in the history.
 */
internal class RunNotifications(
    context: Context,
    private val runKey: String,
    private val scriptName: String,
    private val by: String,
    private val policy: String,
) {
    companion object {
        const val CHANNEL = "external_runs"
        private const val ID_BASE = 7_300

        /** One notification per run: its progress, then its result, under the same id. */
        fun idFor(runKey: String): Int = ID_BASE + Math.floorMod(runKey.hashCode(), 1_000)
    }

    private val context = context.applicationContext
    private val id = idFor(runKey)
    private val manager get() = context.getSystemService(NotificationManager::class.java)
    private val who get() = by.ifBlank { context.getString(R.string.external_run_someone) }

    fun progress(done: Int, total: Int) {
        if (!RunNotify.showsProgress(policy)) return
        post(
            builder(context.getString(R.string.external_run_running_title, who, scriptName))
                .setContentText(context.getString(R.string.external_run_progress, done, total))
                .setProgress(total, done, false)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true),
        )
    }

    fun finished(result: Automation.RunResult) {
        if (!RunNotify.keepsResult(policy, result.succeeded)) {
            runCatching { manager?.cancel(id) }
            return
        }
        val text = when {
            result.succeeded -> context.resources.getQuantityString(R.plurals.external_run_succeeded, result.ran.size, result.ran.size)
            result.error != null -> result.error
            result.failed.isNotEmpty() -> context.getString(R.string.external_run_failed_on, result.failed.joinToString(", ") { it.name })
            else -> result.errorMessage ?: context.getString(R.string.external_run_nothing_ran)
        }
        post(
            builder(context.getString(R.string.external_run_done_title, who, scriptName))
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                // A failure is worth a sound; a success the user asked to see is not.
                .setSilent(result.succeeded),
        )
    }

    private fun builder(title: String): NotificationCompat.Builder {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching {
                manager?.createNotificationChannel(
                    NotificationChannel(CHANNEL, context.getString(R.string.external_runs_channel), NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
        }
        val open = PendingIntent.getActivity(
            context, id,
            Intent(context, MainActivity::class.java)
                .setData(Uri.parse(NotificationLinks.fleetRun(runKey)))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentTitle(title)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
    }

    private fun post(builder: NotificationCompat.Builder) {
        runCatching { manager?.notify(id, builder.build()) }
    }
}
