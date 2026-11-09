package com.jetsetslow.omniterm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.core.content.ContextCompat
import com.jetsetslow.omniterm.automation.AutomationReceiver
import com.jetsetslow.omniterm.automation.TaskerFireReceiver
import com.jetsetslow.omniterm.data.Automation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Sends automation requests to the app as other apps do, and listens for the answers: the plain
 * reply to [REPLY], and Tasker's completion intent to [COMPLETE], both sent to this app only.
 */
class AutomationProbe(private val context: Context) {

    fun plainRun(token: String, requestId: String = "r-42"): Intent = Intent(Automation.ACTION_RUN)
        .setClassName(context, AutomationReceiver::class.java.name)
        .putExtra(Automation.EXTRA_TOKEN, token)
        .putExtra(Automation.EXTRA_REPLY_PACKAGE, context.packageName)
        .putExtra(Automation.EXTRA_REPLY_ACTION, REPLY)
        .putExtra(Automation.EXTRA_REQUEST_ID, requestId)

    /** Sends Tasker's ordered fire broadcast for [token] and returns its result code. */
    fun fire(token: String, timeoutMs: Long = ANSWER_MS): Int? {
        val intent = Intent(Automation.Plugin.ACTION_FIRE_SETTING)
            .setClassName(context, TaskerFireReceiver::class.java.name)
            .putExtra(Automation.Plugin.EXTRA_BUNDLE, Automation.Plugin.bundleFor(token))
            .putExtra(Automation.Plugin.EXTRA_COMPLETION_INTENT, Intent(COMPLETE).setPackage(context.packageName).toUri(Intent.URI_INTENT_SCHEME))
        val code = CompletableDeferred<Int>()
        context.sendOrderedBroadcast(
            intent, null,
            object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) { code.complete(resultCode) }
            },
            null, 0, null, Bundle(),
        )
        return runBlocking { withTimeoutOrNull(timeoutMs) { code.await() } }
    }

    /** The first [action] broadcast to this app within [timeoutMs] of [send], or null. */
    fun awaitBroadcast(action: String, timeoutMs: Long, send: () -> Unit): Intent? {
        val got = CompletableDeferred<Intent>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { got.complete(i) }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        try {
            send()
            return runBlocking { withTimeoutOrNull(timeoutMs) { got.await() } }
        } finally {
            context.unregisterReceiver(receiver)
        }
    }

    companion object {
        const val REPLY = "com.jetsetslow.omniterm.test.AUTOMATION_REPLY"
        const val COMPLETE = "com.jetsetslow.omniterm.test.TASKER_COMPLETE"
        const val ANSWER_MS = 30_000L
        /** How long a request that should get no answer is watched. */
        const val QUIET_MS = 5_000L
    }
}
