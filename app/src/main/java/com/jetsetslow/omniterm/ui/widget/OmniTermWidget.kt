package com.jetsetslow.omniterm.ui.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.formatTemperature
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

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
    private const val LOAD_TIMEOUT_MS = 8_000L

    suspend fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(
            android.content.ComponentName(context, OmniTermWidgetReceiver::class.java)
        )
        if (ids.isNotEmpty()) update(context, ids)
    }

    suspend fun update(context: Context, appWidgetIds: IntArray) {
        if (appWidgetIds.isEmpty()) return
        val appContext = context.applicationContext
        val rows = withContext(Dispatchers.IO) {
            withTimeout(LOAD_TIMEOUT_MS) { loadRows(appContext) }
        }
        val manager = AppWidgetManager.getInstance(appContext)
        appWidgetIds.forEach { appWidgetId ->
            manager.updateAppWidget(appWidgetId, createRemoteViews(appContext, appWidgetId, rows))
        }
        manager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_rows)
    }

    fun showError(context: Context, appWidgetIds: IntArray) {
        val manager = AppWidgetManager.getInstance(context)
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, R.layout.omniterm_widget_error)
            views.setOnClickPendingIntent(
                R.id.widget_error_root,
                refreshPendingIntent(context, appWidgetId),
            )
            manager.updateAppWidget(appWidgetId, views)
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
    private var rows: List<WidgetServerRow> = emptyList()
    private var measurementSystem = MeasurementSystem.Metric

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        runBlocking(Dispatchers.IO) {
            runCatching {
                withTimeout(8_000L) {
                    val db = AppDatabase.getDatabase(context)
                    val selectedIds = context
                        .getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                        .getStringSet("widget_$appWidgetId", null)
                        ?.mapNotNull { it.toIntOrNull() }
                        ?.toSet()
                    val metrics = db.metricHistoryDao()
                        .getLatestMetricsForAllServers()
                        .associateBy { it.serverId }
                    rows = db.serverDao().getAllServers()
                        .filter { selectedIds.isNullOrEmpty() || it.id in selectedIds }
                        .map { WidgetServerRow(it, metrics[it.id]) }
                    measurementSystem = MeasurementSystem.fromSetting(
                        db.appSettingDao().getSetting("measurement_system")?.value
                    )
                }
            }.onFailure {
                android.util.Log.w("OmniTermWidget", "Widget row load failed", it)
                rows = emptyList()
            }
        }
    }

    override fun onDestroy() {
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
    }

    private fun renderAsync(context: Context, appWidgetIds: IntArray) {
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                OmniTermWidgetUpdater.update(context, appWidgetIds)
            } catch (timeout: TimeoutCancellationException) {
                android.util.Log.w("OmniTermWidget", "Widget data load timed out", timeout)
                OmniTermWidgetUpdater.showError(context, appWidgetIds)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                android.util.Log.w("OmniTermWidget", "Widget refresh failed", failure)
                OmniTermWidgetUpdater.showError(context, appWidgetIds)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
