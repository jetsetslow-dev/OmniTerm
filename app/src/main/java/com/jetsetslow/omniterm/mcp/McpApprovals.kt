package com.jetsetslow.omniterm.mcp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.mcp.McpApprovalRequest
import com.jetsetslow.omniterm.data.mcp.McpSettings
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs an AI assistant asked for, waiting for the user's answer on the phone. Each request shows a
 * notification; tapping it opens OmniTerm, where the request is shown in full and approving it
 * needs App Lock, the screen lock, or a plain confirm on a phone without one. Denying needs
 * nothing, from the notification or the app. No answer within the time limit is a no.
 */
object McpApprovals {
    class Pending(val id: Int, val request: McpApprovalRequest, internal val answer: CompletableDeferred<Boolean>)

    private val ids = AtomicInteger(1)
    private val _pending = MutableStateFlow<List<Pending>>(emptyList())
    /** Requests waiting for an answer, oldest first. */
    val pending: StateFlow<List<Pending>> = _pending

    const val CHANNEL = "mcp_approvals"
    private const val NOTIFICATION_BASE = 7_200
    const val ACTION_DENY = "com.jetsetslow.omniterm.action.MCP_DENY"
    const val EXTRA_ID = "com.jetsetslow.omniterm.extra.MCP_REQUEST"

    /** Asks the user about [request]; true only if they approve within [timeoutMs]. */
    suspend fun ask(context: Context, request: McpApprovalRequest, timeoutMs: Long): Boolean {
        val pending = Pending(ids.getAndIncrement(), request, CompletableDeferred())
        _pending.update { it + pending }
        notify(context.applicationContext, pending)
        return try {
            withTimeoutOrNull(timeoutMs) { pending.answer.await() } ?: false
        } finally {
            _pending.update { list -> list.filterNot { it.id == pending.id } }
            context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_BASE + pending.id % 1_000)
        }
    }

    /** The user's answer to request [id]; approving is the caller's to gate behind the lock. */
    fun answer(id: Int, approved: Boolean) {
        _pending.value.find { it.id == id }?.answer?.complete(approved)
    }

    /** Says no to everything waiting, as when the server is turned off. */
    fun denyAll() {
        _pending.value.forEach { it.answer.complete(false) }
    }

    private fun notify(context: Context, pending: Pending) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, context.getString(R.string.mcp_approval_channel), NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val open = PendingIntent.getActivity(
            context, pending.id,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val deny = PendingIntent.getBroadcast(
            context, pending.id,
            Intent(context, McpApprovalReceiver::class.java).setAction(ACTION_DENY).putExtra(EXTRA_ID, pending.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val r = pending.request
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_omniterm)
            .setContentTitle(context.getString(R.string.mcp_approval_title, r.clientName))
            .setContentText(context.getString(R.string.mcp_approval_text, r.action, r.hosts.joinToString(", ")))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setTimeoutAfter(McpSettings.APPROVAL_TIMEOUT_MS)
            .addAction(0, context.getString(R.string.mcp_approval_review), open)
            .addAction(0, context.getString(R.string.mcp_approval_deny), deny)
            .build()
        // Without the notification permission nothing shows, but the request still appears in the app.
        runCatching { context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_BASE + pending.id % 1_000, notification) }
    }
}

/** The notification's "Deny": no lock needed to say no. */
class McpApprovalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != McpApprovals.ACTION_DENY) return
        McpApprovals.answer(intent.getIntExtra(McpApprovals.EXTRA_ID, -1), approved = false)
    }
}
