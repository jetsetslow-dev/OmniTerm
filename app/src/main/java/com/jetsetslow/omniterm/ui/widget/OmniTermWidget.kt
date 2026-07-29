package com.jetsetslow.omniterm.ui.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.lazy.itemsIndexed
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** One widget row: the host plus its freshest persisted telemetry (may be null/stale). */
private data class WidgetServerRow(
    val server: ServerEntity,
    val metric: MetricHistoryEntity?,
)

class OmniTermWidget : GlanceAppWidget(errorUiLayout = R.layout.omniterm_widget_error) {

    companion object {
        private val COMPACT = DpSize(110.dp, 110.dp)
        private val FULL = DpSize(250.dp, 140.dp)

        // Metrics older than this are shown dimmed with an age suffix instead of as live values.
        private const val STALE_AFTER_MS = 15 * 60 * 1000L
        private const val LOAD_TIMEOUT_MS = 15_000L
    }

    override val sizeMode = SizeMode.Responsive(setOf(COMPACT, FULL))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // Everything here runs BEFORE provideContent, so any failure (a database open/migration
        // error, a disk problem) means no content is ever supplied and the launcher keeps showing
        // Glance's loading layout — a blank box with a spinner — with no way for the user to tell
        // what went wrong. Degrade to an error row instead of hanging on the placeholder forever.
        val rows = try {
            withTimeout(LOAD_TIMEOUT_MS) { loadWidgetRows(context, id) }
        } catch (timeout: TimeoutCancellationException) {
            android.util.Log.w("OmniTermWidget", "Widget data load timed out", timeout)
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            android.util.Log.w("OmniTermWidget", "Widget data load failed", failure)
            null
        }

