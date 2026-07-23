package com.jetsetslow.omniterm.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.lazy.itemsIndexed
import androidx.compose.ui.graphics.Color
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.glance.appwidget.AppWidgetId
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.ServerEntity

class OmniTermWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val allServers = AppDatabase.getDatabase(context).serverDao().getAllServers()
        
        val appWidgetId = (id as? AppWidgetId)?.appWidgetId
        val prefs = context.getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
        val selectedIds = prefs.getStringSet("widget_$appWidgetId", null)?.mapNotNull { it.toIntOrNull() }?.toSet()
        
        val servers = if (selectedIds.isNullOrEmpty()) {
            allServers
        } else {
            allServers.filter { it.id in selectedIds }
        }
        
        provideContent {
            WidgetContent(servers)
        }
    }

    @Composable
    private fun WidgetContent(servers: List<ServerEntity>) {
        Column(
            modifier = GlanceModifier.fillMaxSize().background(ColorProvider(Color(0xFF1E1E2E))).padding(16.dp),
            horizontalAlignment = Alignment.Start
        ) {
            Text(
                text = "OmniTerm Fleet (${servers.size})",
                style = TextStyle(color = ColorProvider(Color(0xFFFFFFFF)), fontWeight = FontWeight.Bold)
            )
            Spacer(modifier = GlanceModifier.height(8.dp))
            
            if (servers.isEmpty()) {
                Text(
                    text = "No servers added.",
                    style = TextStyle(color = ColorProvider(Color(0xFFAAAAAA)))
                )
            } else {
                LazyColumn(
                    modifier = GlanceModifier.fillMaxSize()
                ) {
                    itemsIndexed(servers) { index, server ->
                        Row(
                            modifier = GlanceModifier.fillMaxWidth().padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = server.name.takeIf { it.isNotBlank() } ?: server.host,
                                style = TextStyle(color = ColorProvider(Color(0xFFE0E0E0)), fontWeight = FontWeight.Medium),
                                modifier = GlanceModifier.defaultWeight()
                            )
                            Text(
                                text = server.host,
                                style = TextStyle(color = ColorProvider(Color(0xFF88CC88)))
                            )
                        }
                    }
                }
            }
        }
    }
}

class OmniTermWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OmniTermWidget()
}
