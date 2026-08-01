package com.jetsetslow.omniterm.ui.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.OperationGeneration
import com.jetsetslow.omniterm.ui.formatTemperature
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Bound on every widget data load, so a slow database can never wedge the launcher's binder call. */
private const val WIDGET_LOAD_TIMEOUT_MS = 8_000L

/**
 * Run a widget render and classify its outcome: returns the failure to report, or null on success.
 *
 * The ordering of these catches is the contract, not an implementation detail.
 * [TimeoutCancellationException] IS a [CancellationException], so a handler that checks
 * `CancellationException` first swallows the render timeout as if the caller had been cancelled.
 * In a coroutine that means silent termination -- no crash and no log -- so any code after the call
 * (finishing an Activity, clearing a "Saving…" flag) never runs and the UI wedges permanently.
 *
 * A timeout is a *recoverable render failure* and must be returned. Genuine cancellation (the
 * caller's scope going away) must still propagate, or the caller would keep working after teardown.
 */
internal suspend fun runWidgetRender(block: suspend () -> Unit): Throwable? =
    try {
        block()
        null
    } catch (timeout: TimeoutCancellationException) {
        timeout
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Throwable) {
        failure
    }

/** One widget row: the host plus its freshest persisted telemetry (may be null/stale). */
internal data class WidgetServerRow(
    val server: ServerEntity,
    val metric: MetricHistoryEntity?,
)

/**
 * Renders widgets directly through [AppWidgetManager].
 *
 * Glance 1.1 delegated every update to WorkManager. That made update() return after enqueueing,
 * so a worker that never started could leave the launcher's initial "Loading OmniTerm" layout in
 * place forever. Direct RemoteViews keep the load, render, and launcher update in one bounded
 * operation whose failure can be surfaced immediately.
 */
