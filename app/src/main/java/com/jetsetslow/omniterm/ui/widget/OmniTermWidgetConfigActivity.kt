package com.jetsetslow.omniterm.ui.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
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
import androidx.lifecycle.lifecycleScope
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.CancellationException
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
            var loadError by remember { mutableStateOf<String?>(null) }
            var loadAttempt by remember { mutableIntStateOf(0) }
            var saving by remember { mutableStateOf(false) }

            LaunchedEffect(loadAttempt) {
                loading = true
                loadError = null
                try {
                    servers = withContext(Dispatchers.IO) {
                        AppDatabase.getDatabase(this@OmniTermWidgetConfigActivity)
                            .serverDao()
                            .getAllServers()
                    }
                    // Reconfiguration re-opens this screen: start from the widget's saved selection.
                    val saved = getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                        .getStringSet("widget_$appWidgetId", null)
                        ?.mapNotNull { it.toIntOrNull() }
                    selectedIds.clear()
                    selectedIds.addAll(saved ?: servers.map { it.id })
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    android.util.Log.w("OmniTermWidget", "Widget configuration load failed", failure)
                    loadError = getString(R.string.widget_config_load_failed)
                }
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
                                }, enabled = !loading && loadError == null && !saving &&
                                    (servers.isEmpty() || selectedIds.isNotEmpty())) {
                                    Text(if (saving) "Saving…" else "Save")
                                }
                            }
                        )
                    }
                ) { padding ->
                    when {
                        loading -> Box(
                            modifier = Modifier.fillMaxSize().padding(padding),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                        loadError != null -> Column(
                            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Text(loadError.orEmpty())
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(onClick = { loadAttempt++ }) {
                                Text(getString(R.string.retry))
                            }
                        }
                        else -> LazyColumn(contentPadding = padding) {
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
    }

    private fun saveConfigAndFinish(selectedIds: List<Int>, onFailure: () -> Unit) {
        lifecycleScope.launch {
            // No getAppWidgetInfo() guard here: during initial placement the widget is not bound
            // yet, so it returns null and would abort the very first save (leaving RESULT_CANCELED
            // and making the launcher drop the widget). The system only starts this activity with
            // a real widget id, and a stale id makes updateAppWidget below a harmless no-op.
            val preferencesSaved = withContext(Dispatchers.IO) {
                try {
                    getSharedPreferences("widget_prefs", MODE_PRIVATE)
                        .edit()
                        .putStringSet(
                            "widget_$appWidgetId",
                            selectedIds.map { it.toString() }.toSet(),
                        )
                        .commit()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    android.util.Log.w("OmniTermWidget", "Widget preference save failed", failure)
                    false
                }
            }
            if (!preferencesSaved) {
                Toast.makeText(
                    this@OmniTermWidgetConfigActivity,
                    "Could not save the widget configuration.",
                    Toast.LENGTH_LONG,
                ).show()
                onFailure()
                return@launch
            }

            // runWidgetRender classifies a render timeout as a reportable failure instead of
            // letting it cancel this coroutine. Previously a TimeoutCancellationException (which
            // IS a CancellationException) was rethrown here, silently killing the save with no
            // crash and no log: setResult/finish/onFailure never ran, so the button stayed on
            // "Saving…" forever and the launcher dropped the widget. The preferences are already
            // committed above, so a slow render must not abandon the save.
            val renderFailure = withContext(Dispatchers.IO) {
                runWidgetRender {
                    OmniTermWidgetUpdater.update(
                        this@OmniTermWidgetConfigActivity,
                        intArrayOf(appWidgetId),
                    )
                }
            }
            if (renderFailure != null) {
                android.util.Log.w("OmniTermWidget", "Initial widget render failed", renderFailure)
                OmniTermWidgetUpdater.showError(
                    this@OmniTermWidgetConfigActivity,
                    intArrayOf(appWidgetId),
                )
            }

            val resultValue = Intent().apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            }
            setResult(RESULT_OK, resultValue)
            finish()
        }
    }
}
