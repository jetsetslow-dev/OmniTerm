package com.jetsetslow.omniterm.automation

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/**
 * One request to run a grant, as it travels from a receiver to [AutomationJobService]: the grant
 * and its token's hash (never the token), and where the result goes.
 */
data class AutomationRequest(
    val grantId: Int,
    val tokenHash: String,
    /** Tasker's completion intent, as an intent: URI. */
    val completionIntent: String? = null,
    val replyPackage: String? = null,
    val replyAction: String? = null,
    val requestId: String? = null,
) {
    fun toExtras(): PersistableBundle = PersistableBundle().apply {
        putInt(KEY_GRANT, grantId)
        putString(KEY_HASH, tokenHash)
        completionIntent?.let { putString(KEY_COMPLETION, it) }
        replyPackage?.let { putString(KEY_REPLY_PACKAGE, it) }
        replyAction?.let { putString(KEY_REPLY_ACTION, it) }
        requestId?.let { putString(KEY_REQUEST_ID, it) }
    }

    companion object {
        private const val KEY_GRANT = "grant"
        private const val KEY_HASH = "hash"
        private const val KEY_COMPLETION = "completion"
        private const val KEY_REPLY_PACKAGE = "replyPackage"
        private const val KEY_REPLY_ACTION = "replyAction"
        private const val KEY_REQUEST_ID = "requestId"

        fun from(extras: PersistableBundle): AutomationRequest? {
            val grantId = extras.getInt(KEY_GRANT, 0).takeIf { it > 0 } ?: return null
            val hash = extras.getString(KEY_HASH)?.takeIf { it.isNotBlank() } ?: return null
            return AutomationRequest(
                grantId, hash,
                completionIntent = extras.getString(KEY_COMPLETION),
                replyPackage = extras.getString(KEY_REPLY_PACKAGE),
                replyAction = extras.getString(KEY_REPLY_ACTION),
                requestId = extras.getString(KEY_REQUEST_ID),
            )
        }
    }
}

object AutomationJobs {
    /** Receivers check tokens here, off the main thread, while their broadcast waits. */
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Job ids are the app's own; a run's id only has to differ from the others still waiting.
    private const val JOB_ID_BASE = 0x4F_4D_00_00
    private val nextJobId = AtomicInteger(Random.nextInt(0, 0x8000))

    fun repository(context: Context) = AppRepository(AppDatabase.getDatabase(context.applicationContext))

    /**
     * Starts [request]'s run as soon as Android allows: an expedited job on Android 12 and later,
     * which an app may start from a broadcast while a foreground service it may not, and a job
     * with no delay before that. False when Android refused both.
     */
    fun schedule(context: Context, request: AutomationRequest): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        val id = JOB_ID_BASE + (nextJobId.getAndIncrement() and 0xFFFF)
        fun builder() = JobInfo.Builder(id, ComponentName(context, AutomationJobService::class.java)).setExtras(request.toExtras())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Out of expedited quota, Android refuses the job rather than delaying it; run it as a plain job then.
            if (scheduler.schedule(builder().setExpedited(true).build()) == JobScheduler.RESULT_SUCCESS) return true
        }
        return scheduler.schedule(builder().setOverrideDeadline(0).build()) == JobScheduler.RESULT_SUCCESS
    }
}

/** Sends a finished run's result where the request asked. */
object AutomationReplies {
    fun deliver(context: Context, request: AutomationRequest, result: Automation.RunResult) {
        request.completionIntent?.let(::completionIntent)?.let { intent ->
            intent.putExtra(Automation.Plugin.EXTRA_RESULT_CODE, if (result.succeeded) Automation.Plugin.RESULT_OK else Automation.Plugin.RESULT_FAILED)
            intent.putExtra(Automation.Plugin.EXTRA_VARIABLES, Automation.Plugin.variables(result))
            sendSafely(context, intent)
        }
        replyIntent(request, result)?.let { sendSafely(context, it) }
    }

    /** The plain reply: a broadcast to the one package the request named, or null when it named none. */
    fun replyIntent(request: AutomationRequest, result: Automation.RunResult): Intent? {
        val pkg = request.replyPackage?.takeIf { it.isNotBlank() } ?: return null
        val action = request.replyAction?.takeIf { it.isNotBlank() } ?: return null
        return Intent(action).setPackage(pkg).apply {
            putExtra(Automation.EXTRA_EXIT, result.exit)
            putExtra(Automation.EXTRA_OUTPUT, result.combinedOutput())
            putExtra(Automation.EXTRA_FAILED_HOSTS, result.failed.joinToString(",") { it.name })
            result.errorMessage?.let { putExtra(Automation.EXTRA_ERROR, it) }
            request.requestId?.let { putExtra(Automation.EXTRA_REQUEST_ID, it) }
        }
    }

    /**
     * Tasker's completion intent from its URI, fit only to be broadcast to the app it names: one
     * that names no app is dropped, since anything listening could read the output, and so is a
     * selector, which could send it somewhere else. (Parsed without `URI_ALLOW_UNSAFE`, the URI
     * cannot grant access to any of OmniTerm's files either: Android drops those flags.)
     */
    fun completionIntent(uri: String): Intent? {
        val intent = runCatching { Intent.parseUri(uri, Intent.URI_INTENT_SCHEME) }.getOrNull() ?: return null
        if (intent.component == null && intent.`package`.isNullOrBlank()) return null
        intent.selector = null
        return intent
    }

    private fun sendSafely(context: Context, intent: Intent) {
        try {
            context.sendBroadcast(intent)
        } catch (e: RuntimeException) {
            Log.w("OmniTermAutomation", "Sending the result failed", e)
        }
    }
}

/** Runs one [AutomationRequest] and sends its result, however the run ends. */
class AutomationJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val runs = ConcurrentHashMap<Int, Job>()

    override fun onStartJob(params: JobParameters): Boolean {
        val request = AutomationRequest.from(params.extras) ?: return false
        runs[params.jobId] = scope.launch {
            val transport = JschSshTransport()
            val result = try {
                AutomationRunner(applicationContext, AutomationJobs.repository(applicationContext), transport)
                    .run(request.grantId, request.tokenHash)
            } catch (e: CancellationException) {
                Automation.RunResult(emptyList(), getString(R.string.automation_stopped))
            } catch (e: Exception) {
                Log.w("OmniTermAutomation", "The run failed", e)
                Automation.RunResult(emptyList(), e.message ?: e.javaClass.simpleName)
            } finally {
                transport.shutdown()
            }
            AutomationReplies.deliver(applicationContext, request, result)
            runs.remove(params.jobId)
            jobFinished(params, false)
        }
        return true
    }

    /** Android stopped the job: the run ends, and its result says so. */
    override fun onStopJob(params: JobParameters): Boolean {
        runs.remove(params.jobId)?.cancel()
        return false
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
