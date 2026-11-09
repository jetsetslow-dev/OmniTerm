package com.jetsetslow.omniterm.automation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.Automation
import kotlinx.coroutines.launch

/**
 * Checks a request's token off the main thread, then runs it in a job: a receiver only has seconds,
 * a run can take minutes. A token OmniTerm does not know is dropped with no reply; a known one
 * always goes to the job, which also answers when automation is off. [resultCode]
 * turns whether a run started (null: unknown token) into the broadcast's result code, if any.
 */
private fun BroadcastReceiver.checkThenRun(
    context: Context,
    token: String?,
    request: (grantId: Int, tokenHash: String) -> AutomationRequest,
    resultCode: (started: Boolean?) -> Int? = { null },
) {
    val app = context.applicationContext
    val pending = goAsync()
    AutomationJobs.scope.launch {
        var started: Boolean? = false
        try {
            val repository = AutomationJobs.repository(app)
            val grant = AutomationGate(app, repository).grantFor(token)
            if (grant == null) {
                Log.i("OmniTermAutomation", "Ignored a request with a token OmniTerm does not know")
                started = null
                return@launch
            }
            // A known token always gets its answer from the job, even "automation is off", so
            // Tasker hears why on its completion intent like any other result.
            val req = request(grant.id, grant.tokenHash)
            started = AutomationJobs.schedule(app, req)
            if (started != true) {
                AutomationReplies.replyIntent(req, Automation.RunResult(emptyList(), app.getString(R.string.automation_not_started)))
                    ?.let { runCatching { app.sendBroadcast(it) } }
            }
        } catch (e: Exception) {
            Log.w("OmniTermAutomation", "Checking a request failed", e)
            started = false
        } finally {
            resultCode(started)?.let { pending.resultCode = it }
            pending.finish()
        }
    }
}

private fun Intent.stringExtra(name: String): String? = runCatching { getStringExtra(name) }.getOrNull()

/**
 * [Automation.ACTION_RUN]: runs the saved script a token was made for, on its hosts. Tasker's Send
 * Intent, `am broadcast` and any app can send it; only the token decides what runs.
 */
class AutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Automation.ACTION_RUN) return
        val token = intent.stringExtra(Automation.EXTRA_TOKEN)
        val replyPackage = intent.stringExtra(Automation.EXTRA_REPLY_PACKAGE)
        val replyAction = intent.stringExtra(Automation.EXTRA_REPLY_ACTION)
        val requestId = intent.stringExtra(Automation.EXTRA_REQUEST_ID)?.take(200)
        checkThenRun(
            context, token,
            request = { id, hash -> AutomationRequest(id, hash, replyPackage = replyPackage, replyAction = replyAction, requestId = requestId) },
        )
    }
}

/**
 * The Locale/Tasker plug-in's fire receiver: runs the action a plug-in host saved from
 * [TaskerEditActivity]. When the host waits for the result (Tasker sends a completion intent),
 * it is told the result follows, and gets it with %output, %exit and %failed_hosts.
 */
class TaskerFireReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Automation.Plugin.ACTION_FIRE_SETTING) return
        val bundle = runCatching { intent.getBundleExtra(Automation.Plugin.EXTRA_BUNDLE) }.getOrNull()
        val token = Automation.Plugin.tokenFrom(bundle)
        val completion = intent.stringExtra(Automation.Plugin.EXTRA_COMPLETION_INTENT)
            ?.takeIf { AutomationReplies.completionIntent(it) != null }
        val ordered = isOrderedBroadcast
        checkThenRun(
            context, token,
            request = { id, hash -> AutomationRequest(id, hash, completionIntent = completion) },
            resultCode = { started ->
                when {
                    !ordered -> null
                    started != true -> Automation.Plugin.RESULT_FAILED
                    // The result follows on the completion intent.
                    completion != null -> Automation.Plugin.RESULT_PENDING
                    else -> Automation.Plugin.RESULT_OK
                }
            },
        )
    }
}