        provideContent {
            GlanceTheme {
                if (rows == null) WidgetLoadError(context) else WidgetContent(context, rows)
            }
        }
    }

    private suspend fun loadWidgetRows(context: Context, id: GlanceId): List<WidgetServerRow> {
        val db = AppDatabase.getDatabase(context)
        val allServers = db.serverDao().getAllServers()

        val appWidgetId = runCatching { GlanceAppWidgetManager(context).getAppWidgetId(id) }.getOrNull()
        val prefs = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
        val selectedIds = prefs.getStringSet("widget_$appWidgetId", null)?.mapNotNull { it.toIntOrNull() }?.toSet()

        val servers = if (selectedIds.isNullOrEmpty()) {
            allServers
        } else {
            allServers.filter { it.id in selectedIds }
        }
        // One snapshot query avoids an N+1 database walk every time the launcher refreshes a fleet
        // widget. This matters for larger fleets and for the platform's constrained widget worker.
        val latestByServer = db.metricHistoryDao().getLatestMetricsForAllServers().associateBy { it.serverId }
        return servers.map { WidgetServerRow(it, latestByServer[it.id]) }
    }

    /** Shown when the widget's data could not be read; tapping retries via a normal refresh. */
    @Composable
    private fun WidgetLoadError(context: Context) {
        Column(
            modifier = GlanceModifier.fillMaxSize()
                .background(GlanceTheme.colors.widgetBackground)
                .cornerRadius(16.dp)
                .padding(12.dp)
                .clickable(actionRunCallback<RefreshWidgetAction>()),
            horizontalAlignment = Alignment.Start,
        ) {
            Text(
                text = context.getString(com.jetsetslow.omniterm.R.string.widget_load_failed),
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Bold),
            )
            Text(
                text = context.getString(com.jetsetslow.omniterm.R.string.widget_tap_to_retry),
                style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 12.sp),
            )
        }
    }

    @Composable
    private fun WidgetContent(context: Context, rows: List<WidgetServerRow>) {
        val showMetrics = LocalSize.current.width >= FULL.width
        Column(
            modifier = GlanceModifier.fillMaxSize()
                .background(GlanceTheme.colors.widgetBackground)
                .cornerRadius(16.dp)
                .padding(12.dp),
            horizontalAlignment = Alignment.Start,
        ) {
            Row(
                modifier = GlanceModifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "OmniTerm Fleet (${rows.count { it.server.status == "online" }}/${rows.size})",
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Bold),
                    modifier = GlanceModifier.defaultWeight().clickable(
                        actionStartActivity(Intent(context, MainActivity::class.java))
                    ),
                )
                Text(
                    text = "↻",
                    style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 18.sp, fontWeight = FontWeight.Bold),
                    modifier = GlanceModifier.padding(horizontal = 6.dp)
                        .clickable(actionRunCallback<RefreshWidgetAction>()),
                )
            }
            Spacer(modifier = GlanceModifier.height(8.dp))

            if (rows.isEmpty()) {
                Column(
                    modifier = GlanceModifier.fillMaxWidth().clickable(
                        actionStartActivity(
                            Intent(context, MainActivity::class.java)
                                .setAction("com.jetsetslow.omniterm.action.NEW_HOST")
                        )
                    ),
                ) {
                    Text(
                        text = context.getString(com.jetsetslow.omniterm.R.string.widget_no_servers),
                        style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant),
                    )
                    Text(
                        text = context.getString(com.jetsetslow.omniterm.R.string.widget_add_server),
                        style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 12.sp),
                    )
                }
            } else {
                LazyColumn(modifier = GlanceModifier.fillMaxSize()) {
                    itemsIndexed(rows) { _, row ->
                        ServerRow(context, row, showMetrics)
                    }
                }
            }
        }
    }

    @Composable
    private fun ServerRow(context: Context, row: WidgetServerRow, showMetrics: Boolean) {
        val server = row.server
        val online = server.status == "online"
        val dotColor = when (server.status) {
            "online" -> Color(0xFF66BB6A)
            "connecting" -> Color(0xFFFFB300)
            else -> Color(0xFFE53935)
        }
        Row(
            modifier = GlanceModifier.fillMaxWidth().padding(vertical = 4.dp)
                .clickable(
                    actionStartActivity(
                        Intent(context, MainActivity::class.java)
                            .setAction(Intent.ACTION_VIEW)
                            .putExtra("shortcut_server_id", server.id)
                    )
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = GlanceModifier.size(8.dp).cornerRadius(4.dp).background(ColorProvider(dotColor)),
            ) {}
            Spacer(modifier = GlanceModifier.width(8.dp))
            Text(
                text = server.name.takeIf { it.isNotBlank() } ?: server.host,
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Medium),
                maxLines = 1,
                modifier = GlanceModifier.defaultWeight(),
            )
            if (online) {
                Text(
                    text = "HP ${server.healthScore}",
                    style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 12.sp),
                )
                val metric = row.metric
                if (showMetrics && metric != null) {
                    val age = System.currentTimeMillis() - metric.timestamp
                    val stale = age > STALE_AFTER_MS
                    val label = "CPU ${metric.cpuUsage.toInt()}% · RAM ${metric.ramUsage.toInt()}%" +
                        if (stale) " · ${age / 60000}m ago" else ""
                    Spacer(modifier = GlanceModifier.width(8.dp))
                    Text(
                        text = label,
                        style = TextStyle(
                            color = if (stale) GlanceTheme.colors.onSurfaceVariant else GlanceTheme.colors.onSurface,
                            fontSize = 12.sp,
                        ),
                        maxLines = 1,
                    )
                }
            } else {
                Text(
                    text = if (server.status == "connecting") "…" else "offline",
                    style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp),
                )
            }
        }
    }
}

/** Manual refresh tap target on the widget header. */
class RefreshWidgetAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: androidx.glance.action.ActionParameters) {
        OmniTermWidget().update(context, glanceId)
    }
}

class OmniTermWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OmniTermWidget()

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val editor = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE).edit()
        appWidgetIds.forEach { editor.remove("widget_$it") }
        editor.apply()
    }
}