object OmniTermWidgetUpdater {
    suspend fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(
            android.content.ComponentName(context, OmniTermWidgetReceiver::class.java)
        )
        if (ids.isNotEmpty()) update(context, ids)
    }

    suspend fun update(
        context: Context,
        appWidgetIds: IntArray,
        publishIfCurrent: (Int, () -> Unit) -> Unit = { _, publish -> publish() },
    ) {
        if (appWidgetIds.isEmpty()) return
        val appContext = context.applicationContext
        val rows = withContext(Dispatchers.IO) {
            withTimeout(WIDGET_LOAD_TIMEOUT_MS) { loadRows(appContext) }
        }
        val manager = AppWidgetManager.getInstance(appContext)
        withContext(Dispatchers.IO) {
            appWidgetIds.forEach { appWidgetId ->
                publishIfCurrent(appWidgetId) {
                    manager.updateAppWidget(
                        appWidgetId,
                        createRemoteViews(appContext, appWidgetId, rows),
                    )
                    // Keep this off the main thread: the launcher may answer it by re-entering our
                    // RemoteViewsFactory.onDataSetChanged() synchronously, which blocks on a DB read.
                    manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_rows)
                }
            }
        }
    }

    fun showLoading(context: Context, appWidgetIds: IntArray) {
        val manager = AppWidgetManager.getInstance(context)
        appWidgetIds.forEach { appWidgetId ->
            manager.updateAppWidget(
                appWidgetId,
                RemoteViews(context.packageName, R.layout.omniterm_widget_loading),
            )
        }
    }

    fun showError(
        context: Context,
        appWidgetIds: IntArray,
        publishIfCurrent: (Int, () -> Unit) -> Unit = { _, publish -> publish() },
    ) {
        val manager = AppWidgetManager.getInstance(context)
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, R.layout.omniterm_widget_error)
            views.setOnClickPendingIntent(
                R.id.widget_error_root,
                refreshPendingIntent(context, appWidgetId),
            )
            publishIfCurrent(appWidgetId) { manager.updateAppWidget(appWidgetId, views) }
        }
    }

    private suspend fun loadRows(context: Context): List<WidgetServerRow> {
        val db = AppDatabase.getDatabase(context)
        val allServers = db.serverDao().getAllServers()
        val latestByServer = db.metricHistoryDao()
            .getLatestMetricsForAllServers()
            .associateBy { it.serverId }
        return allServers.map { server -> WidgetServerRow(server, latestByServer[server.id]) }
    }

    private fun createRemoteViews(
        context: Context,
        appWidgetId: Int,
        allRows: List<WidgetServerRow>,
    ): RemoteViews {
        val selectedIds = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
            .getStringSet("widget_$appWidgetId", null)
            ?.mapNotNull { it.toIntOrNull() }
            ?.toSet()
        val rows = if (selectedIds.isNullOrEmpty()) {
            allRows
        } else {
            allRows.filter { it.server.id in selectedIds }
        }

        return RemoteViews(context.packageName, R.layout.omniterm_widget).apply {
            setTextViewText(
                R.id.widget_title,
                context.getString(
                    R.string.widget_fleet_summary,
                    rows.count { it.server.status == "online" },
                    rows.size,
                ),
            )
            setOnClickPendingIntent(R.id.widget_title, openAppPendingIntent(context, appWidgetId))
            setOnClickPendingIntent(R.id.widget_refresh, refreshPendingIntent(context, appWidgetId))

            if (rows.isEmpty()) {
                setViewVisibility(R.id.widget_empty, View.VISIBLE)
                setViewVisibility(R.id.widget_rows, View.GONE)
                setOnClickPendingIntent(
                    R.id.widget_empty,
                    addHostPendingIntent(context, appWidgetId),
                )
                return@apply
            }

            setViewVisibility(R.id.widget_empty, View.GONE)
            setViewVisibility(R.id.widget_rows, View.VISIBLE)
            val serviceIntent = Intent(context, OmniTermWidgetService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                .setData(widgetUri(appWidgetId, "rows"))
            setRemoteAdapter(R.id.widget_rows, serviceIntent)
            setPendingIntentTemplate(
                R.id.widget_rows,
                serverPendingIntentTemplate(context, appWidgetId),
            )
        }
    }

    private fun openAppPendingIntent(context: Context, appWidgetId: Int): PendingIntent =
        activityPendingIntent(
            context,
            appWidgetId,
            "fleet",
            Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN),
        )

    private fun addHostPendingIntent(context: Context, appWidgetId: Int): PendingIntent =
        activityPendingIntent(
            context,
            appWidgetId,
            "new-host",
            Intent(context, MainActivity::class.java)
                .setAction("com.jetsetslow.omniterm.action.NEW_HOST"),
        )

    private fun serverPendingIntentTemplate(
        context: Context,
        appWidgetId: Int,
    ): PendingIntent {
        val mutableFlag =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(
            context,
            appWidgetId,
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(widgetUri(appWidgetId, "server")),
            PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
        )
    }

    private fun activityPendingIntent(
        context: Context,
        appWidgetId: Int,
        destination: String,
        intent: Intent,
    ): PendingIntent {
        intent.data = widgetUri(appWidgetId, destination)
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun refreshPendingIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, OmniTermWidgetReceiver::class.java)
            .setAction(OmniTermWidgetReceiver.ACTION_REFRESH)
            .setData(widgetUri(appWidgetId, "refresh"))
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun widgetUri(appWidgetId: Int, destination: String): Uri =
        Uri.parse("omniterm://widget/$appWidgetId/$destination")
}

/** Supplies scrollable host rows to the launcher-owned widget collection. */
class OmniTermWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        OmniTermWidgetRowFactory(
            applicationContext,
            intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            ),
        )
}

