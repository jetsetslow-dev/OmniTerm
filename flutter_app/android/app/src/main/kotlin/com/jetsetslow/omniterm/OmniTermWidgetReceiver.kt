package com.jetsetslow.omniterm

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONObject

private const val HOME_WIDGET_PREFERENCES = "HomeWidgetPreferences"
private const val WIDGET_SELECTION_PREFERENCES = "widget_prefs"

/** Android home-screen surface fed by the same Drift-backed snapshot Flutter renders. */
class OmniTermWidgetReceiver : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val rows = selectedWidgetRows(context, widgetId, widgetData)
            val views = RemoteViews(context.packageName, R.layout.omniterm_flutter_widget)
            views.setTextViewText(
                R.id.widget_summary,
                "${rows.count { it.optString("status") == "online" }} / ${rows.size} online",
            )
            views.setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("omniterm://widget/fleet"),
                ),
            )
            views.setOnClickPendingIntent(
                R.id.widget_refresh,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("omniterm://widget/refresh"),
                ),
            )
            // "No hosts" and "could not read what the app published" are different facts. Falling
            // through to the empty state told a user with twelve saved hosts to add one — and a
            // home-screen widget gives them no way to ask again. The decision itself lives in
            // `domain/widget_payload.dart`, where it can be tested; this only renders it.
            val published = widgetData.getString("payload_status", null)
            val readable = published == "ok"
            views.setTextViewText(
                R.id.widget_empty,
                if (readable) "Open OmniTerm to add a host"
                else "Could not load fleet data. Open OmniTerm, then refresh the widget.",
            )
            val showRows = readable && rows.isNotEmpty()
            views.setViewVisibility(R.id.widget_empty, if (showRows) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.widget_rows, if (showRows) View.VISIBLE else View.GONE)
            views.setRemoteAdapter(
                R.id.widget_rows,
                Intent(context, OmniTermWidgetService::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                    .setData(Uri.parse("omniterm://widget/$widgetId/rows")),
            )
            views.setPendingIntentTemplate(
                R.id.widget_rows,
                rowPendingIntentTemplate(context, widgetId),
            )
            appWidgetManager.updateAppWidget(widgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(widgetId, R.id.widget_rows)
        }
    }

    private fun rowPendingIntentTemplate(context: Context, widgetId: Int): PendingIntent {
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        return PendingIntent.getActivity(
            context,
            widgetId,
            Intent(context, MainActivity::class.java)
                .setAction(HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION)
                .setData(Uri.parse("omniterm://widget/$widgetId/server")),
            PendingIntent.FLAG_UPDATE_CURRENT or mutable,
        )
    }
}

class OmniTermWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = WidgetRowsFactory(
        applicationContext,
        intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ),
    )
}

private class WidgetRowsFactory(
    private val context: Context,
    private val widgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
    @Volatile private var rows: List<JSONObject> = emptyList()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        rows = selectedWidgetRows(
            context,
            widgetId,
            context.getSharedPreferences(HOME_WIDGET_PREFERENCES, Context.MODE_PRIVATE),
        )
    }

    override fun onDestroy() {
        rows = emptyList()
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews? {
        val row = rows.getOrNull(position) ?: return null
        val status = row.optString("status", "offline")
        val views = RemoteViews(context.packageName, R.layout.omniterm_flutter_widget_row)
        views.setTextViewText(
            R.id.widget_row_name,
            row.optString("name").ifBlank { row.optString("host", "Host") },
        )
        views.setTextViewText(
            R.id.widget_row_state,
            if (status == "online") "ONLINE · ${row.optInt("health", 0)}%" else status.uppercase(),
        )
        views.setOnClickFillInIntent(
            R.id.widget_row,
            Intent().setData(Uri.parse("omniterm://widget/server/${row.optInt("id")}")),
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = rows.getOrNull(position)?.optLong("id") ?: position.toLong()
    override fun hasStableIds(): Boolean = true
}

internal fun selectedWidgetRows(
    context: Context,
    widgetId: Int,
    widgetData: SharedPreferences,
): List<JSONObject> {
    val raw = runCatching { JSONArray(widgetData.getString("servers_json", "[]")) }
        .getOrElse { JSONArray() }
    val selected = context.getSharedPreferences(WIDGET_SELECTION_PREFERENCES, Context.MODE_PRIVATE)
        .getStringSet("widget_$widgetId", null)
        ?.mapNotNull { it.toIntOrNull() }
        ?.toSet()
    return buildList {
        for (index in 0 until raw.length()) {
            val row = raw.optJSONObject(index) ?: continue
            if (selected.isNullOrEmpty() || row.optInt("id") in selected) add(row)
        }
    }
}
