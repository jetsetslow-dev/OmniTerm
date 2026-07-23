package com.jetsetslow.omniterm.ui.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class OmniTermWidgetConfigActivity : ComponentActivity() {

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setResult(RESULT_CANCELED)

        val extras = intent.extras
        if (extras != null) {
            appWidgetId = extras.getInt(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID
            )
        }

        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        setContent {
            var servers by remember { mutableStateOf<List<ServerEntity>>(emptyList()) }
            val selectedIds = remember { mutableStateListOf<Int>() }

            LaunchedEffect(Unit) {
                servers = withContext(Dispatchers.IO) {
                    AppDatabase.getDatabase(this@OmniTermWidgetConfigActivity).serverDao().getAllServers()
                }
            }

            MaterialTheme {
                Scaffold(
                    topBar = {
                        TopAppBar(
                            title = { Text("Select Servers for Widget") },
                            actions = {
                                TextButton(onClick = {
                                    saveConfigAndFinish(selectedIds)
                                }) {
                                    Text("Save")
                                }
                            }
                        )
                    }
                ) { padding ->
                    LazyColumn(contentPadding = padding) {
                        items(servers) { server ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        if (selectedIds.contains(server.id)) {
                                            selectedIds.remove(server.id)
                                        } else {
                                            selectedIds.add(server.id)
                                        }
                                    }
                                    .padding(16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Checkbox(
                                    checked = selectedIds.contains(server.id),
                                    onCheckedChange = null
                                )
                                Spacer(modifier = Modifier.width(16.dp))
                                Text(server.name.takeIf { it.isNotBlank() } ?: server.host)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun saveConfigAndFinish(selectedIds: List<Int>) {
        val prefs = getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
        prefs.edit().putStringSet("widget_$appWidgetId", selectedIds.map { it.toString() }.toSet()).apply()

        CoroutineScope(Dispatchers.IO).launch {
            val manager = GlanceAppWidgetManager(this@OmniTermWidgetConfigActivity)
            val glanceId = manager.getGlanceIdBy(appWidgetId)
            OmniTermWidget().update(this@OmniTermWidgetConfigActivity, glanceId)
            
            val resultValue = Intent().apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            }
            withContext(Dispatchers.Main) {
                setResult(RESULT_OK, resultValue)
                finish()
            }
        }
    }
}
