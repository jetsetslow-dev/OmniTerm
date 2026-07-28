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
import androidx.lifecycle.lifecycleScope
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.ServerEntity
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
            var loading by remember { mutableStateOf(true) }
            var saving by remember { mutableStateOf(false) }

            LaunchedEffect(Unit) {
                servers = withContext(Dispatchers.IO) {
                    AppDatabase.getDatabase(this@OmniTermWidgetConfigActivity).serverDao().getAllServers()
                }
                // Reconfiguration re-opens this screen: start from the widget's saved selection.
                val saved = getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                    .getStringSet("widget_$appWidgetId", null)
                    ?.mapNotNull { it.toIntOrNull() }
                selectedIds.clear()
                selectedIds.addAll(saved ?: servers.map { it.id })
                loading = false
            }

            MaterialTheme {
                Scaffold(
                    topBar = {
                        TopAppBar(
                            title = { Text("Select Servers for Widget") },
                            actions = {
                                TextButton(onClick = {
                                    if (!saving) {
                                        saving = true
                                        saveConfigAndFinish(selectedIds.toList()) { saving = false }
                                    }
                                }, enabled = !loading && !saving && (servers.isEmpty() || selectedIds.isNotEmpty())) {
                                    Text(if (saving) "Saving…" else "Save")
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

    private fun saveConfigAndFinish(selectedIds: List<Int>, onFailure: () -> Unit) {
        lifecycleScope.launch {
            val glanceId = withContext(Dispatchers.IO) {
                runCatching {
                    GlanceAppWidgetManager(this@OmniTermWidgetConfigActivity)
                        .getGlanceIdBy(appWidgetId)
                }
            }.getOrElse {
                android.widget.Toast.makeText(
                    this@OmniTermWidgetConfigActivity,
                    "This widget is no longer available.",
                    android.widget.Toast.LENGTH_LONG,
                ).show()
                onFailure()
                return@launch
            }

            withContext(Dispatchers.IO) {
                getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet("widget_$appWidgetId", selectedIds.map { it.toString() }.toSet())
                    .commit()
                // A render failure should not strand a valid widget in a permanently-cancelled
                // configuration flow; the platform or the next telemetry write can retry it.
                runCatching {
                    OmniTermWidget().update(this@OmniTermWidgetConfigActivity, glanceId)
                }
            }

            val resultValue = Intent().apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            }
            setResult(RESULT_OK, resultValue)
            finish()
        }
    }
}