private class OmniTermWidgetRowFactory(
    private val context: Context,
    private val appWidgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
    // onDataSetChanged() loads on one thread while getCount()/getViewAt() read from the launcher's
    // binder thread. Without a memory barrier the launcher can pair a fresh getCount() with a stale
    // row, rendering one host's metrics under another's name.
    @Volatile
    private var rows: List<WidgetServerRow> = emptyList()

    @Volatile
    private var measurementSystem = MeasurementSystem.Metric

    private val loadScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        // The launcher normally calls this on a binder thread, where blocking is expected. But when
        // our own process triggers notifyAppWidgetViewDataChanged() while a widget is visible, the
        // callback can re-enter here on the main thread -- and blocking there ANRs the app. Hand the
        // load to an IO thread and wait only off the main thread, so rows still refresh either way.
        val load = loadScope.async { loadRows() }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // Cannot block the main thread. The load still completes and publishes rows; the
            // launcher picks them up on its next bind, which this update already schedules.
            android.util.Log.w("OmniTermWidget", "onDataSetChanged() on main thread; loading async")
            return
        }
        runBlocking { load.join() }
    }

    /** Reads the selection and telemetry, then publishes both in one write. */
    private suspend fun loadRows() {
        runCatching {
            withTimeout(WIDGET_LOAD_TIMEOUT_MS) {
                val db = AppDatabase.getDatabase(context)
                val selectedIds = context
                    .getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                    .getStringSet("widget_$appWidgetId", null)
                    ?.mapNotNull { it.toIntOrNull() }
                    ?.toSet()
                val metrics = db.metricHistoryDao()
                    .getLatestMetricsForAllServers()
                    .associateBy { it.serverId }
                val loaded = db.serverDao().getAllServers()
                    .filter { selectedIds.isNullOrEmpty() || it.id in selectedIds }
                    .map { WidgetServerRow(it, metrics[it.id]) }
                val system = MeasurementSystem.fromSetting(
                    db.appSettingDao().getSetting("measurement_system")?.value
                )
                // Publish the unit before the rows: getViewAt() formats using it, and the rows write
                // is what makes the new data visible to the launcher's thread.
                measurementSystem = system
                rows = loaded
            }
        }.onFailure {
            android.util.Log.w("OmniTermWidget", "Widget row load failed", it)
            rows = emptyList()
        }
    }

    override fun onDestroy() {
        loadScope.cancel()
        rows = emptyList()
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews? {
        val row = rows.getOrNull(position) ?: return null
        val server = row.server
        return RemoteViews(context.packageName, R.layout.omniterm_widget_row).apply {
            setImageViewResource(
                R.id.widget_status,
                when (server.status) {
                    "online" -> R.drawable.widget_status_online
                    "connecting" -> R.drawable.widget_status_connecting
                    else -> R.drawable.widget_status_offline
                },
            )
            setTextViewText(
                R.id.widget_server_name,
                server.name.takeIf { it.isNotBlank() }
                    ?: context.getString(R.string.widget_unnamed_host),
            )
            setTextViewText(
                R.id.widget_server_health,
                when {
                    server.status == "online" ->
                        context.getString(R.string.widget_health, server.healthScore)
                    server.status == "connecting" ->
                        context.getString(R.string.widget_connecting)
                    else -> context.getString(R.string.widget_offline)
                },
            )
            setTextViewText(R.id.widget_server_metrics, formatMetrics(row.metric))
            setOnClickFillInIntent(
                R.id.widget_server_row,
                Intent()
                    .setData(Uri.parse("omniterm://widget/$appWidgetId/server/${server.id}"))
                    .putExtra("shortcut_server_id", server.id),
            )
        }
    }

    private fun formatMetrics(metric: MetricHistoryEntity?): String {
        if (metric == null) return "CPU — · RAM — · TEMP — · DISK —"
        val temperature = metric.cpuTemperatureC?.let {
            formatTemperature(it, measurementSystem)
        } ?: "—"
        return context.getString(
            R.string.widget_metrics,
            metric.cpuUsage.toInt(),
            metric.ramUsage.toInt(),
            temperature,
            metric.diskUsage.toInt(),
        )
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long =
        rows.getOrNull(position)?.server?.id?.toLong() ?: position.toLong()
    override fun hasStableIds(): Boolean = true
}

class OmniTermWidgetReceiver : AppWidgetProvider() {
    companion object {
        const val ACTION_REFRESH = "com.jetsetslow.omniterm.action.REFRESH_WIDGET"
        private val refreshGenerations = OperationGeneration<Int>()
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        renderAsync(context, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        renderAsync(context, intArrayOf(appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            val appWidgetId = intent.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            )
            if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                renderAsync(context, intArrayOf(appWidgetId))
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val editor = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE).edit()
        appWidgetIds.forEach { editor.remove("widget_$it") }
        editor.apply()
        refreshGenerations.forget(appWidgetIds.toList())
    }

    private fun renderAsync(context: Context, appWidgetIds: IntArray) {
        // RemoteViews has no implicit busy state. Publish this before starting I/O so even a manual
        // refresh of an already-populated widget gives immediate, accessible feedback.
        val generations = refreshGenerations.begin(appWidgetIds.toList())
        OmniTermWidgetUpdater.showLoading(context, appWidgetIds)
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                OmniTermWidgetUpdater.update(context, appWidgetIds) { id, publish ->
                    refreshGenerations.publishIfCurrent(id, generations.getValue(id), publish)
                }
            } catch (timeout: TimeoutCancellationException) {
                android.util.Log.w("OmniTermWidget", "Widget data load timed out", timeout)
                OmniTermWidgetUpdater.showError(context, appWidgetIds) { id, publish ->
                    refreshGenerations.publishIfCurrent(id, generations.getValue(id), publish)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                android.util.Log.w("OmniTermWidget", "Widget refresh failed", failure)
                OmniTermWidgetUpdater.showError(context, appWidgetIds) { id, publish ->
                    refreshGenerations.publishIfCurrent(id, generations.getValue(id), publish)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }
}
