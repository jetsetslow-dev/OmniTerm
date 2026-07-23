package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.jetsetslow.omniterm.data.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLocale
import com.jetsetslow.omniterm.data.BiometricCryptoGate
import java.io.InputStream
import java.text.DateFormat
import java.util.Date

private fun copySensitiveClipboard(
    context: android.content.Context,
    scope: kotlinx.coroutines.CoroutineScope,
    label: String,
    text: String,
) {
    val manager = context.getSystemService(android.content.ClipboardManager::class.java) ?: return
    val clip = android.content.ClipData.newPlainText(label, text)
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
        clip.description.extras = android.os.PersistableBundle().apply {
            putBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE, true)
        }
    }
    manager.setPrimaryClip(clip)
    scope.launch {
        delay(60_000)
        val stillSame = runCatching {
            manager.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString() == text
        }.getOrDefault(false)
        if (stillSame) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                manager.clearPrimaryClip()
            } else {
                manager.setPrimaryClip(android.content.ClipData.newPlainText("", ""))
            }
        }
    }
}

@Composable
fun ToolsScreen(viewModel: AppViewModel) {
    val toolsItems = listOf(
        Triple(Screen.Alerts, "Alerts & Rules", Icons.Filled.Notifications),
        Triple(Screen.QuickScripts, "Scripts", Icons.Filled.Code),
        Triple(Screen.Network, "Network Tools", Icons.Filled.Lan),
        Triple(Screen.AuthKeys, "Auth & Keys", Icons.Filled.Key),
        Triple(Screen.Backup, "App Backup", Icons.Filled.Backup),
        Triple(Screen.HealthScoring, "Health Scoring", Icons.Filled.MonitorHeart),
        Triple(Screen.Settings, "Settings", Icons.Filled.Settings),
        Triple(Screen.About, "About OmniTerm", Icons.Filled.Info)
    )

    Column(modifier = Modifier.fillMaxSize()) {
        SectionHeader("OmniTerm Utilities")

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize().padding(12.dp)
        ) {
            items(toolsItems) { (scr, label, icon) ->
                OmniCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(110.dp)
                        .clickable { viewModel.navigateTo(scr) }
                ) {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(icon, contentDescription = label, tint = OmniColors.cyan, modifier = Modifier.size(28.dp))
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(label, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    }
                }
            }
        }
    }
}

// Wrapper for sub-tool headers to return back to grid easily
@Composable
fun ToolScaffold(
    viewModel: AppViewModel,
    title: String,
    onAdd: (() -> Unit)? = null,
    addEnabled: Boolean = true,
    content: @Composable () -> Unit
) {
    Column(modifier = Modifier.fillMaxSize()) {
        // Slim inline header (no card) so tool screens don't waste vertical real estate.
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { viewModel.navigateTo(Screen.Tools) }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Spacer(modifier = Modifier.width(4.dp))
            Text(title, fontWeight = FontWeight.Bold, fontSize = 18.sp, fontFamily = OmniFonts.display, modifier = Modifier.weight(1f))

            if (onAdd != null) {
                IconButton(onClick = onAdd, enabled = addEnabled) {
                    Icon(
                        Icons.Filled.Add,
                        contentDescription = "Add",
                        tint = if (addEnabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }
            }
        }
        Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
            content()
        }
    }
}

// 7.1 ALERTS TOOL PANEL
/**
 * Compact global incident view used by the app-bar badge. It owns no navigation and exposes the
 * same immediate incident actions as the full Alerts Center, plus a host refresh for quick
 * verification after remediation.
 */
@Composable
fun AlertsPopup(
    viewModel: AppViewModel,
    onDismiss: () -> Unit,
) {
    val alerts by viewModel.activeAlerts.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000)
            now = System.currentTimeMillis()
        }
    }
    val active = alerts.filter { !it.acknowledged && it.mutedUntil < now }
    val muted = alerts.filter { it.mutedUntil >= now }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .padding(horizontal = 16.dp)
                .widthIn(max = 480.dp)
                .fillMaxWidth()
                .heightIn(max = 560.dp),
            shape = RoundedCornerShape(14.dp),
            tonalElevation = 8.dp,
        ) {
            Column(Modifier.fillMaxWidth().padding(12.dp)) {
                AlertPopupHeader(
                    activeCount = active.size,
                    mutedCount = muted.size,
                    onAcknowledgeAll = viewModel::acknowledgeAllAlerts,
                    onDismiss = onDismiss,
                )

                if (active.isEmpty() && muted.isEmpty()) {
                    Box(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("No active alert incidents.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    AlertPopupIncidentList(
                        active = active,
                        muted = muted,
                        servers = servers,
                        modifier = Modifier.fillMaxWidth().weight(1f, fill = false),
                        onAcknowledge = viewModel::acknowledgeAlert,
                        onMute = viewModel::muteAlertForOneHour,
                        onUnmute = viewModel::unmuteAlert,
                        onRefresh = viewModel::refreshServer,
                    )
                }

                HorizontalDivider(Modifier.padding(top = 12.dp))
                Text(
                    "Rules and incident history are available in Tools → Alerts & Rules.",
                    modifier = Modifier.padding(top = 10.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = OmniTextSize.Meta,
                )
            }
        }
    }
}

@Composable
fun AlertPopupHeader(
    activeCount: Int,
    mutedCount: Int,
    onAcknowledgeAll: () -> Unit,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.NotificationsActive,
            contentDescription = "Notifications Active",
            tint = OmniColors.red,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text("Active alerts", style = MaterialTheme.typography.titleMedium)
            Text(
                "$activeCount firing · $mutedCount muted",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = OmniTextSize.Meta,
            )
        }
        IconButton(onClick = onDismiss) {
            Icon(Icons.Filled.Close, contentDescription = "Close alerts popup")
        }
    }

    if (activeCount > 0) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = onAcknowledgeAll) {
                Text("ACKNOWLEDGE ALL", fontSize = OmniTextSize.Meta)
            }
        }
    }
}

@Composable
fun AlertPopupIncidentList(
    active: List<ActiveAlertEntity>,
    muted: List<ActiveAlertEntity>,
    servers: List<ServerEntity>,
    onAcknowledge: (Int) -> Unit,
    onMute: (Int) -> Unit,
    onUnmute: (Int) -> Unit,
    onRefresh: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier.testTag("alerts-popup-list"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(active, key = { "active-${it.id}" }) { alert ->
            AlertPopupIncidentCard(
                alert = alert,
                server = servers.find { it.id == alert.serverId },
                muted = false,
                onAcknowledge = { onAcknowledge(alert.id) },
                onMuteToggle = { onMute(alert.id) },
                onRefresh = { if (alert.serverId > 0) onRefresh(alert.serverId) },
            )
        }
        if (muted.isNotEmpty()) {
            item(key = "muted-heading") {
                Text(
                    "Muted incidents",
                    fontWeight = FontWeight.Bold,
                    fontSize = OmniTextSize.Dense,
                    color = OmniColors.purple,
                    modifier = Modifier.padding(top = 4.dp, start = 4.dp),
                )
            }
        }
        items(muted, key = { "muted-${it.id}" }) { alert ->
            AlertPopupIncidentCard(
                alert = alert,
                server = servers.find { it.id == alert.serverId },
                muted = true,
                onAcknowledge = null,
                onMuteToggle = { onUnmute(alert.id) },
                onRefresh = { if (alert.serverId > 0) onRefresh(alert.serverId) },
            )
        }
    }
}

@Composable
fun AlertPopupIncidentCard(
    alert: ActiveAlertEntity,
    server: ServerEntity?,
    muted: Boolean,
    onAcknowledge: (() -> Unit)?,
    onMuteToggle: () -> Unit,
    onRefresh: () -> Unit,
) {
    val accent = when {
        muted -> OmniColors.purple
        alert.severity == "CRITICAL" -> OmniColors.red
        else -> OmniColors.amber
    }
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accent) {
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(alert.metricName, fontWeight = FontWeight.Bold, fontSize = OmniTextSize.Dense)
                Text(
                    if (muted) "MUTED" else alert.severity,
                    color = accent,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = OmniTextSize.Tag,
                )
            }
            Text(
                "${server?.name ?: "Server"} · current ${alert.currentValue} · threshold ${alert.thresholdValue}",
                fontSize = OmniTextSize.Meta,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (muted) {
                Text(
                    "Muted until ${formatShortDateTime(alert.mutedUntil)}",
                    fontSize = OmniTextSize.Tag,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onRefresh, enabled = alert.serverId > 0) {
                    Text("REFRESH", fontSize = OmniTextSize.Meta)
                }
                if (onAcknowledge != null) {
                    TextButton(onClick = onAcknowledge) {
                        Text("ACKNOWLEDGE", fontSize = OmniTextSize.Meta)
                    }
                }
                TextButton(onClick = onMuteToggle) {
                    Text(if (muted) "UNMUTE" else "MUTE 1H", fontSize = OmniTextSize.Meta)
                }
            }
        }
    }
}

@Composable
fun AlertsToolView(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    // 0: Firing alerts, 1: Rules Config, 2: History — VM-held so the global swipe gesture can page it.
    val activeTab = viewModel.activeAlertsTab
    val alerts by viewModel.activeAlerts.collectAsStateWithLifecycle()
    val alertHistory by viewModel.alertHistory.collectAsStateWithLifecycle()
    val rules by viewModel.alertRules.collectAsStateWithLifecycle()
    val serversList by viewModel.servers.collectAsStateWithLifecycle()
    var showCreateRuleDialog by remember { mutableStateOf(false) }
    var editRule by remember { mutableStateOf<AlertRuleEntity?>(null) }
    // A mute can expire without a database emission (for example while the host is offline), so a
    // lightweight minute tick keeps the Active/Muted partition honest even with no telemetry.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000)
            now = System.currentTimeMillis()
        }
    }


    ToolScaffold(
        viewModel = viewModel,
        title = "Alerts Center",
        onAdd = if (activeTab == 1) { { showCreateRuleDialog = true } } else null
    ) {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
            // Honest scope: rules are evaluated by the in-app telemetry poller, so alerts only
            // fire while OmniTerm is open. There is no background/push delivery.
            OmniCard(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp), leftAccent = OmniColors.amber) {
                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("In-app monitoring", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            Text(
                                if (viewModel.alertsEnabled) "Global alerts are on." else "Global alerts are off.",
                                fontSize = 11.sp,
                                color = if (viewModel.alertsEnabled) MaterialTheme.colorScheme.onSurfaceVariant else OmniColors.red,
                            )
                        }
                        Switch(
                            checked = viewModel.alertsEnabled,
                            onCheckedChange = { viewModel.saveAlertsEnabled(it) },
                        )
                    }
                    Text(
                        "Rules are checked on each metrics refresh while OmniTerm is open. Alerts will not " +
                            "fire in the background or when the app is closed — keep the app running to monitor.",
                        fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            val visibleAlerts = alerts.filter { !it.acknowledged && it.mutedUntil < now }
            val acknowledgedAlerts = alerts.filter { it.acknowledged && it.mutedUntil < now }
            val mutedAlerts = alerts.filter { it.mutedUntil >= now }

            PrimaryTabRow(selectedTabIndex = activeTab) {
                Tab(selected = activeTab == 0, onClick = { viewModel.activeAlertsTab = 0 }) { Text("Active (${visibleAlerts.size})", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
                Tab(selected = activeTab == 1, onClick = { viewModel.activeAlertsTab = 1 }) { Text("Rules", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
                Tab(selected = activeTab == 2, onClick = { viewModel.activeAlertsTab = 2 }) { Text("History", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            }

            Spacer(modifier = Modifier.height(12.dp))

            if (activeTab == 0) {
                if (visibleAlerts.isEmpty() && mutedAlerts.isEmpty()) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No active alert incidents.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                        if (visibleAlerts.isNotEmpty()) {
                            item {
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                                    TextButton(onClick = { viewModel.acknowledgeAllAlerts() }) { Text("Ack All") }
                                }
                            }
                        }
                        items(visibleAlerts) { alert ->
                            val srv = serversList.find { it.id == alert.serverId }
                            val accentColor = if (alert.acknowledged) Color.Gray
                                              else if (alert.severity == "CRITICAL") OmniColors.red
                                              else OmniColors.amber
                            OmniCard(modifier = Modifier.fillMaxWidth().alpha(if (alert.acknowledged) 0.6f else 1f), leftAccent = accentColor) {
                                Column(modifier = Modifier.padding(12.dp)) {
                                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(alert.metricName, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (alert.acknowledged) Color.Gray else Color.Unspecified)
                                        }
                                        Text(if (alert.acknowledged) "ACKNOWLEDGED" else alert.severity,
                                            color = if (alert.acknowledged) Color.Gray else if (alert.severity == "CRITICAL") Color.Red else Color(0xFFF59E0B),
                                            fontWeight = FontWeight.ExtraBold, fontSize = 11.sp)
                                    }
                                    Text("Threshold: ${alert.thresholdValue}% · Current: ${alert.currentValue}%", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text("Server: ${srv?.name ?: "server"}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(modifier = Modifier.height(8.dp))
                                    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                        if (!alert.acknowledged) {
                                            TextButton(onClick = { viewModel.acknowledgeAlert(alert.id) }) { Text("ACKNOWLEDGE") }
                                        }
                                        TextButton(onClick = { viewModel.muteAlertForOneHour(alert.id) }) { Text("MUTE 1H") }
                                    }
                                }
                            }
                        }
                        if (mutedAlerts.isNotEmpty()) {
                            item {
                                Text(
                                    "Muted incidents",
                                    fontWeight = FontWeight.Bold,
                                    color = OmniColors.purple,
                                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
                                )
                            }
                            items(mutedAlerts) { alert ->
                                val srv = serversList.find { it.id == alert.serverId }
                                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.purple) {
                                    Column(modifier = Modifier.padding(12.dp)) {
                                        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                                            Text(alert.metricName, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                            Text("MUTED", color = OmniColors.purple, fontWeight = FontWeight.ExtraBold, fontSize = 11.sp)
                                        }
                                        Text("Server: ${srv?.name ?: "server"}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        Text("Until ${formatShortDateTime(alert.mutedUntil)}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                            TextButton(onClick = { viewModel.unmuteAlert(alert.id) }) { Text("UNMUTE") }
                                        }
                                    }
                                }
                            }
                        }
                        if (acknowledgedAlerts.isNotEmpty()) {
                            item {
                                Text(
                                    "${acknowledgedAlerts.size} acknowledged incident(s) hidden until recovery.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
                                )
                            }
                        }
                    }
                }
            } else if (activeTab == 1) {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                    item {
                        OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.purple) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(12.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Default alert rules", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                    Text(
                                        "CPU/memory/disk 90%, latency 250ms. Created as editable All Hosts rules.",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                Switch(
                                    checked = viewModel.alertPresetsEnabled,
                                    onCheckedChange = { on ->
                                        if (on) {
                                            confirm.ask(
                                                "Enable default rules?",
                                                "This creates editable All Hosts alert rules for CPU, memory, disk, and latency.",
                                                confirmLabel = "Enable",
                                                destructive = false,
                                            ) {
                                                viewModel.toggleAlertPresets(true)
                                            }
                                        } else {
                                            confirm.ask(
                                                "Disable default rules?",
                                                "This removes the default CPU/memory/disk/latency All Hosts rules. Custom rules you added are kept.",
                                                confirmLabel = "Disable",
                                            ) {
                                                viewModel.toggleAlertPresets(false)
                                            }
                                        }
                                    },
                                )
                            }
                        }
                    }
                    items(rules) { r ->
                        val srv = serversList.find { it.id == r.serverId }
                        OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(12.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(r.metricName, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                    val targetName = if (r.serverId == 0) "All Hosts" else srv?.name ?: "host"
                                    Text("$targetName · Threshold > ${r.thresholdValue}% for ${r.triggerWindow}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (r.notes.isNotBlank()) {
                                        Text(r.notes, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)
                                    }
                                }
                                Row {
                                    IconButton(onClick = { editRule = r }) {
                                        Icon(Icons.Filled.Edit, null, tint = OmniColors.cyan)
                                    }
                                    IconButton(onClick = {
                                        confirm.ask("Delete rule?", "Delete the ${r.metricName} alert rule for ${srv?.name ?: "this host"}?", confirmLabel = "Delete") {
                                            viewModel.deleteAlertRule(r)
                                        }
                                    }) {
                                        Icon(Icons.Filled.Delete, null, tint = Color.Red)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                if (alertHistory.isEmpty()) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No alert history yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                        item {
                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                                TextButton(onClick = {
                                    confirm.ask("Clear history?", "Delete all alert history?", confirmLabel = "Clear") {
                                        viewModel.clearAlertHistory()
                                    }
                                }) { Text("Clear History") }
                            }
                        }
                        items(alertHistory) { item ->
                            val accent = when {
                                item.status == "muted" -> OmniColors.purple
                                item.status == "resolved" -> OmniColors.green
                                item.severity == "CRITICAL" -> OmniColors.red
                                else -> OmniColors.amber
                            }
                            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accent) {
                                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(item.metricName, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                            Text(item.serverName, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                        Text(item.status.uppercase(), color = accent, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                    }
                                    Text(
                                        "Current ${item.currentValue.toInt()} · threshold ${item.thresholdValue.toInt()} · ${item.severity}",
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Text(
                                        "Triggered ${formatShortDateTime(item.triggeredTime)} · recorded ${formatShortDateTime(item.historyTime)}",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showCreateRuleDialog || editRule != null) {
        val existing = editRule
        // Creating supports multiple hosts (one rule per host, or id 0 = "All hosts"); editing an
        // existing rule keeps its single-host identity, so the picker becomes single-select.
        val selectedSrvIds = remember(existing) { mutableStateListOf(existing?.serverId ?: 0) }
        var metricSelect by remember(existing) { mutableStateOf(existing?.metricName ?: "CPU Usage") }
        var threshInput by remember(existing) { mutableStateOf(existing?.thresholdValue?.toString() ?: "80") }
        var severitySelect by remember(existing) { mutableStateOf(existing?.severity ?: "CRITICAL") }
        var notesInput by remember(existing) { mutableStateOf(existing?.notes ?: "") }

        AlertDialog(
            onDismissRequest = { showCreateRuleDialog = false; editRule = null },
            title = { Text(if (existing == null) "Add Alert Rule Trigger" else "Edit Alert Rule") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    HostPickerField(
                        label = if (existing == null) "Hosts" else "Host",
                        servers = serversList,
                        selectedIds = selectedSrvIds.toSet(),
                        singleSelect = existing != null,
                        allHostsOption = true,
                        onToggle = { id ->
                            if (existing != null) {
                                selectedSrvIds.clear(); selectedSrvIds.add(id)
                            } else if (id == 0) {
                                // "All hosts" is exclusive of concrete picks.
                                selectedSrvIds.clear(); selectedSrvIds.add(0)
                            } else {
                                selectedSrvIds.remove(0)
                                if (!selectedSrvIds.remove(id)) selectedSrvIds.add(id)
                            }
                        },
                    )
                    Text("Select Metric Key:")
                    val metricsOptions = listOf("CPU Usage", "Memory Usage", "Disk Usage", "Latency")
                    @OptIn(ExperimentalLayoutApi::class)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        metricsOptions.forEach { opt ->
                            FilterChip(selected = metricSelect == opt, onClick = { metricSelect = opt }, label = { Text(opt) })
                        }
                    }
                    OutlinedTextField(value = threshInput, onValueChange = { threshInput = it }, label = { Text("Threshold value (%)") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(
                        value = notesInput,
                        onValueChange = { notesInput = it },
                        label = { Text("Notes (optional)") },
                        placeholder = { Text("Why this rule exists / what it watches for") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 2,
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = selectedSrvIds.isNotEmpty(),
                    onClick = {
                        val thresh = threshInput.toFloatOrNull() ?: 80f
                        if (existing == null) {
                            // One rule per picked host ("All hosts" collapses to a single id-0 rule).
                            val targets = if (0 in selectedSrvIds) listOf(0) else selectedSrvIds.toList()
                            targets.forEach { srvId ->
                                viewModel.addAlertRule(srvId, metricSelect, "/", thresh, severitySelect, "5m", notesInput.trim())
                            }
                        } else {
                            viewModel.updateAlertRule(existing.copy(serverId = selectedSrvIds.first(), metricName = metricSelect, thresholdValue = thresh, severity = severitySelect, notes = notesInput.trim()))
                        }
                        showCreateRuleDialog = false
                        editRule = null
                    }
                ) {
                    Text("Confirm")
                }
            },
            dismissButton = {
                TextButton(onClick = { showCreateRuleDialog = false; editRule = null }) { Text("Cancel") }
            }
        )
    }
}



// 7.2 CUSTOM SCRIPTS PORTAL PANEL
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun QuickScriptsToolView(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val scripts by viewModel.quickScripts.collectAsStateWithLifecycle()
    var showCreateScriptSheet by remember { mutableStateOf(false) }
    // VM-held so the global swipe gesture can page between Quick scripts / Fleet commands.
    val activeScriptTab = viewModel.activeScriptsTab
    var createScriptTab by remember { mutableStateOf(0) }
    // When non-null the add/edit dialog opens pre-filled to edit this existing script.
    var editScript by remember { mutableStateOf<QuickScriptEntity?>(null) }

    val visibleScripts = if (activeScriptTab == 0) {
        scripts.filter { it.availableForQuick }
    } else {
        scripts.filter { it.availableForFleet }
    }
    // Group by category, preserving the DAO ordering (category, sortOrder, name) within each group.
    val grouped = visibleScripts.groupBy { it.category.ifBlank { "General" } }

    ToolScaffold(
        viewModel = viewModel,
        title = "Scripts",
        onAdd = {
            createScriptTab = activeScriptTab
            showCreateScriptSheet = true
        }
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize()) {
                PrimaryTabRow(selectedTabIndex = activeScriptTab) {
                    Tab(
                        selected = activeScriptTab == 0,
                        onClick = { viewModel.activeScriptsTab = 0 }
                    ) { Text("Quick scripts", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
                    Tab(
                        selected = activeScriptTab == 1,
                        onClick = { viewModel.activeScriptsTab = 1 }
                    ) { Text("Fleet commands", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = if (activeScriptTab == 0) {
                        "Quick scripts run on the currently selected host and can be filtered by OS or platform."
                    } else {
                        "Fleet commands are broadcast commands for multiple hosts or groups from the Fleet screen."
                    },
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                Spacer(Modifier.height(8.dp))

                if (activeScriptTab == 0) {
                    OmniCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp), leftAccent = OmniColors.purple) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Homelab preset scripts", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text(
                                    "Proxmox, CasaOS, Home Assistant, Linux, and general ops snippets. Each script remains editable.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = viewModel.homelabPresetsEnabled,
                                onCheckedChange = { on ->
                                    if (on) {
                                        confirm.ask(
                                            "Enable preset scripts?",
                                            "This adds curated quick scripts for common homelab platforms. You can edit or delete them afterwards.",
                                            confirmLabel = "Enable",
                                            destructive = false,
                                        ) {
                                            viewModel.toggleHomelabPresets(true)
                                        }
                                    } else {
                                        confirm.ask(
                                            "Disable preset scripts?",
                                            "This removes the curated preset scripts, including any edits to them. Your own scripts are kept.",
                                            confirmLabel = "Disable",
                                        ) {
                                            viewModel.toggleHomelabPresets(false)
                                        }
                                    }
                                },
                            )
                        }
                    }
                } else {
                    OmniCard(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp), leftAccent = OmniColors.cyan) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Fleet default commands", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text(
                                    "CPU/RAM, disk, services, logs, containers, ports, and kernel presets for broadcast use.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = viewModel.fleetPresetsEnabled,
                                onCheckedChange = { on ->
                                    if (on) {
                                        confirm.ask(
                                            "Enable fleet defaults?",
                                            "This adds built-in fleet broadcast commands. You can edit or delete them afterwards.",
                                            confirmLabel = "Enable",
                                            destructive = false,
                                        ) {
                                            viewModel.toggleFleetPresets(true)
                                        }
                                    } else {
                                        confirm.ask(
                                            "Disable fleet defaults?",
                                            "This removes the built-in fleet commands, including edits to those defaults. Your own commands are kept.",
                                            confirmLabel = "Disable",
                                        ) {
                                            viewModel.toggleFleetPresets(false)
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))

                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 12.dp)
                ) {
                    grouped.forEach { (category, items) ->
                        item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                            Text(
                                text = category,
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp,
                                color = OmniColors.cyan,
                                modifier = Modifier.padding(top = 8.dp)
                            )
                        }
                        items(items) { s ->
                            OmniCard(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = 84.dp)
                                    .combinedClickable(
                                        onClick = { editScript = s },
                                        onLongClick = { editScript = s }
                                    )
                            ) {
                                Column(modifier = Modifier.padding(12.dp)) {
                                    Row(verticalAlignment = Alignment.Top) {
                                        Text(
                                            text = "${s.emoji} ${s.name}",
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 14.sp,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f)
                                        )
                                        IconButton(
                                            onClick = { editScript = s },
                                            modifier = Modifier.size(24.dp)
                                        ) {
                                            Icon(Icons.Filled.Edit, "Edit script", tint = OmniColors.cyan, modifier = Modifier.size(16.dp))
                                        }
                                        IconButton(
                                            onClick = {
                                                confirm.ask("Delete script?", "Delete quick script \"${s.name}\"?", confirmLabel = "Delete") {
                                                    viewModel.deleteQuickScript(s)
                                                }
                                            },
                                            modifier = Modifier.size(24.dp)
                                        ) {
                                            Icon(Icons.Filled.Delete, "Delete script", tint = Color.Red, modifier = Modifier.size(16.dp))
                                        }
                                    }
                                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        if (s.availableForQuick) OmniTag("Quick", color = OmniColors.green)
                                        if (s.availableForFleet) OmniTag("Fleet", color = OmniColors.cyan)
                                        if (!s.targetOs.equals("Any", ignoreCase = true)) OmniTag(s.targetOs, color = OmniColors.amber)
                                        if (!s.targetSystem.equals("Any", ignoreCase = true)) OmniTag(s.targetSystem, color = OmniColors.purple)
                                    }
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        text = s.command,
                                        fontSize = 10.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        fontFamily = OmniFonts.mono,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (s.notes.isNotBlank()) {
                                        Text(
                                            text = s.notes,
                                            fontSize = 10.sp,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showCreateScriptSheet || editScript != null) {
                val existing = editScript
                val knownCategories = scripts.map { it.category.ifBlank { "General" } }.distinct().sorted()
        val addingFleetCommand = existing == null && createScriptTab == 1
        SharedScriptEditorDialog(
            existing = existing,
            title = if (existing != null) "Edit script" else "Add script",
            initialCategory = if (addingFleetCommand) "Fleet" else "General",
            defaultAvailableForQuick = !addingFleetCommand,
            defaultAvailableForFleet = addingFleetCommand,
            knownCategories = knownCategories,
            onDismiss = { showCreateScriptSheet = false; editScript = null },
            onSave = { draft ->
                if (existing != null) {
                    viewModel.updateQuickScript(
                        existing.copy(
                            emoji = draft.emoji,
                            name = draft.name,
                            command = draft.command,
                            category = draft.category,
                            availableForQuick = draft.availableForQuick,
                            availableForFleet = draft.availableForFleet,
                            targetOs = draft.targetOs,
                            targetSystem = draft.targetSystem,
                            notes = draft.notes,
                        )
                    )
                } else {
                    viewModel.addQuickScript(
                        draft.emoji,
                        draft.name,
                        draft.command,
                        "cyan",
                        false,
                        draft.category,
                        availableForQuick = draft.availableForQuick,
                        availableForFleet = draft.availableForFleet,
                        targetOs = draft.targetOs,
                        targetSystem = draft.targetSystem,
                        notes = draft.notes,
                    )
                }
                showCreateScriptSheet = false
                editScript = null
            }
        )
    }
}

// Shared add/edit dialog for quick scripts. `existing == null` means "add", otherwise "edit".
@Composable
private fun QuickScriptEditorDialog(
    existing: QuickScriptEntity?,
    knownCategories: List<String>,
    onDismiss: () -> Unit,
    onSave: (emoji: String, name: String, command: String, category: String, availableForQuick: Boolean, availableForFleet: Boolean, targetOs: String, targetSystem: String) -> Unit
) {
    var nameInput by remember { mutableStateOf(existing?.name ?: "") }
    var emojiInput by remember { mutableStateOf(existing?.emoji ?: "LIN") }
    var cmdInput by remember { mutableStateOf(existing?.command ?: "") }
    var categoryInput by remember { mutableStateOf(existing?.category?.ifBlank { "General" } ?: "General") }
    var availableForQuick by remember { mutableStateOf(existing?.availableForQuick ?: true) }
    var availableForFleet by remember { mutableStateOf(existing?.availableForFleet ?: false) }
    var targetOs by remember { mutableStateOf(existing?.targetOs?.ifBlank { "Any" } ?: "Any") }
    var targetSystem by remember { mutableStateOf(existing?.targetSystem?.ifBlank { "Any" } ?: "Any") }
    var categoryMenuExpanded by remember { mutableStateOf(false) }
    var osMenuExpanded by remember { mutableStateOf(false) }
    var systemMenuExpanded by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing != null) "Edit script" else "Add script") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(value = emojiInput, onValueChange = { emojiInput = it.take(6).uppercase() }, label = { Text("Shortcut label") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = nameInput, onValueChange = { nameInput = it }, label = { Text("Script name") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = cmdInput, onValueChange = { cmdInput = it }, label = { Text("Command") }, modifier = Modifier.fillMaxWidth(), minLines = 2)
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = availableForQuick, onCheckedChange = { availableForQuick = it })
                        Text("Quick")
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = availableForFleet, onCheckedChange = { availableForFleet = it })
                        Text("Fleet")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(modifier = Modifier.weight(1f)) {
                        OutlinedTextField(
                            value = targetOs,
                            onValueChange = { targetOs = it },
                            label = { Text("Quick OS") },
                            enabled = availableForQuick,
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                IconButton(onClick = { osMenuExpanded = true }, enabled = availableForQuick) {
                                    Icon(Icons.Filled.ArrowDropDown, "Pick OS")
                                }
                            }
                        )
                        DropdownMenu(expanded = osMenuExpanded, onDismissRequest = { osMenuExpanded = false }) {
                            quickScriptOsOptions.forEach { os ->
                                DropdownMenuItem(text = { Text(os) }, onClick = { targetOs = os; osMenuExpanded = false })
                            }
                        }
                    }
                    Box(modifier = Modifier.weight(1f)) {
                        OutlinedTextField(
                            value = targetSystem,
                            onValueChange = { targetSystem = it },
                            label = { Text("Quick system") },
                            enabled = availableForQuick,
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                IconButton(onClick = { systemMenuExpanded = true }, enabled = availableForQuick) {
                                    Icon(Icons.Filled.ArrowDropDown, "Pick system")
                                }
                            }
                        )
                        DropdownMenu(expanded = systemMenuExpanded, onDismissRequest = { systemMenuExpanded = false }) {
                            quickScriptSystemOptions.forEach { system ->
                                DropdownMenuItem(text = { Text(system) }, onClick = { targetSystem = system; systemMenuExpanded = false })
                            }
                        }
                    }
                }
                // Free-text category with a dropdown of existing categories for convenience.
                Box(modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = categoryInput,
                        onValueChange = { categoryInput = it },
                        label = { Text("Category / Group") },
                        modifier = Modifier.fillMaxWidth(),
                        trailingIcon = {
                            IconButton(onClick = { categoryMenuExpanded = true }) {
                                Icon(Icons.Filled.ArrowDropDown, "Pick existing category")
                            }
                        }
                    )
                    DropdownMenu(expanded = categoryMenuExpanded, onDismissRequest = { categoryMenuExpanded = false }) {
                        knownCategories.forEach { cat ->
                            DropdownMenuItem(text = { Text(cat) }, onClick = { categoryInput = cat; categoryMenuExpanded = false })
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = nameInput.isNotBlank() && cmdInput.isNotBlank() && (availableForQuick || availableForFleet),
                onClick = { onSave(emojiInput, nameInput, cmdInput, categoryInput, availableForQuick, availableForFleet, targetOs.ifBlank { "Any" }, targetSystem.ifBlank { "Any" }) }
            ) {
                Text(if (existing != null) "Save changes" else "Add script")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

// 7.2 UNIFIED NETWORK TOOLS (Host Scan · Ping · Traceroute · Port Scan · Wake-on-LAN)
//
// One tabbed screen for all device-side network utilities. The target host is shared across the
// Ping / Traceroute / Port Scan tabs via viewModel.portScannerTarget (a VM-level field that already
// persists across recomposition and tab switches), so a host discovered in Host Scan or typed in one
// tab carries into the others. WoL keeps its own saved-target model.
@Composable
fun NetworkToolView(viewModel: AppViewModel) {
    // Subtab index lives in the VM so the app's global horizontal-swipe gesture (swipeNavigate) can
    // page between these tabs the same way it does Monitor/Infra/SFTP/Fleet.
    val tab = viewModel.activeNetworkTab
    val tabs = listOf("Host Scan", "Wake-on-LAN", "Ping", "Traceroute", "Port Scan", "DNS Lookup", "WHOIS", "Speed Test", "Tunnels")

    ToolScaffold(viewModel, "Network Tools") {
        Column(modifier = Modifier.fillMaxSize()) {
            PrimaryScrollableTabRow(selectedTabIndex = tab, edgePadding = 0.dp, containerColor = Color.Transparent) {
                tabs.forEachIndexed { i, label ->
                    Tab(selected = tab == i, onClick = { viewModel.activeNetworkTab = i }, text = { Text(label, fontSize = 12.sp) })
                }
            }
            Box(modifier = Modifier.fillMaxSize()) {
                when (tab) {
                    0 -> HostScanTab(viewModel, onUseHost = { viewModel.portScannerTarget = it; viewModel.activeNetworkTab = 4 })
                    1 -> WolTab(viewModel)
                    2 -> PingTab(viewModel)
                    3 -> TracerouteTab(viewModel)
                    4 -> PortScanTab(viewModel)
                    5 -> DnsLookupTab(viewModel)
                    6 -> WhoisTab(viewModel)
                    7 -> SpeedTestTab(viewModel)
                    else -> TunnelsTab(viewModel)
                }
            }
        }
    }
}

// ── Host Scan: rich subnet sweep (rDNS hostname, MAC + vendor, open common ports) ──
@Composable
private fun HostScanTab(viewModel: AppViewModel, onUseHost: (String) -> Unit) {
    // Reads the shared session cache: a sweep run from any picker shows up here, and the button
    // force-refreshes it for everyone. Parent of the pickers — same underlying scanHosts() sweep.
    val hosts = viewModel.hostScanResults
    val scanning = viewModel.isLanScanInProgress
    val scope = rememberCoroutineScope()

    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            "Sweep your local network and gather as much detail as possible per host: hostname, MAC + vendor, and which common ports answer. Tap a host to scan its ports.",
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(
            onClick = { scope.launch { viewModel.refreshLanScan(force = true) } },
            modifier = Modifier.fillMaxWidth(),
            enabled = !scanning,
        ) {
            if (scanning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Scanning network…")
            } else {
                Icon(Icons.Filled.Lan, contentDescription = "Lan", modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text(if (hosts.isEmpty()) "Scan network" else "Rescan network")
            }
        }
        if (!scanning && hosts.isEmpty()) {
            Text("No hosts yet — run a scan.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
            items(hosts) { host ->
                ScannedHostCard(
                    host = host,
                    accent = if (host.isOnline) OmniColors.green else MaterialTheme.colorScheme.onSurfaceVariant,
                    trailingIcon = Icons.Filled.NetworkCheck,
                    trailingDesc = "Use as port-scan target",
                    onClick = { onUseHost(host.ip) },
                )
            }
        }
    }
}

// Rich per-host card shared by the Host Scan tab and the LAN host-picker popup, so both surfaces
// show the same detail (status dot, IP, hostname, MAC + vendor, open ports) instead of the old
// cramped IP+MAC row.
@Composable
private fun ScannedHostCard(
    host: AppViewModel.ScannedHost,
    accent: Color,
    onClick: () -> Unit,
    trailingIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    trailingDesc: String? = null,
    trailingTint: Color = OmniColors.cyan,
) {
    OmniCard(
        modifier = Modifier.fillMaxWidth().clickable { onClick() },
        leftAccent = accent,
    ) {
        // SelectionContainer so a long-press can copy an IP/hostname/MAC straight off the card;
        // plain taps still fall through to the card's clickable.
        SelectionContainer {
            Column(modifier = Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(if (host.isOnline) Color(0xFF10B981) else Color.Red))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(host.ip, fontSize = 14.sp, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, modifier = Modifier.weight(1f))
                    if (trailingIcon != null) {
                        Icon(trailingIcon, contentDescription = trailingDesc, tint = trailingTint, modifier = Modifier.size(18.dp))
                    }
                }
                if (host.hostname.isNotBlank()) {
                    Text(host.hostname, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(
                    buildString {
                        append(host.mac.ifBlank { "MAC unavailable" })
                        if (host.vendor.isNotBlank()) append(" · ${host.vendor}")
                    },
                    fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (host.openPorts.isNotEmpty()) {
                    Text(
                        "Open ports: ${host.openPorts.joinToString(", ")}",
                        fontSize = 11.sp, fontFamily = OmniFonts.mono, color = OmniColors.green,
                    )
                }
            }
        }
    }
}

// ── Shared LAN host picker for Ping / Traceroute / Port Scan ──
// Unlike the Host Scan tab, these tabs are about acting on a target the user already has in mind, so
// the discovered-host list must NOT occupy the top of the view by default. Instead this is a single
// button that opens a popup on demand. Opening the popup reuses the session-shared scan cache when
// it's still fresh (no redundant sweep) and only re-scans when stale or forced. Picking a host sets
// portScannerTarget — the field all three tabs read — and closes the popup.
@Composable
private fun LanHostPicker(viewModel: AppViewModel) {
    val coroutineScope = rememberCoroutineScope()
    var showPicker by remember { mutableStateOf(false) }

    OutlinedButton(
        onClick = {
            showPicker = true
            // Reuse a fresh cache; otherwise this kicks off a sweep the popup will show progress for.
            coroutineScope.launch { viewModel.refreshLanScan(force = false) }
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(Icons.Filled.Lan, contentDescription = "Lan", modifier = Modifier.size(18.dp))
        Spacer(modifier = Modifier.width(8.dp))
        Text("Pick LAN host", fontSize = 12.sp)
    }

    if (showPicker) {
        LanHostPickerDialog(
            viewModel = viewModel,
            onDismiss = { showPicker = false },
            onPick = { ip ->
                viewModel.portScannerTarget = ip
                showPicker = false
            },
        )
    }
}

@Composable
private fun LanHostPickerDialog(
    viewModel: AppViewModel,
    onDismiss: () -> Unit,
    onPick: (String) -> Unit,
) {
    val hosts = viewModel.hostScanResults
    val isScanning = viewModel.isLanScanInProgress
    val coroutineScope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Pick a LAN host") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { coroutineScope.launch { viewModel.refreshLanScan(force = true) } },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isScanning,
                ) {
                    if (isScanning) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Scanning network…")
                    } else {
                        Text(if (hosts.isEmpty()) "Scan LAN" else "Rescan LAN", fontSize = 12.sp)
                    }
                }
                if (!isScanning && hosts.isEmpty()) {
                    Text("No hosts yet — run a scan.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(hosts) { host ->
                        ScannedHostCard(
                            host = host,
                            accent = if (viewModel.portScannerTarget == host.ip) OmniColors.cyan else if (host.isOnline) OmniColors.green else MaterialTheme.colorScheme.onSurfaceVariant,
                            onClick = { onPick(host.ip) },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

// ── Ping (device-side ICMP) ──
@Composable
private fun PingTab(viewModel: AppViewModel) {
    var pingTries by remember { mutableStateOf("4") }

    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LanHostPicker(viewModel)
        OutlinedTextField(
            value = viewModel.portScannerTarget,
            onValueChange = { viewModel.portScannerTarget = it },
            label = { Text("Hostname or IP address") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        )
        OutlinedTextField(
            value = pingTries,
            onValueChange = { pingTries = it.filter { c -> c.isDigit() }.take(4) },
            label = { Text("Tries (0 = keep pinging until stopped)") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        Button(
            onClick = {
                if (viewModel.pingRunning) viewModel.stopPing()
                else viewModel.startPing(viewModel.portScannerTarget, pingTries.toIntOrNull() ?: 4)
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.pingRunning || viewModel.portScannerTarget.isNotBlank(),
        ) {
            if (viewModel.pingRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Stop")
            } else {
                Text("Start Ping")
            }
        }
        Text(
            "Pings are sent from this device, so they tell you whether the HOST is reachable on your current network — independent of SSH.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (viewModel.pingLines.isNotEmpty()) {
            OmniCard(modifier = Modifier.fillMaxWidth().weight(1f)) {
                val pingListState = rememberLazyListState()
                LaunchedEffect(viewModel.pingLines.size) {
                    if (viewModel.pingLines.isNotEmpty()) pingListState.animateScrollToItem(viewModel.pingLines.size - 1)
                }
                SelectionContainer {
                    LazyColumn(
                        state = pingListState,
                        modifier = Modifier.fillMaxSize().padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        items(viewModel.pingLines) { line ->
                            Text(
                                line,
                                fontSize = 11.sp,
                                fontFamily = OmniFonts.mono,
                                color = if (line.contains("failed", true) || line.contains("unreachable", true) || line.contains("100% packet loss"))
                                    OmniColors.red else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Traceroute (device-side) ──
@Composable
private fun TracerouteTab(viewModel: AppViewModel) {
    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LanHostPicker(viewModel)
        OutlinedTextField(
            value = viewModel.portScannerTarget,
            onValueChange = { viewModel.portScannerTarget = it },
            label = { Text("Hostname or IP address") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        )
        Button(
            onClick = {
                if (viewModel.tracerouteRunning) viewModel.stopTraceroute()
                else viewModel.startTraceroute(viewModel.portScannerTarget)
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.tracerouteRunning || viewModel.portScannerTarget.isNotBlank(),
        ) {
            if (viewModel.tracerouteRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Stop")
            } else {
                Text("Start Traceroute")
            }
        }
        Text(
            "Traces each network hop from this device to the host. Uses the platform traceroute; if it isn't available, a clear message is shown.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (viewModel.tracerouteLines.isNotEmpty()) {
            OmniCard(modifier = Modifier.fillMaxWidth().weight(1f)) {
                val listState = rememberLazyListState()
                LaunchedEffect(viewModel.tracerouteLines.size) {
                    if (viewModel.tracerouteLines.isNotEmpty()) listState.animateScrollToItem(viewModel.tracerouteLines.size - 1)
                }
                SelectionContainer {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize().padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        items(viewModel.tracerouteLines) { line ->
                            Text(
                                line,
                                fontSize = 11.sp,
                                fontFamily = OmniFonts.mono,
                                color = if (line.contains("not available", true) || line.contains("failed", true))
                                    OmniColors.red else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Port Scan (uses the shared target host) ──
@Composable
private fun PortScanTab(viewModel: AppViewModel) {
    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LanHostPicker(viewModel)

        OutlinedTextField(
            value = viewModel.portScannerTarget,
            onValueChange = { viewModel.portScannerTarget = it },
            label = { Text("Target Host IP (Scan pointer)") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone)
        )

        OutlinedTextField(
            value = viewModel.portScannerRange,
            onValueChange = { viewModel.portScannerRange = it },
            label = { Text("Ports list range (comma-split)") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone)
        )

        Button(
            onClick = { viewModel.runPortScanner() },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.portScannerTarget.isNotBlank() && !viewModel.isPortScannerScanning
        ) {
            if (viewModel.isPortScannerScanning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            } else {
                Text("Initiate Range Scan")
            }
        }

        SelectionContainer(modifier = Modifier.weight(1f)) {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(viewModel.portScannerResults) { (port, status) ->
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = if (status.contains("Open")) OmniColors.green else MaterialTheme.colorScheme.onSurfaceVariant) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("Port $port", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                            Text(status, color = if (status.contains("Open")) Color(0xFF10B981) else Color.Gray, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}

// ── Wake-on-LAN: inline LAN scanner (like the other tabs) + saved targets + add/edit dialog ──
//
// The LAN scanner lives in the tab body, mirroring the Ping/Traceroute/Port Scan LanHostPicker, so
// all five tabs discover hosts the same way. Tapping a scanned host opens the Add dialog pre-filled
// with that host's name, MAC, and broadcast segment. The Add dialog itself is now scan-free.
@Composable
private fun WolTab(viewModel: AppViewModel) {
    val targetComputers by viewModel.wolTargets.collectAsStateWithLifecycle()
    var showAddWol by remember { mutableStateOf(false) }
    var editingTarget by remember { mutableStateOf<WolTargetEntity?>(null) }
    // When a scanned host is tapped, prefill the Add dialog from it.
    var prefill by remember { mutableStateOf<AppViewModel.ScannedWolDevice?>(null) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val context = LocalContext.current

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            WolLanScanner(
                viewModel = viewModel,
                onPick = { device -> prefill = device; showAddWol = true },
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Saved targets", fontWeight = FontWeight.Bold, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = { prefill = null; showAddWol = true }, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp), modifier = Modifier.height(36.dp)) {
                Icon(Icons.Filled.Add, contentDescription = "Add", modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Add target", fontSize = 12.sp)
            }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp).padding(bottom = 12.dp)) {
            items(targetComputers) { target ->
                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(modifier = Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                            WolStatusDot(viewModel, target.ipAddress)
                            Column {
                                Text(target.name, fontWeight = FontWeight.Bold)
                                Text(
                                    buildString {
                                        append("MAC: ${target.macAddress} · Port ${target.port}")
                                        if (target.ipAddress.isNotBlank()) append(" · ${target.ipAddress}")
                                    },
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                if (target.notes.isNotBlank()) {
                                    Text(
                                        target.notes,
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Button(
                                onClick = {
                                    confirm.ask(
                                        "Send wake packet?",
                                        "Send a Wake-on-LAN magic packet to \"${target.name}\" (${target.macAddress})?",
                                        confirmLabel = "Wake",
                                    ) {
                                        viewModel.triggerWol(target) { sent ->
                                            android.widget.Toast.makeText(
                                                context,
                                                if (sent) "Magic packet sent to ${target.name}"
                                                else "Failed to send magic packet to ${target.name}",
                                                android.widget.Toast.LENGTH_SHORT,
                                            ).show()
                                        }
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF10B981)),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                                modifier = Modifier.height(36.dp),
                            ) {
                                Icon(Icons.Filled.Power, contentDescription = "Power", modifier = Modifier.size(15.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("Wake", fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                            }
                            IconButton(onClick = { editingTarget = target }) {
                                Icon(Icons.Filled.Edit, contentDescription = "Edit WOL target", tint = OmniColors.cyan)
                            }
                            IconButton(
                                onClick = {
                                    confirm.ask(
                                        "Delete WOL target?",
                                        "Delete \"${target.name}\" from Wake-on-LAN targets?",
                                        confirmLabel = "Delete",
                                    ) { viewModel.deleteWolTarget(target) }
                                }
                            ) {
                                Icon(Icons.Filled.Delete, contentDescription = "Delete WOL target", tint = Color.Red)
                            }
                        }
                    }
                }
            }
        }
    }

    if (showAddWol || editingTarget != null) {
        val target = editingTarget
        // For an edit, seed from the saved target. For an add, seed from the tapped scanned host (if
        // any), otherwise blank. The remember key includes both so re-opening with a different source
        // re-initializes the fields.
        var name by remember(target, prefill) { mutableStateOf(target?.name ?: prefill?.name ?: "") }
        var mac by remember(target, prefill) { mutableStateOf(target?.macAddress ?: prefill?.mac ?: "") }
        var broadcastIp by remember(target, prefill) {
            mutableStateOf(target?.broadcastIp ?: prefill?.ip?.substringBeforeLast('.')?.plus(".255") ?: "192.168.1.255")
        }
        var ipAddress by remember(target, prefill) { mutableStateOf(target?.ipAddress ?: prefill?.ip ?: "") }
        var port by remember(target, prefill) { mutableStateOf((target?.port ?: 9).toString()) }
        var notes by remember(target, prefill) { mutableStateOf(target?.notes ?: "") }
        fun dismissEditor() {
            showAddWol = false
            editingTarget = null
            prefill = null
        }

        AlertDialog(
            onDismissRequest = { dismissEditor() },
            title = { Text(if (target == null) "Configure WOL Pointer" else "Edit WOL Pointer") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Machine Name") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = mac, onValueChange = { mac = it }, label = { Text("MAC Address target") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = broadcastIp, onValueChange = { broadcastIp = it }, label = { Text("Broadcast IP network segment") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
                    OutlinedTextField(value = ipAddress, onValueChange = { ipAddress = it }, label = { Text("Host IP address (for online status)") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone), singleLine = true)
                    OutlinedTextField(value = port, onValueChange = { port = it.filter { c -> c.isDigit() } }, label = { Text("UDP port") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true)
                    OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes") }, modifier = Modifier.fillMaxWidth(), minLines = 2)
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (target == null) {
                            viewModel.addWolTarget(name, mac, broadcastIp, ipAddress, port.toIntOrNull() ?: 9, notes)
                        } else {
                            viewModel.updateWolTarget(target, name, mac, broadcastIp, ipAddress, port.toIntOrNull() ?: 9, notes)
                        }
                        dismissEditor()
                    },
                    enabled = name.isNotBlank() && mac.isNotBlank() && broadcastIp.isNotBlank(),
                ) {
                    Text(if (target == null) "Add configuration" else "Save changes")
                }
            },
            dismissButton = {
                TextButton(onClick = { dismissEditor() }) { Text("Cancel") }
            }
        )
    }
}

// ── Live online-status dot for a saved WoL target. Polls the host IP (ICMP, ARP-cache fallback)
// every 10s while visible. Grey = no IP configured / checking; green = up; red = no response. ──
@Composable
private fun WolStatusDot(viewModel: AppViewModel, ip: String) {
    // null = unknown/checking, true = online, false = offline.
    var online by remember(ip) { mutableStateOf<Boolean?>(null) }
    // Keying on wolStatusRefreshTick restarts this effect when the WoL tab is pulled to refresh, so the
    // dot re-pings immediately instead of waiting out the rest of its 10s poll interval.
    LaunchedEffect(ip, viewModel.wolStatusRefreshTick) {
        if (ip.isBlank()) { online = null; return@LaunchedEffect }
        while (true) {
            online = viewModel.pingWolHost(ip)
            delay(10_000)
        }
    }
    val color = when (online) {
        true -> Color(0xFF10B981)
        false -> Color.Red
        null -> Color.Gray
    }
    Box(modifier = Modifier.padding(end = 10.dp).size(10.dp).clip(CircleShape).background(color))
}

// ── LAN scanner for the Wake-on-LAN tab. Like LanHostPicker, the discovered-host list lives in a
// popup (opened on demand) rather than inline, so it doesn't push the saved targets down the screen.
// Instead of setting a shared target, it hands the tapped host to [onPick] so the caller can open the
// Add-target dialog pre-filled from it.
@Composable
private fun WolLanScanner(viewModel: AppViewModel, onPick: (AppViewModel.ScannedWolDevice) -> Unit) {
    val coroutineScope = rememberCoroutineScope()
    var showPicker by remember { mutableStateOf(false) }

    OutlinedButton(
        onClick = {
            showPicker = true
            // Reuse a fresh session-cached scan; only sweep when stale (see refreshLanScan).
            coroutineScope.launch { viewModel.refreshLanScan(force = false) }
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(Icons.Filled.Lan, contentDescription = "Lan", modifier = Modifier.size(18.dp))
        Spacer(modifier = Modifier.width(8.dp))
        Text("Scan LAN to add a target", fontSize = 12.sp)
    }

    if (showPicker) {
        LanHostPickerDialog(
            viewModel = viewModel,
            onDismiss = { showPicker = false },
            onPick = { ip ->
                val host = viewModel.hostScanResults.firstOrNull { it.ip == ip }
                onPick(
                    AppViewModel.ScannedWolDevice(
                        name = host?.hostname?.ifBlank { "LAN Device" } ?: "LAN Device",
                        mac = host?.mac ?: "",
                        ip = ip,
                        isOnline = host?.isOnline ?: true,
                    )
                )
                showPicker = false
            },
        )
    }
}

// 7.5 CREDENTIAL KEYCHAINS PANEL
@Composable
fun AuthKeysToolView(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val keysList by viewModel.keys.collectAsStateWithLifecycle()
    val profilesList by viewModel.profiles.collectAsStateWithLifecycle()
    var showCreateKey by remember { mutableStateOf(false) }
    var showCreateProfile by remember { mutableStateOf(false) }
    var showImportKeyDialog by remember { mutableStateOf(false) }
    var editProfile by remember { mutableStateOf<CredentialProfileEntity?>(null) }
    var editKey by remember { mutableStateOf<SshKeyEntity?>(null) }
    var authFeedback by remember { mutableStateOf("") }
    var authFeedbackOk by remember { mutableStateOf(true) }
    var showAuthOption by remember { mutableStateOf(false) }
    var generatedKeyResult by remember { mutableStateOf<Triple<String, String, String>?>(null) } // alias, priv, pub
    val context = LocalContext.current
    val clipboardScope = rememberCoroutineScope()

    // Refresh trusted host keys once when the screen opens. Kept at the composable's top level (not
    // inside the LazyColumn item that renders them) so it fires once, instead of re-firing every time
    // that row scrolls back into composition.
    LaunchedEffect(Unit) { viewModel.refreshKnownHosts() }

    // Play Store free tier allows a single saved credential (profiles + keys combined).
    val credentialLimitReached = viewModel.hasCredentialProfileLimit &&
        (profilesList.size + keysList.size) >= viewModel.credentialProfileLimit

    ToolScaffold(
        viewModel = viewModel,
        title = "Auth Keys & Profiles",
        onAdd = { showAuthOption = true },
        addEnabled = !credentialLimitReached
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxSize().padding(12.dp)) {

                if (credentialLimitReached) {
                    item {
                        Text(
                            viewModel.credentialProfileLimitMessage(),
                            color = OmniColors.amber,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                }

                if (authFeedback.isNotBlank()) {
                    item {
                        Text(
                            authFeedback,
                            color = if (authFeedbackOk) OmniColors.green else Color.Red,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(top = 8.dp)
                        )
                    }
                }
                item { Text("Credential Profiles (Username/Password)", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp)) }
                items(profilesList) { profile ->
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(16.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(profile.profileName, fontWeight = FontWeight.Bold)
                                Text("User: ${profile.username} · Auth: ${profile.authType}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Row {
                                IconButton(onClick = { editProfile = profile }) {
                                    Icon(Icons.Filled.Edit, "Edit profile", tint = OmniColors.cyan)
                                }
                                IconButton(onClick = {
                                    confirm.ask("Delete profile?", "Delete credential profile \"${profile.profileName}\"? Hosts using it will lose these credentials.", confirmLabel = "Delete") {
                                        viewModel.deleteProfile(profile)
                                    }
                                }) {
                                    Icon(Icons.Filled.Delete, null, tint = Color.Red)
                                }
                            }
                        }
                    }
                }

                item { Text("SSH Keys", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 16.dp)) }
                items(keysList) { key ->
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.purple) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(16.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(key.alias, fontWeight = FontWeight.Bold)
                                Text("Crypto: ${key.keyType} · Fingerprint: ${key.fingerprint}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Row {
                                IconButton(onClick = { editKey = key }) {
                                    Icon(Icons.Filled.Edit, "Edit key", tint = OmniColors.purple)
                                }
                                IconButton(onClick = {
                                    confirm.ask("Delete key?", "Delete SSH key \"${key.alias}\" from OmniTerm? Hosts relying on it will no longer authenticate.", confirmLabel = "Delete") {
                                        viewModel.deleteKey(key)
                                    }
                                }) {
                                    Icon(Icons.Filled.Delete, null, tint = Color.Red)
                                }
                            }
                        }
                    }
                }

                item {
                    val hosts = viewModel.knownHosts
                    Column {
                        SectionHeader("Trusted Host Keys", modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
                        if (hosts.isEmpty()) {
                            Text("No trusted host keys yet.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                        } else {
                            hosts.forEach { kh ->
                                OmniCard(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp), leftAccent = OmniColors.amber) {
                                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(kh.host, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                            Text("${kh.keyType} · ${kh.fingerprint}", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                                        }
                                        IconButton(onClick = {
                                            confirm.ask("Remove trusted key?", "Remove the trusted SSH host key for ${kh.host}? The next connection will prompt you to verify and pin the key again.", confirmLabel = "Remove") {
                                                viewModel.removeKnownHost(kh.host)
                                            }
                                        }) {
                                            Icon(Icons.Filled.Delete, "Remove trusted key", tint = Color.Red)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showAuthOption) {
        AlertDialog(
            onDismissRequest = { showAuthOption = false },
            title = { Text("Add Authentication Source") },
            text = {
                Column {
                    ListItem(
                        headlineContent = { Text("Profile (User/Pass)") },
                        modifier = Modifier.clickable { showAuthOption = false; showCreateProfile = true }
                    )
                    ListItem(
                        headlineContent = { Text("Generate SSH Key") },
                        modifier = Modifier.clickable { showAuthOption = false; showCreateKey = true }
                    )
                    ListItem(
                        headlineContent = { Text("Import SSH Key") },
                        modifier = Modifier.clickable { showAuthOption = false; showImportKeyDialog = true }
                    )
                }
            },
            confirmButton = { TextButton(onClick = { showAuthOption = false }) { Text("Cancel") } }
        )
    }

    if (showCreateProfile) {
        var pName by remember { mutableStateOf("") }
        var pUser by remember { mutableStateOf("") }
        var pPass by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showCreateProfile = false },
            title = { Text("Create Credential Profile") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = pName, onValueChange = { pName = it }, label = { Text("Profile Name") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = pUser, onValueChange = { pUser = it }, label = { Text("Username") }, modifier = Modifier.fillMaxWidth())
                    OmniPasswordField(value = pPass, onValueChange = { pPass = it }, label = "Password", modifier = Modifier.fillMaxWidth())
                }
            },
            confirmButton = {
                Button(
                    enabled = pName.isNotBlank() && pUser.isNotBlank() && pPass.isNotBlank(),
                    onClick = {
                    viewModel.addCredentialProfile(pName, pUser, "password", pPass, null) { ok, msg ->
                        authFeedbackOk = ok
                        authFeedback = msg
                        if (ok) showCreateProfile = false
                    }
                }) { Text("Save Profile") }
            },
            dismissButton = { TextButton(onClick = { showCreateProfile = false }) { Text("Cancel") } }
        )
    }

    if (showCreateKey) {
        var alias by remember { mutableStateOf("") }
        val keyType = "RSA"

        AlertDialog(
            onDismissRequest = { showCreateKey = false },
            title = { Text("Generate Cryptographic Keypair") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = alias, onValueChange = { alias = it }, label = { Text("Key Alias Name") }, modifier = Modifier.fillMaxWidth())
                    Text("OmniTerm will generate a real RSA 4096-bit SSH keypair and store the private key in the local key vault.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            confirmButton = {
                Button(
                    enabled = alias.isNotBlank(),
                    onClick = {
                        viewModel.generateSshKey(alias, keyType) { ok, msg, priv, pub ->
                            authFeedbackOk = ok
                            authFeedback = msg
                            if (ok && priv != null && pub != null) {
                                generatedKeyResult = Triple(alias, priv, pub)
                            }
                        }
                        showCreateKey = false
                    }
                ) {
                    Text("Generate Keys")
                }
            },
            dismissButton = {
                TextButton(onClick = { showCreateKey = false }) { Text("Cancel") }
            }
        )
    }

    if (showImportKeyDialog) {
        var importAlias by remember { mutableStateOf("") }
        var importedPrivateKey by remember { mutableStateOf("") }
        var importedPublicKey by remember { mutableStateOf("") }
        val context = LocalContext.current
        var pickTarget by remember { mutableStateOf("private") }
        val keyFileLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.OpenDocument()
        ) { uri ->
            if (uri != null) {
                try {
                    context.contentResolver.openInputStream(uri)?.use {
                        val text = it.reader().readText()
                        if (pickTarget == "public") importedPublicKey = text else importedPrivateKey = text
                    }
                } catch (e: Exception) {
                    android.util.Log.w("ToolsScreen", "Failed to read key file", e)
                    android.widget.Toast.makeText(context, "Could not read file: ${e.message}", android.widget.Toast.LENGTH_SHORT).show()
                }
            }
        }

        AlertDialog(
            onDismissRequest = { showImportKeyDialog = false },
            title = { Text("Import existing SSH Key") },
            text = {
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        "Only the private key is required — the type (RSA, OpenSSH, ed25519, ECDSA…) " +
                            "is detected automatically and the public key is derived from it. Add the " +
                            "public key only if you want to store it too.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(value = importAlias, onValueChange = { importAlias = it }, label = { Text("Key Custom Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())

                    Text("Private key (required)", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    OutlinedTextField(
                        value = importedPrivateKey,
                        onValueChange = { importedPrivateKey = it },
                        label = { Text("-----BEGIN ... PRIVATE KEY-----") },
                        modifier = Modifier.fillMaxWidth().height(130.dp),
                        maxLines = 6,
                    )
                    OutlinedButton(
                        onClick = { pickTarget = "private"; keyFileLauncher.launch(arrayOf("*/*")) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Folder, contentDescription = "Folder")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Load private key from file")
                    }

                    Text("Public key (optional)", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    OutlinedTextField(
                        value = importedPublicKey,
                        onValueChange = { importedPublicKey = it },
                        label = { Text("ssh-rsa AAAA… (leave blank to auto-derive)") },
                        modifier = Modifier.fillMaxWidth().height(90.dp),
                        maxLines = 3,
                    )
                    OutlinedButton(
                        onClick = { pickTarget = "public"; keyFileLauncher.launch(arrayOf("*/*")) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Folder, contentDescription = "Folder")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Load public key (.pub) from file")
                    }
                }
            },
            confirmButton = {
                Button(
                    enabled = importAlias.isNotBlank() && importedPrivateKey.isNotBlank(),
                    onClick = {
                        viewModel.addSshKey(importAlias, "", importedPrivateKey, importedPublicKey) { ok, msg ->
                            authFeedbackOk = ok
                            authFeedback = msg
                            if (ok) showImportKeyDialog = false
                        }
                    }
                ) {
                    Text("Save Key")
                }
            },
            dismissButton = {
                TextButton(onClick = { showImportKeyDialog = false }) { Text("Cancel") }
            }
        )
    }

    // Edit an existing credential profile (name / username / password).
    editProfile?.let { profile ->
        var pName by remember(profile.id) { mutableStateOf(profile.profileName) }
        var pUser by remember(profile.id) { mutableStateOf(profile.username) }
        var pPass by remember(profile.id) { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { editProfile = null },
            title = { Text("Edit Credential Profile") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = pName, onValueChange = { pName = it }, label = { Text("Profile Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = pUser, onValueChange = { pUser = it }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    if (profile.authType == "password") {
                        OmniPasswordField(
                            value = pPass,
                            onValueChange = { pPass = it },
                            label = "Password (leave blank to keep current)",
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        Text("Key profile — bound to key '${profile.keyAlias ?: "?"}'.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            },
            confirmButton = {
                Button(
                    enabled = pName.isNotBlank() && pUser.isNotBlank(),
                    onClick = {
                    viewModel.updateCredentialProfile(profile, pName, pUser, pPass) { ok, msg ->
                        authFeedbackOk = ok
                        authFeedback = msg
                        if (ok) editProfile = null
                    }
                }) { Text("Save Changes") }
            },
            dismissButton = { TextButton(onClick = { editProfile = null }) { Text("Cancel") } }
        )
    }

    // Edit an existing SSH key: rename and/or replace the key material.
    editKey?.let { key ->
        var alias by remember(key.id) { mutableStateOf(key.alias) }
        var newPrivate by remember(key.id) { mutableStateOf("") }
        var newPublic by remember(key.id) { mutableStateOf("") }
        val context = LocalContext.current
        var pickTarget by remember(key.id) { mutableStateOf("private") }
        val keyFileLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.OpenDocument()
        ) { uri ->
            if (uri != null) {
                try {
                    context.contentResolver.openInputStream(uri)?.use {
                        val text = it.reader().readText()
                        if (pickTarget == "public") newPublic = text else newPrivate = text
                    }
                } catch (e: Exception) {
                    android.util.Log.w("ToolsScreen", "Failed to read key file", e)
                    android.widget.Toast.makeText(context, "Could not read file: ${e.message}", android.widget.Toast.LENGTH_SHORT).show()
                }
            }
        }
        AlertDialog(
            onDismissRequest = { editKey = null },
            title = { Text("Edit SSH Key") },
            text = {
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                ) {
                    OutlinedTextField(value = alias, onValueChange = { alias = it }, label = { Text("Key Alias Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Text(
                        "Renaming updates every host and profile that uses this key. Leave the key " +
                            "fields blank to keep the current key pair; paste a new private key to replace it.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text("Replacement private key (optional)", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    OutlinedTextField(
                        value = newPrivate,
                        onValueChange = { newPrivate = it },
                        label = { Text("-----BEGIN ... PRIVATE KEY-----") },
                        modifier = Modifier.fillMaxWidth().height(120.dp),
                        maxLines = 6,
                    )
                    OutlinedButton(
                        onClick = { pickTarget = "private"; keyFileLauncher.launch(arrayOf("*/*")) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Folder, contentDescription = "Folder")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Load private key from file")
                    }
                    Text("Replacement public key (optional)", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    OutlinedTextField(
                        value = newPublic,
                        onValueChange = { newPublic = it },
                        label = { Text("ssh-… (leave blank to auto-derive)") },
                        modifier = Modifier.fillMaxWidth().height(80.dp),
                        maxLines = 3,
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = alias.isNotBlank(),
                    onClick = {
                        viewModel.updateSshKey(key, alias, newPrivate, newPublic) { ok, msg ->
                            authFeedbackOk = ok
                            authFeedback = msg
                            if (ok) editKey = null
                        }
                    }
                ) { Text("Save Changes") }
            },
            dismissButton = { TextButton(onClick = { editKey = null }) { Text("Cancel") } }
        )
    }

    generatedKeyResult?.let { (alias, priv, pub) ->
        val copyToClipboard = rememberClipboardCopy()
        AlertDialog(
            onDismissRequest = { generatedKeyResult = null },
            title = { Text("Generated Key: $alias") },
            text = {
                Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Warning: Private key is shown only once. Please copy it now if you need it.", color = Color.Red, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Text("Private Key", fontWeight = FontWeight.Bold)
                    OutlinedTextField(value = priv, onValueChange = {}, readOnly = true, modifier = Modifier.fillMaxWidth().height(150.dp), textStyle = androidx.compose.ui.text.TextStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, fontSize = 10.sp))
                    Button(onClick = { copySensitiveClipboard(context, clipboardScope, "OmniTerm private key", priv) }) { Text("Copy Private Key") }

                    Text("Public Key", fontWeight = FontWeight.Bold)
                    OutlinedTextField(value = pub, onValueChange = {}, readOnly = true, modifier = Modifier.fillMaxWidth().height(100.dp), textStyle = androidx.compose.ui.text.TextStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, fontSize = 10.sp))
                    Button(onClick = { copyToClipboard(pub) }) { Text("Copy Public Key") }

                    Text("Install on your server", fontWeight = FontWeight.Bold)
                    Text(
                        "The server only accepts this key after the PUBLIC key is added to " +
                            "~/.ssh/authorized_keys for the user you log in as. While password login " +
                            "still works, the easiest way is to run this in any terminal on this host:",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val installCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
                        "echo '${pub.trim()}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
                    OutlinedTextField(
                        value = installCmd,
                        onValueChange = {},
                        readOnly = true,
                        modifier = Modifier.fillMaxWidth().height(100.dp),
                        textStyle = androidx.compose.ui.text.TextStyle(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, fontSize = 10.sp),
                    )
                    Button(onClick = { copyToClipboard(installCmd) }) { Text("Copy Install Command") }
                    Text(
                        "From a computer with ssh installed you can instead run: ssh-copy-id user@host",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                Button(onClick = { generatedKeyResult = null }) { Text("Done") }
            }
        )
    }
}

// 7.6 CRON JOBS PANEL
@Composable
fun CronJobsToolView(viewModel: AppViewModel) {
    val srv = viewModel.selectedServer
    LaunchedEffect(viewModel.selectedServerId) { viewModel.loadCron() }
    ToolScaffold(viewModel, "Cron schedules · ${srv?.name ?: "—"}") {
        // Wrap in a scrollable Column so the host picker and the crontab card stack vertically
        // (ToolScaffold hands its content a bare Box, which would otherwise overlap them).
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
            // Let the user choose which host's crontab to inspect.
            ServerSelectorBar(viewModel, onServerChange = { viewModel.loadCron() })
            when {
                srv == null ->
                    Text("Select a server first.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                viewModel.cronLoading && viewModel.cronText.isEmpty() ->
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                else -> {
                    val lines = viewModel.cronText.lines().filter { it.isNotBlank() }
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
                        Column(modifier = Modifier.padding(12.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(srv.name, fontWeight = FontWeight.Bold)
                                Text("Reload", color = MaterialTheme.colorScheme.primary, fontSize = 12.sp, modifier = Modifier.clickable { viewModel.loadCron() })
                            }
                            Spacer(modifier = Modifier.height(6.dp))
                            if (lines.isEmpty()) {
                                Text("No crontab entries for ${srv.username}.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                            } else {
                                lines.forEach { cron ->
                                    Text(
                                        cron,
                                        fontFamily = OmniFonts.mono,
                                        fontSize = 12.sp,
                                        color = if (cron.startsWith("#")) Color.Gray else MaterialTheme.colorScheme.onSurface,
                                        modifier = Modifier.padding(vertical = 2.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// 7.7 BACKUPS SCHEDULERS PANEL
@Composable
fun BackupToolView(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    var exportFeedback by remember { mutableStateOf("") }
    var exportFeedbackOk by remember { mutableStateOf(true) }
    var showImportPasswordDialog by remember { mutableStateOf(false) }
    var showExportPasswordDialog by remember { mutableStateOf(false) }
    var showExportSelectionDialog by remember { mutableStateOf(false) }
    var showRestoreSelectionDialog by remember { mutableStateOf(false) }
    var pendingImportContent by remember { mutableStateOf("") }
    var pendingRestorePassword by remember { mutableStateOf("") }
    var pendingExportSelection by remember { mutableStateOf(BackupSelection()) }
    var restoreSelection by remember { mutableStateOf(BackupSelection()) }
    var restoreContents by remember { mutableStateOf<BackupContents?>(null) }
    var restoreHosts by remember { mutableStateOf<List<BackupHostOption>>(emptyList()) }
    var selectedRestoreHostIds by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var importPassword by remember { mutableStateOf("") }
    var exportPassword by remember { mutableStateOf("") }
    var pendingExportPassword by remember { mutableStateOf("") }
    val exportSelection = viewModel.backupExportSelection
    fun setExportSelection(selection: BackupSelection) {
        viewModel.updateBackupExportSelection(selection)
    }

    ToolScaffold(viewModel, "App Backup") {
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("OmniTerm app backup", fontWeight = FontWeight.Bold)
                    Text(
                        "Exports OmniTerm's own configuration — saved hosts, keys, scripts and settings. " +
                            "It does NOT back up any files or data on your servers.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "Last backup: ${if (viewModel.lastBackupExportTime <= 0L) "Never" else formatDateTime(viewModel.lastBackupExportTime)}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(modifier = Modifier.height(12.dp))

                    val context = LocalContext.current
                    val importBackupLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
                        androidx.activity.result.contract.ActivityResultContracts.OpenDocument()
                    ) { uri ->
                        if (uri != null) {
                            try {
                                context.contentResolver.openInputStream(uri)?.use {
                                    pendingImportContent = readBackupTextLimited(it)
                                    if (viewModel.backupNeedsPassword(pendingImportContent)) {
                                        showImportPasswordDialog = true
                                    } else {
                                        viewModel.inspectBackupContents(pendingImportContent, "") { ok, contents, msg ->
                                            if (ok && contents != null) {
                                                restoreContents = contents
                                                restoreSelection = backupSelectionFromContents(contents)
                                                viewModel.inspectBackupHosts(pendingImportContent, "") { hostsOk, hosts, hostsMsg ->
                                                    if (hostsOk) {
                                                        restoreHosts = hosts
                                                        selectedRestoreHostIds = hosts.map { it.oldId }.toSet()
                                                        showRestoreSelectionDialog = true
                                                    } else {
                                                        exportFeedbackOk = false
                                                        exportFeedback = hostsMsg
                                                    }
                                                }
                                            } else {
                                                exportFeedbackOk = false
                                                exportFeedback = msg
                                            }
                                        }
                                    }
                                }
                            } catch(e: Exception) {
                                exportFeedbackOk = false
                                exportFeedback = e.message ?: "Error reading backup file."
                            }
                        }
                    }

                    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
                        androidx.activity.result.contract.ActivityResultContracts.CreateDocument("application/json")
                    ) { uri ->
                        if (uri != null) {
                            viewModel.exportBackup(uri, pendingExportPassword, context, pendingExportSelection) { ok, msg ->
                                exportFeedbackOk = ok
                                exportFeedback = msg
                                pendingExportPassword = ""
                                pendingExportSelection = BackupSelection()
                            }
                        }
                    }

                    Text(
                        "Tap Backup to choose export sections. Restore shows available sections after the selected file is read.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(modifier = Modifier.height(12.dp))

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                pendingExportSelection = exportSelection
                                showExportSelectionDialog = true
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            Icon(Icons.Filled.CloudUpload, contentDescription = "Backup")
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Backup", fontSize = 12.sp)
                        }

                        Button(
                            onClick = {
                                importBackupLauncher.launch(arrayOf("application/json", "*/*"))
                            },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.secondary)
                        ) {
                            Icon(Icons.Filled.CloudDownload, contentDescription = "Restore Backup")
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Restore", fontSize = 12.sp)
                        }
                    }

                    if (exportFeedback.isNotEmpty()) {
                        Text(exportFeedback, color = if (exportFeedbackOk) Color(0xFF10B981) else Color.Red, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
                    }

                    if (showExportSelectionDialog) {
                        AlertDialog(
                            onDismissRequest = { showExportSelectionDialog = false },
                            title = { Text("Backup sections") },
                            text = {
                                Column(
                                    modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                                    verticalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    BackupSelectionList(
                                        title = "Choose what to include",
                                        selection = pendingExportSelection,
                                        contents = null,
                                        onChange = {
                                            pendingExportSelection = it
                                            setExportSelection(it)
                                        },
                                    )
                                    Text(
                                        if (pendingExportSelection.hasSensitiveData()) "Sensitive sections selected: backup will be encrypted." else "No sensitive sections selected: backup will be plain JSON.",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            },
                            confirmButton = {
                                TextButton(
                                    onClick = {
                                        showExportSelectionDialog = false
                                        if (pendingExportSelection.hasSensitiveData()) {
                                            showExportPasswordDialog = true
                                        } else {
                                            pendingExportPassword = ""
                                            launcher.launch("omniterm_backup_${System.currentTimeMillis() / 1000}.json")
                                        }
                                    }
                                ) { Text("Continue") }
                            },
                            dismissButton = {
                                TextButton(onClick = { showExportSelectionDialog = false }) { Text("Cancel") }
                            },
                        )
                    }

                    if (showExportPasswordDialog) {
                        AlertDialog(
                            onDismissRequest = { showExportPasswordDialog = false; exportPassword = "" },
                            title = { Text("Encrypt Backup") },
                            text = {
                                Column {
                                    Text("Sensitive backup sections require encryption. Choose a passphrase you'll need for restore.", fontSize = 12.sp)
                                    Spacer(modifier = Modifier.height(8.dp))
                                    OmniPasswordField(
                                        value = exportPassword,
                                        onValueChange = { exportPassword = it },
                                        label = "Passphrase (min 8 chars)",
                                    )
                                }
                            },
                            confirmButton = {
                                TextButton(
                                    enabled = exportPassword.length >= 8,
                                    onClick = {
                                        pendingExportPassword = exportPassword
                                        exportPassword = ""
                                        showExportPasswordDialog = false
                                        launcher.launch("omniterm_backup_${System.currentTimeMillis() / 1000}.json")
                                    }
                                ) { Text("Choose location") }
                            },
                            dismissButton = {
                                TextButton(onClick = { showExportPasswordDialog = false; exportPassword = "" }) { Text("Cancel") }
                            }
                        )
                    }
                }
            }

            if (showImportPasswordDialog) {
                AlertDialog(
                    onDismissRequest = { showImportPasswordDialog = false; pendingImportContent = ""; importPassword = ""; pendingRestorePassword = "" },
                    title = { Text("Encrypted Backup") },
                    text = {
                        Column {
                            Text("Enter the password to decrypt the backup.")
                            Spacer(modifier = Modifier.height(8.dp))
                            OmniPasswordField(
                                value = importPassword,
                                onValueChange = { importPassword = it },
                                label = "Password",
                            )
                        }
                    },
                    confirmButton = {
                        TextButton(
                            enabled = importPassword.isNotEmpty(),
                            onClick = {
                                val pwd = importPassword
                                showImportPasswordDialog = false
                                importPassword = ""
                                pendingRestorePassword = pwd
                                viewModel.inspectBackupContents(pendingImportContent, pwd) { ok, contents, msg ->
                                    if (ok && contents != null) {
                                        restoreContents = contents
                                        restoreSelection = backupSelectionFromContents(contents)
                                        viewModel.inspectBackupHosts(pendingImportContent, pwd) { hostsOk, hosts, hostsMsg ->
                                            if (hostsOk) {
                                                restoreHosts = hosts
                                                selectedRestoreHostIds = hosts.map { it.oldId }.toSet()
                                                showRestoreSelectionDialog = true
                                            } else {
                                                pendingImportContent = ""
                                                pendingRestorePassword = ""
                                                exportFeedbackOk = false
                                                exportFeedback = hostsMsg
                                            }
                                        }
                                    } else {
                                        pendingImportContent = ""
                                        pendingRestorePassword = ""
                                        exportFeedbackOk = false
                                        exportFeedback = msg
                                    }
                                }
                            }
                        ) {
                            Text("Restore")
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showImportPasswordDialog = false; pendingImportContent = ""; importPassword = ""; pendingRestorePassword = "" }) {
                            Text("Cancel")
                        }
                    }
                )
            }
            if (showRestoreSelectionDialog) {
                val contents = restoreContents
                AlertDialog(
                    onDismissRequest = {
                        showRestoreSelectionDialog = false
                        pendingImportContent = ""
                        pendingRestorePassword = ""
                        restoreContents = null
                        restoreHosts = emptyList()
                        selectedRestoreHostIds = emptySet()
                    },
                    title = { Text("Restore backup") },
                    text = {
                        Column(
                            modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text("Choose what to restore from this backup.", fontSize = 12.sp)
                            if (contents != null) {
                                BackupSelectionList(
                                    title = "Available sections",
                                    selection = restoreSelection,
                                    contents = contents,
                                    onChange = { restoreSelection = it },
                                )
                                if (restoreHosts.isNotEmpty() && restoreSelection.servers) {
                                    HorizontalDivider()
                                    BackupHostSelectionList(
                                        hosts = restoreHosts,
                                        selectedIds = selectedRestoreHostIds,
                                        onChange = { selectedRestoreHostIds = it },
                                        maxSelected = if (viewModel.hasHostLimit) viewModel.hostLimit else Int.MAX_VALUE,
                                    )
                                }
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                val content = pendingImportContent
                                val pwd = pendingRestorePassword
                                val selection = restoreSelection
                                val selectedHostIds = if (selection.servers) selectedRestoreHostIds else emptySet()
                                showRestoreSelectionDialog = false
                                pendingImportContent = ""
                                pendingRestorePassword = ""
                                restoreContents = null
                                restoreHosts = emptyList()
                                selectedRestoreHostIds = emptySet()
                                confirm.ask(
                                    "Restore selected data?",
                                    "Restoring selected sections will add matching backup contents into OmniTerm. This cannot be undone.",
                                    confirmLabel = "Restore",
                                ) {
                                    viewModel.restoreEncryptedBackup(content, pwd, selection, selectedHostIds) { ok, msg ->
                                        exportFeedbackOk = ok
                                        exportFeedback = msg
                                    }
                                }
                            }
                        ) { Text("Restore") }
                    },
                    dismissButton = {
                        TextButton(
                            onClick = {
                                showRestoreSelectionDialog = false
                                pendingImportContent = ""
                                pendingRestorePassword = ""
                                restoreContents = null
                                restoreHosts = emptyList()
                                selectedRestoreHostIds = emptySet()
                            }
                        ) { Text("Cancel") }
                    }
                )
            }
        }
    }
}

private fun backupSelectionFromContents(contents: BackupContents): BackupSelection {
    val hasServers = contents.servers > 0
    val hasAlertRules = contents.alertRules > 0
    return BackupSelection(
        servers = hasServers,
        sshKeys = contents.sshKeys > 0,
        credentialProfiles = contents.credentialProfiles > 0,
        scripts = contents.scripts > 0,
        alertRules = contents.alertRules > 0,
        activeAlerts = contents.activeAlerts > 0 && hasServers && hasAlertRules,
        alertHistory = contents.alertHistory > 0,
        wolTargets = contents.wolTargets > 0,
        networkShares = contents.networkShares > 0,
        portForwards = contents.portForwards > 0 && hasServers,
        settings = contents.settings > 0,
    ).withReferentialClosure()
}

@Composable
private fun BackupSelectionList(
    title: String,
    selection: BackupSelection,
    contents: BackupContents?,
    onChange: (BackupSelection) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        // A trailing "*" marks a section as sensitive: selecting it forces the backup to be encrypted
        // (see hasSensitiveData). Every section except Active alerts can carry secrets — hostnames,
        // keys, credentials, paths, command fragments — so they're all starred. The legend below
        // explains the marker once instead of repeating "(sensitive)" on every row.
        BackupSelectionRow("Servers *", contents?.servers, selection.servers, { onChange(selection.withServersSelected(it)) }, contents == null || contents.servers > 0)
        BackupSelectionRow("SSH keys *", contents?.sshKeys, selection.sshKeys, { onChange(selection.copy(sshKeys = it)) }, contents == null || contents.sshKeys > 0)
        BackupSelectionRow("Credential profiles *", contents?.credentialProfiles, selection.credentialProfiles, { onChange(selection.copy(credentialProfiles = it)) }, contents == null || contents.credentialProfiles > 0)
        BackupSelectionRow("Scripts *", contents?.scripts, selection.scripts, { onChange(selection.copy(scripts = it)) }, contents == null || contents.scripts > 0)
        BackupSelectionRow("Alert rules *", contents?.alertRules, selection.alertRules, { onChange(selection.withAlertRulesSelected(it)) }, contents == null || contents.alertRules > 0)
        BackupSelectionRow("Active alerts", contents?.activeAlerts, selection.activeAlerts, { onChange(selection.withActiveAlertsSelected(it)) }, contents == null || (contents.activeAlerts > 0 && contents.alertRules > 0 && contents.servers > 0))
        BackupSelectionRow("Alert history *", contents?.alertHistory, selection.alertHistory, { onChange(selection.withAlertHistorySelected(it)) }, contents == null || contents.alertHistory > 0)
        BackupSelectionRow("Wake on LAN *", contents?.wolTargets, selection.wolTargets, { onChange(selection.copy(wolTargets = it)) }, contents == null || contents.wolTargets > 0)
        BackupSelectionRow("Network shares *", contents?.networkShares, selection.networkShares, { onChange(selection.copy(networkShares = it)) }, contents == null || contents.networkShares > 0)
        BackupSelectionRow("SSH tunnels *", contents?.portForwards, selection.portForwards, { onChange(selection.withPortForwardsSelected(it)) }, contents == null || (contents.portForwards > 0 && contents.servers > 0))
        BackupSelectionRow("Settings & customizations *", contents?.settings, selection.settings, { onChange(selection.copy(settings = it)) }, contents == null || contents.settings > 0)
        BackupSelectionRow("Crash logs *", contents?.crashLogs, selection.crashLogs, { onChange(selection.copy(crashLogs = it)) }, contents == null || contents.crashLogs > 0)
        Text(
            "* Sensitive — selecting forces an encrypted backup.",
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp),
        )
        Text(
            "Alert rules and history include Servers. Active alerts also include Alert rules. SSH tunnels include Servers.",
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun BackupSelectionRow(
    label: String,
    count: Int?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean,
) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Checkbox(checked = checked && enabled, onCheckedChange = onCheckedChange, enabled = enabled)
        Text(
            if (count == null) label else "$label ($count)",
            fontSize = 12.sp,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun BackupHostSelectionList(
    hosts: List<BackupHostOption>,
    selectedIds: Set<Int>,
    onChange: (Set<Int>) -> Unit,
    maxSelected: Int,
) {
    val effectiveMax = maxSelected.coerceAtLeast(1)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Hosts to restore", fontWeight = FontWeight.Bold, fontSize = 12.sp)
        if (maxSelected != Int.MAX_VALUE) {
            Text(
                "Free Play Store restore is limited to $effectiveMax host${if (effectiveMax == 1) "" else "s"}.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        hosts.forEach { host ->
            val checked = host.oldId in selectedIds
            val canAdd = checked || selectedIds.size < effectiveMax
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = checked,
                    enabled = canAdd,
                    onCheckedChange = { next ->
                        onChange(
                            if (next) {
                                if (selectedIds.size < effectiveMax) selectedIds + host.oldId else selectedIds
                            } else {
                                selectedIds - host.oldId
                            }
                        )
                    },
                )
                Column(Modifier.weight(1f)) {
                    Text(host.name, fontSize = 12.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${host.host}:${host.port}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
fun SettingsToolView(viewModel: AppViewModel) {
    var pinSetupInput by remember { mutableStateOf("") }
    var showPinDialog by remember { mutableStateOf(false) }
    var showSaveAuth by remember { mutableStateOf(false) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    // Staged drafts for all settings; applied to the ViewModel only on Save.
    var draftDark by rememberSaveable { mutableStateOf(viewModel.isDarkModeEnabled) }
    var draftAmoled by rememberSaveable { mutableStateOf(viewModel.isAmoledEnabled) }
    var draftHighlightLimit by rememberSaveable { mutableStateOf(viewModel.editorHighlightLimit) }
    var draftAccessibility by rememberSaveable { mutableStateOf(viewModel.isAccessibilityEnabled) }
    var draftTextScale by rememberSaveable { mutableStateOf(viewModel.textScale) }
    var draftIntervalSec by rememberSaveable { mutableStateOf((viewModel.telemetryIntervalMs / 1000).toInt()) }
    var draftKeepOn by rememberSaveable { mutableStateOf(viewModel.defaultKeepScreenOn) }
    var draftBgKeepAlive by rememberSaveable { mutableStateOf(viewModel.isBackgroundKeepAlive) }
    var draftBatterySaver by rememberSaveable { mutableStateOf(viewModel.batterySaverEnabled) }
    var draftBatterySaverPct by rememberSaveable { mutableStateOf(viewModel.batterySaverThresholdPct) }
    var draftRetention by rememberSaveable { mutableStateOf(viewModel.metricsRetentionDays) }
    var draftAlertHistoryLimit by rememberSaveable { mutableStateOf(viewModel.alertHistoryLimit) }
    var draftTerminalFontSize by rememberSaveable { mutableStateOf(viewModel.terminalFontSize) }
    var draftTerminalTheme by rememberSaveable { mutableStateOf(viewModel.terminalTheme) }
    var draftTerminalScrollbackLimit by rememberSaveable { mutableStateOf(viewModel.terminalScrollbackLimit) }
    var draftSmartSwipe by rememberSaveable { mutableStateOf(viewModel.smartSwipeInput) }
    var draftLinkDetection by rememberSaveable { mutableStateOf(viewModel.terminalLinkDetection) }
    var draftLinkInApp by rememberSaveable { mutableStateOf(viewModel.linkOpenInApp) }
    var draftTmuxControl by rememberSaveable { mutableStateOf(viewModel.tmuxControlMode) }
    var draftAppLock by rememberSaveable { mutableStateOf(viewModel.isAppLockEnabled) }
    var draftAppLockGrace by rememberSaveable { mutableStateOf(viewModel.appLockGraceMs) }
    var draftBiometrics by rememberSaveable { mutableStateOf(viewModel.useBiometrics) }
    var draftBlockScreenshots by rememberSaveable { mutableStateOf(viewModel.isFlagSecureEnabled) }
    var draftSftpWarnFileCount by rememberSaveable { mutableStateOf(viewModel.sftpLargeBatchFileThreshold.toString()) }
    var draftSftpWarnGb by rememberSaveable { mutableStateOf((viewModel.sftpLargeBatchBytesThreshold / 1_000_000_000L).coerceAtLeast(1L).toString()) }
    val draftSftpWarnFileCountValue = draftSftpWarnFileCount.toIntOrNull()?.coerceIn(1, 10_000)
    val currentSftpWarnGb = (viewModel.sftpLargeBatchBytesThreshold / 1_000_000_000L).coerceAtLeast(1L)
    val draftSftpWarnGbValue = draftSftpWarnGb.toLongOrNull()?.coerceAtLeast(1L)

    val dirty = draftDark != viewModel.isDarkModeEnabled ||
        draftAmoled != viewModel.isAmoledEnabled ||
        draftHighlightLimit != viewModel.editorHighlightLimit ||
        draftAccessibility != viewModel.isAccessibilityEnabled ||
        draftTextScale != viewModel.textScale ||
        draftIntervalSec != (viewModel.telemetryIntervalMs / 1000).toInt() ||
        draftKeepOn != viewModel.defaultKeepScreenOn ||
        draftBgKeepAlive != viewModel.isBackgroundKeepAlive ||
        draftBatterySaver != viewModel.batterySaverEnabled ||
        draftBatterySaverPct != viewModel.batterySaverThresholdPct ||
        draftRetention != viewModel.metricsRetentionDays ||
        draftAlertHistoryLimit != viewModel.alertHistoryLimit ||
        draftTerminalFontSize != viewModel.terminalFontSize ||
        draftTerminalTheme != viewModel.terminalTheme ||
        draftTerminalScrollbackLimit != viewModel.terminalScrollbackLimit ||
        draftSmartSwipe != viewModel.smartSwipeInput ||
        draftLinkDetection != viewModel.terminalLinkDetection ||
        draftLinkInApp != viewModel.linkOpenInApp ||
        draftTmuxControl != viewModel.tmuxControlMode ||
        draftAppLock != viewModel.isAppLockEnabled ||
        draftAppLockGrace != viewModel.appLockGraceMs ||
        draftBiometrics != viewModel.useBiometrics ||
        draftBlockScreenshots != viewModel.isFlagSecureEnabled ||
        draftSftpWarnFileCountValue == null ||
        draftSftpWarnFileCountValue != viewModel.sftpLargeBatchFileThreshold ||
        draftSftpWarnGbValue == null ||
        draftSftpWarnGbValue != currentSftpWarnGb

    // Mirror dirty state to the ViewModel so navigation can guard against unsaved changes.
    LaunchedEffect(dirty) { viewModel.settingsDirty = dirty }

    fun resetDrafts() {
        draftDark = viewModel.isDarkModeEnabled
        draftAmoled = viewModel.isAmoledEnabled
        draftHighlightLimit = viewModel.editorHighlightLimit
        draftAccessibility = viewModel.isAccessibilityEnabled
        draftTextScale = viewModel.textScale
        draftIntervalSec = (viewModel.telemetryIntervalMs / 1000).toInt()
        draftKeepOn = viewModel.defaultKeepScreenOn
        draftBgKeepAlive = viewModel.isBackgroundKeepAlive
        draftBatterySaver = viewModel.batterySaverEnabled
        draftBatterySaverPct = viewModel.batterySaverThresholdPct
        draftRetention = viewModel.metricsRetentionDays
        draftAlertHistoryLimit = viewModel.alertHistoryLimit
        draftTerminalFontSize = viewModel.terminalFontSize
        draftTerminalTheme = viewModel.terminalTheme
        draftTerminalScrollbackLimit = viewModel.terminalScrollbackLimit
        draftSmartSwipe = viewModel.smartSwipeInput
        draftLinkDetection = viewModel.terminalLinkDetection
        draftLinkInApp = viewModel.linkOpenInApp
        draftTmuxControl = viewModel.tmuxControlMode
        draftAppLock = viewModel.isAppLockEnabled
        draftAppLockGrace = viewModel.appLockGraceMs
        draftBiometrics = viewModel.useBiometrics
        draftBlockScreenshots = viewModel.isFlagSecureEnabled
        draftSftpWarnFileCount = viewModel.sftpLargeBatchFileThreshold.toString()
        draftSftpWarnGb = (viewModel.sftpLargeBatchBytesThreshold / 1_000_000_000L).coerceAtLeast(1L).toString()
    }

    fun applyDrafts() {
        if (draftDark != viewModel.isDarkModeEnabled) viewModel.saveDarkModeToggle(draftDark)
        if (draftAmoled != viewModel.isAmoledEnabled) viewModel.saveAmoledToggle(draftAmoled)
        if (draftHighlightLimit != viewModel.editorHighlightLimit) viewModel.saveEditorHighlightLimit(draftHighlightLimit)
        if (draftAccessibility != viewModel.isAccessibilityEnabled) viewModel.saveAccessibilityToggle(draftAccessibility)
        if (draftTextScale != viewModel.textScale) viewModel.saveTextScale(draftTextScale)
        if (draftIntervalSec != (viewModel.telemetryIntervalMs / 1000).toInt()) viewModel.saveTelemetryInterval(draftIntervalSec)
        if (draftKeepOn != viewModel.defaultKeepScreenOn) viewModel.saveKeepScreenOnToggle(draftKeepOn)
        if (draftBgKeepAlive != viewModel.isBackgroundKeepAlive) viewModel.saveBackgroundKeepAliveToggle(draftBgKeepAlive)
        if (draftBatterySaver != viewModel.batterySaverEnabled) viewModel.saveBatterySaverEnabled(draftBatterySaver)
        if (draftBatterySaverPct != viewModel.batterySaverThresholdPct) viewModel.saveBatterySaverThreshold(draftBatterySaverPct)
        if (draftRetention != viewModel.metricsRetentionDays) viewModel.saveRetentionSetting(draftRetention)
        if (draftAlertHistoryLimit != viewModel.alertHistoryLimit) viewModel.saveAlertHistoryLimit(draftAlertHistoryLimit)
        if (draftTerminalFontSize != viewModel.terminalFontSize) viewModel.saveTerminalFontSize(draftTerminalFontSize)
        if (draftTerminalTheme != viewModel.terminalTheme) viewModel.saveTerminalTheme(draftTerminalTheme)
        if (draftTerminalScrollbackLimit != viewModel.terminalScrollbackLimit) viewModel.saveTerminalScrollbackLimit(draftTerminalScrollbackLimit)
        if (draftSmartSwipe != viewModel.smartSwipeInput) viewModel.saveSmartSwipeInput(draftSmartSwipe)
        if (draftLinkDetection != viewModel.terminalLinkDetection) viewModel.saveTerminalLinkDetection(draftLinkDetection)
        if (draftLinkInApp != viewModel.linkOpenInApp) viewModel.saveLinkOpenInApp(draftLinkInApp)
        if (draftTmuxControl != viewModel.tmuxControlMode) viewModel.saveTmuxControlMode(draftTmuxControl)
        val nextSftpWarnCount = draftSftpWarnFileCountValue ?: viewModel.sftpLargeBatchFileThreshold
        val nextSftpWarnBytes = (draftSftpWarnGbValue ?: currentSftpWarnGb) * 1_000_000_000L
        if (nextSftpWarnCount != viewModel.sftpLargeBatchFileThreshold || nextSftpWarnBytes != viewModel.sftpLargeBatchBytesThreshold) {
            viewModel.saveSftpLargeBatchThresholds(nextSftpWarnCount, nextSftpWarnBytes)
            draftSftpWarnFileCount = nextSftpWarnCount.toString()
            draftSftpWarnGb = (nextSftpWarnBytes / 1_000_000_000L).toString()
        }
        if (!draftAppLock) draftBiometrics = false
        if (draftAppLock != viewModel.isAppLockEnabled) {
            if (draftAppLock) viewModel.saveAppLockToggle(true)
            else viewModel.removeSecurityPin()
        }
        if (draftAppLock && draftBiometrics != viewModel.useBiometrics) viewModel.saveBiometricsToggle(draftBiometrics)
        if (draftAppLockGrace != viewModel.appLockGraceMs) viewModel.saveAppLockGrace(draftAppLockGrace)
        if (draftBlockScreenshots != viewModel.isFlagSecureEnabled) viewModel.saveFlagSecureToggle(draftBlockScreenshots)
    }

    ToolScaffold(viewModel, "App settings") {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
            Column(
                modifier = Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Security lock card applies immediately (it is the auth setup itself, not a draft).
                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        SettingsCardHeader("Security gate app lock", "Require a PIN each time OmniTerm opens.", OmniColors.cyan)

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Require PIN to unlock")
                            Switch(
                                checked = draftAppLock,
                                onCheckedChange = { on ->
                                    if (on) {
                                        if (viewModel.savedPin == null) showPinDialog = true
                                        else draftAppLock = true
                                    } else {
                                        draftAppLock = false
                                        draftBiometrics = false
                                    }
                                }
                            )
                        }

                        if (draftAppLock) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Unlock with biometrics")
                                val activity = LocalContext.current.getActivity()
                                Switch(
                                    checked = draftBiometrics,
                                    onCheckedChange = { on ->
                                        if (on && activity != null) {
                                            BiometricCryptoGate.authenticate(
                                                activity = activity,
                                                title = "Verify Biometrics",
                                                subtitle = "Authenticate to enable biometric unlock",
                                                onAuthenticated = { draftBiometrics = true },
                                            )
                                        } else {
                                            draftBiometrics = false
                                        }
                                    }
                                )
                            }
                            TextButton(onClick = { showPinDialog = true }) { Text("Change PIN") }

                            Spacer(Modifier.height(8.dp))
                            Text("Re-lock after leaving the app", fontSize = 13.sp)
                            Text(
                                "Quick app switches within this window won't ask for the PIN again. " +
                                    "A full restart of the app always locks.",
                                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Spacer(Modifier.height(6.dp))
                            val graceChoices = listOf(
                                "Immediately" to 0L,
                                "30s" to 30_000L,
                                "1 min" to 60_000L,
                                "5 min" to 300_000L,
                            )
                            @OptIn(ExperimentalLayoutApi::class)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                graceChoices.forEach { (label, ms) ->
                                    FilterChip(
                                        selected = draftAppLockGrace == ms,
                                        onClick = { draftAppLockGrace = ms },
                                        label = { Text(label, fontSize = 12.sp) },
                                    )
                                }
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text("Block screenshots")
                                Text(
                                    "Hides terminals and credentials from screenshots and the app switcher.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = draftBlockScreenshots,
                                onCheckedChange = { draftBlockScreenshots = it }
                            )
                        }
                    }
                }

                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        SettingsCardHeader("Display Behavior", "App appearance, refresh cadence, and screen power.", OmniColors.green)

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Keep device screen always on")
                            Switch(checked = draftKeepOn, onCheckedChange = { draftKeepOn = it })
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Low-battery saver")
                                Text(
                                    "Below the threshold (unplugged): turn off keep-screen-on, pause " +
                                        "auto-refresh, and park tmux terminals resumably. Resumes on " +
                                        "charge, recovery, or pull-to-refresh.",
                                    fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(checked = draftBatterySaver, onCheckedChange = { draftBatterySaver = it })
                        }
                        if (draftBatterySaver) {
                            Spacer(modifier = Modifier.height(6.dp))
                            Text("Engage below: $draftBatterySaverPct%", fontSize = 12.sp)
                            @OptIn(ExperimentalLayoutApi::class)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf(10, 15, 20, 30).forEach { pct ->
                                    FilterChip(
                                        selected = draftBatterySaverPct == pct,
                                        onClick = { draftBatterySaverPct = pct },
                                        label = { Text("$pct%", fontSize = 12.sp) },
                                    )
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))

                        // Auto-refresh cadence for metrics (Servers/Fleet/Monitor) and the countdown rings.
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text("Auto-refresh interval")
                                Text("How often host metrics refresh", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            var intervalExpanded by remember { mutableStateOf(false) }
                            Box {
                                TextButton(onClick = { intervalExpanded = true }) { Text("${draftIntervalSec}s") }
                                DropdownMenu(expanded = intervalExpanded, onDismissRequest = { intervalExpanded = false }) {
                                    listOf(5, 10, 15, 30, 60, 120).forEach { secs ->
                                        DropdownMenuItem(
                                            text = { Text("${secs}s") },
                                            onClick = { draftIntervalSec = secs; intervalExpanded = false },
                                        )
                                    }
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text("Theme App Appearance")
                                Text("Use system or override", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }

                            var expanded by remember { mutableStateOf(false) }
                            Box {
                                TextButton(onClick = { expanded = true }) {
                                    Text(when (draftDark) { true -> "Dark"; false -> "Light"; null -> "System" })
                                }
                                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                                    DropdownMenuItem(text = { Text("System Default") }, onClick = { draftDark = null; expanded = false })
                                    DropdownMenuItem(text = { Text("Dark Theme") }, onClick = { draftDark = true; expanded = false })
                                    DropdownMenuItem(text = { Text("Light Theme") }, onClick = { draftDark = false; expanded = false })
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("AMOLED black")
                                Text(
                                    "Pure-black surfaces in dark mode to save power on OLED screens. No effect in Light or High-contrast mode.",
                                    fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            // Only meaningful when dark mode can be active (System or Dark, not forced Light).
                            Switch(
                                checked = draftAmoled,
                                onCheckedChange = { draftAmoled = it },
                                enabled = draftDark != false,
                            )
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Text("Editor syntax highlighting", fontWeight = FontWeight.Bold)
                        Text(
                            "Max file size to colourise in the code editor (SFTP files, Compose YAML). " +
                                "Lower it if editing large files feels slow; \"Off\" disables highlighting.",
                            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(modifier = Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            // 0 = off; the largest option is the enforced cap (users can only lower it).
                            listOf(0 to "Off", 50_000 to "50 KB", 100_000 to "100 KB", HIGHLIGHT_MAX_CHARS_CAP to "Max").forEach { (value, label) ->
                                FilterChip(
                                    selected = draftHighlightLimit == value,
                                    onClick = { draftHighlightLimit = value },
                                    label = { Text(label) },
                                )
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("High-contrast mode")
                                Text(
                                    "Stronger colors and borders for better readability. Applies on top of your Dark/Light theme.",
                                    fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(checked = draftAccessibility, onCheckedChange = { draftAccessibility = it })
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Text("Text size", fontWeight = FontWeight.Bold)
                        Text("Scales text across all screens.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(modifier = Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf("small" to "Small", "normal" to "Default", "large" to "Large").forEach { (key, label) ->
                                FilterChip(
                                    selected = draftTextScale == key,
                                    onClick = { draftTextScale = key },
                                    label = { Text(label) }
                                )
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Keep sessions alive in background")
                                Text("Maintain active SSH/SFTP sessions when app is minimized", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Switch(checked = draftBgKeepAlive, onCheckedChange = { draftBgKeepAlive = it })
                        }
                    }
                }

                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        SettingsCardHeader("Metrics Data Pruning", "Pruning metric history logs prevents database overflow.", OmniColors.amber)
                        Text("Retention Window: $draftRetention days")
                        Slider(
                            value = draftRetention.toFloat(),
                            onValueChange = { draftRetention = it.toInt() },
                            valueRange = 1f..30f,
                            steps = 28,
                        )
                    }
                }

                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.purple) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SettingsCardHeader("Terminal", "Persistent terminal display preferences.", OmniColors.purple)
                        Text("Font size: ${draftTerminalFontSize}sp", fontSize = 12.sp)
                        Slider(
                            value = draftTerminalFontSize.toFloat(),
                            onValueChange = { draftTerminalFontSize = it.toInt() },
                            valueRange = 8f..28f,
                            steps = 19,
                        )
                        Text("Theme", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        @OptIn(ExperimentalLayoutApi::class)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                            listOf(
                                "system" to "App theme",
                                "omni_dark" to "Omni Dark",
                                "solarized_dark" to "Solarized",
                                "matrix" to "Matrix",
                                "light" to "Light",
                            ).forEach { (key, label) ->
                                FilterChip(
                                    selected = draftTerminalTheme == key,
                                    onClick = { draftTerminalTheme = key },
                                    label = { Text(label, fontSize = 11.sp, maxLines = 1) },
                                )
                            }
                        }
                        Text("Scrollback: ${draftTerminalScrollbackLimit / 1000}k lines", fontSize = 12.sp)
                        Slider(
                            value = draftTerminalScrollbackLimit.toFloat(),
                            onValueChange = { draftTerminalScrollbackLimit = it.toInt() },
                            valueRange = 1_000f..50_000f,
                            steps = 48,
                        )
                        Text(
                            "Applies to new terminal sessions. Existing sessions keep their current buffer.",
                            fontSize = 10.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(8.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                                Text("Smart swipe input")
                                Text(
                                    "Lets gesture keyboards correct each swiped word before it's sent. " +
                                        "Turn off to disable swipe-typing and accept strict, literal " +
                                        "keystrokes like a password field (no autocorrect or suggestions).",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(checked = draftSmartSwipe, onCheckedChange = { draftSmartSwipe = it })
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                                Text("tmux control mode (experimental)")
                                Text(
                                    "Persistent sessions attach with tmux's control protocol " +
                                        "(what iTerm2 uses): every output byte is streamed, so " +
                                        "scroll history is always complete — nothing is skipped " +
                                        "while you're not watching. Split panes made inside tmux " +
                                        "aren't rendered. Applies to newly opened sessions.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(checked = draftTmuxControl, onCheckedChange = { draftTmuxControl = it })
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                                Text("Tap-to-open links")
                                Text(
                                    "Detect URLs in terminal output (including lines wrapped across " +
                                        "rows) and open them on tap. Best-effort pattern matching — " +
                                        "turn off if taps misfire on unusual output.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(checked = draftLinkDetection, onCheckedChange = { draftLinkDetection = it })
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                                Text("Open links in-app")
                                Text(
                                    "Tapped links open in an in-app browser tab (back returns " +
                                        "straight to the terminal). Turn off to hand links to your " +
                                        "external browser app instead.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = draftLinkInApp,
                                onCheckedChange = { draftLinkInApp = it },
                                enabled = draftLinkDetection,
                            )
                        }
                    }
                }

                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.red) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        SettingsCardHeader("Alert History", "Keep the newest acknowledged, muted, and resolved incidents per host.", OmniColors.red)
                        Text("History entries per host: $draftAlertHistoryLimit")
                        Slider(
                            value = draftAlertHistoryLimit.toFloat(),
                            onValueChange = { draftAlertHistoryLimit = it.toInt() },
                            valueRange = 10f..100f,
                            steps = 8,
                        )
                    }
                }

                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SettingsCardHeader("SFTP Transfer Warnings", "Warn before large multi-file uploads or downloads.", OmniColors.cyan)
                        OutlinedTextField(
                            value = draftSftpWarnFileCount,
                            onValueChange = { draftSftpWarnFileCount = it.filter(Char::isDigit).take(5) },
                            label = { Text("Warn at file count") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = draftSftpWarnGb,
                            onValueChange = { draftSftpWarnGb = it.filter(Char::isDigit).take(4) },
                            label = { Text("Warn at total download size (GB)") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            // Sticky Save / Cancel bar — always visible; disabled when there are no changes.
            HorizontalDivider()
            Row(
                modifier = Modifier.fillMaxWidth().padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(
                    onClick = { resetDrafts() },
                    enabled = dirty,
                    modifier = Modifier.weight(1f),
                ) { Text("Cancel") }
                Button(
                    onClick = { if (viewModel.savedPin == null) applyDrafts() else showSaveAuth = true },
                    enabled = dirty,
                    modifier = Modifier.weight(1f),
                ) { Text("Save changes") }
            }
        }
    }

    if (showPinDialog) {
        AlertDialog(
            onDismissRequest = { showPinDialog = false },
            title = { Text("Configure Security PIN") },
            text = {
                OutlinedTextField(
                    value = pinSetupInput,
                    onValueChange = { pinSetupInput = it },
                    label = { Text("PIN (4-8 digits)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (pinSetupInput.length in 4..8) {
                            viewModel.savePinConfiguration(pinSetupInput)
                            draftAppLock = true  // prevent applyDrafts from calling removeSecurityPin()
                            draftBiometrics = false
                            pinSetupInput = ""
                            showPinDialog = false
                        }
                    }
                ) {
                    Text("Save PIN")
                }
            },
            dismissButton = {
                TextButton(onClick = { showPinDialog = false }) { Text("Cancel") }
            }
        )
    }

    if (showSaveAuth) {
        SettingsSaveAuthDialog(
            viewModel = viewModel,
            onCancel = { showSaveAuth = false },
            onAuthenticated = { showSaveAuth = false; applyDrafts() },
        )
    }

    // Discard-changes prompt raised by the navigation guard when leaving with unsaved edits.
    if (viewModel.showSettingsDiscardDialog) {
        AlertDialog(
            onDismissRequest = { viewModel.cancelSettingsDiscard() },
            title = { Text("Discard changes?") },
            text = { Text("You have unsaved settings changes. Leave without saving them?") },
            confirmButton = {
                TextButton(onClick = { resetDrafts(); viewModel.discardSettingsAndLeave() }) {
                    Text("Discard", color = OmniColors.red)
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.cancelSettingsDiscard() }) { Text("Keep editing") }
            },
        )
    }
}



private fun readBackupTextLimited(input: InputStream, maxChars: Int = 10 * 1024 * 1024): String {
    input.reader(Charsets.UTF_8).use { reader ->
        val out = StringBuilder()
        val buffer = CharArray(8192)
        while (true) {
            val read = reader.read(buffer)
            if (read < 0) return out.toString()
            if (out.length + read > maxChars) {
                throw IllegalArgumentException("Backup file is too large to import safely.")
            }
            out.append(buffer, 0, read)
        }
    }
}

/** PIN/biometric confirmation before applying staged settings (shown only when app lock is on). */
@Composable
private fun SettingsSaveAuthDialog(
    viewModel: AppViewModel,
    onCancel: () -> Unit,
    onAuthenticated: () -> Unit,
) {
    val context = LocalContext.current
    var pin by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    // If biometrics is the chosen unlock method, present the system prompt immediately.
    LaunchedEffect(Unit) {
        if (viewModel.useBiometrics) {
            context.getActivity()?.let { activity ->
                BiometricCryptoGate.authenticate(
                    activity = activity,
                    title = "Authenticate to save settings",
                    subtitle = "Confirm it's you",
                    onAuthenticated = onAuthenticated,
                )
            }
        }
    }

    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Authenticate to save") },
        text = {
            Column {
                Text("Enter your app PIN to apply these changes.", fontSize = 14.sp)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = pin,
                    onValueChange = { pin = it; error = null },
                    label = { Text("PIN") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = Color.Red, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val err = viewModel.verifyPinForSensitiveAction(pin)
                if (err == null) onAuthenticated() else error = err
            }) { Text("Confirm") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

// 7.9 ABOUT DEVELOPER INFO PANEL
@Composable
fun AboutToolView(viewModel: AppViewModel) {
    var linkFeedback by remember { mutableStateOf("") }
    var diagFeedback by remember { mutableStateOf("") }
    val context = LocalContext.current
    val copyToClipboard = rememberClipboardCopy()
    // Advertising ID is flavor-resolved (Play Services in playStore; "N/A" in source-available) and the
    // lookup is a background IPC call, so fetch it once and hold the result for display + copy.
    var advertisingId by remember { mutableStateOf("…") }
    LaunchedEffect(Unit) { advertisingId = flavorAdvertisingId(context) }
    ToolScaffold(viewModel, "About OmniTerm") {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(Icons.Filled.Hub, null, modifier = Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
            Text("OmniTerm Terminal Console", fontWeight = FontWeight.Bold, fontSize = 20.sp, textAlign = TextAlign.Center)
            // Real version from the build — use this to confirm which APK is actually installed.
            Text(
                "Version ${com.jetsetslow.omniterm.BuildConfig.VERSION_NAME}",
                fontSize = 12.sp,
                fontFamily = OmniFonts.mono,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Build ${com.jetsetslow.omniterm.BuildConfig.VERSION_CODE}",
                fontSize = 11.sp,
                fontFamily = OmniFonts.mono,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
            Text(
                "${com.jetsetslow.omniterm.BuildConfig.DISTRIBUTION_NAME} build. Source available for noncommercial use under the PolyForm Noncommercial License 1.0.0. OmniTerm talks directly to your hosts over SSH/SFTP and keeps SSH keys and credentials on-device: no telemetry, no third-party servers.",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )

            Spacer(modifier = Modifier.height(24.dp))
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("Source code & contributions", fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    Text(
                        "Build from source for noncommercial use, file issues, or contribute on GitHub.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    val aboutToolbarColor = MaterialTheme.colorScheme.surface.toArgb()
                    Button(
                        onClick = {
                            if (!openLink(context, GITHUB_URL, viewModel.linkOpenInApp, aboutToolbarColor)) {
                                linkFeedback = "No browser app found."
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Code, contentDescription = "Code")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("View on GitHub")
                    }
                    OutlinedButton(
                        onClick = {
                            if (!openLink(context, "https://github.com/jetsetslow-dev/OmniTerm/blob/main/PRIVACY.md", viewModel.linkOpenInApp, aboutToolbarColor)) {
                                linkFeedback = "No browser app found."
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.PrivacyTip, contentDescription = "Privacy Tip")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Privacy Policy")
                    }
                    Text(GITHUB_URL, fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    if (linkFeedback.isNotEmpty()) {
                        Text(linkFeedback, color = Color.Red, fontSize = 14.sp)
                    }
                }
            }

            // Device & diagnostics — surfaced so users can copy exact build/device details into a
            // support request without hitting a crash first. Mirrors the crash reporter's environment.
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    SectionHeader("Device & diagnostics")
                    HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.3f))
                    DiagnosticRow("App version", com.jetsetslow.omniterm.BuildConfig.VERSION_NAME)
                    DiagnosticRow("Build", com.jetsetslow.omniterm.BuildConfig.VERSION_CODE.toString())
                    DiagnosticRow("Distribution", com.jetsetslow.omniterm.BuildConfig.DISTRIBUTION_NAME)
                    DiagnosticRow("Device", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
                    DiagnosticRow("Android", "${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})")
                    DiagnosticRow("ABI", android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
                    DiagnosticRow("Ad ID", advertisingId)
                    Spacer(modifier = Modifier.height(2.dp))
                    OutlinedButton(
                        onClick = {
                            copyToClipboard(deviceDiagnostics() + "\nAd ID: " + advertisingId)
                            diagFeedback = "Diagnostics copied to clipboard."
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = "Content Copy")
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Copy diagnostics")
                    }
                    if (diagFeedback.isNotEmpty()) {
                        Text(diagFeedback, color = OmniColors.green, fontSize = 12.sp)
                    }
                }
            }

            CrashHistoryCard()
        }
    }
}

/**
 * About → Crash history. Lists past crashes recorded on-device (see [com.jetsetslow.omniterm.data.CrashLog])
 * so a crash that didn't recur at startup can still be reviewed and sent to GitHub. Each entry can be
 * opened to view its full trace, reported as a prefilled GitHub issue, shared (full report attached),
 * or copied. Nothing leaves the device unless the user picks a destination.
 */
@Composable
private fun CrashHistoryCard() {
    val context = LocalContext.current
    val copyToClipboard = rememberClipboardCopy()
    var entries by remember { mutableStateOf(com.jetsetslow.omniterm.data.CrashLog.all(context)) }
    var expandedIndex by remember { mutableStateOf(-1) }
    var feedback by remember { mutableStateOf("") }

    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.red) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            SectionHeader("Crash history")
            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.3f))

            if (entries.isEmpty()) {
                Text(
                    "No crashes recorded. Reports appear here automatically if the app crashes.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Text(
                    "${entries.size} recorded. Release traces are obfuscated — keep the version line so it can be decoded.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                entries.forEachIndexed { index, entry ->
                    val expanded = expandedIndex == index
                    val time = remember(entry.timeMs) {
                        java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US)
                            .format(java.util.Date(entry.timeMs))
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                            .clickable { expandedIndex = if (expanded) -1 else index }
                            .padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                Icons.Filled.BugReport,
                                contentDescription = "Bug Report",
                                tint = OmniColors.red,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Column(Modifier.weight(1f)) {
                                Text(time, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(
                                    entry.headline,
                                    fontSize = 12.sp,
                                    fontFamily = OmniFonts.mono,
                                    maxLines = if (expanded) Int.MAX_VALUE else 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Icon(
                                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                                contentDescription = if (expanded) "Collapse" else "Expand",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        if (expanded) {
                            Text(
                                entry.report,
                                fontSize = 10.sp,
                                fontFamily = OmniFonts.mono,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton(
                                    onClick = {
                                        if (!com.jetsetslow.omniterm.data.CrashLog.openGitHubIssue(context, entry.report)) {
                                            copyToClipboard(entry.report)
                                            feedback = "No browser found — report copied instead."
                                        }
                                    },
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                                ) {
                                    Icon(Icons.Filled.Code, null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Report", fontSize = 12.sp)
                                }
                                OutlinedButton(
                                    onClick = {
                                        runCatching { com.jetsetslow.omniterm.data.CrashLog.shareReport(context, entry.report) }
                                            .onFailure { feedback = "Couldn't open share sheet." }
                                    },
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                                ) {
                                    Icon(Icons.Filled.Share, null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Share", fontSize = 12.sp)
                                }
                                OutlinedButton(
                                    onClick = {
                                        copyToClipboard(entry.report)
                                        feedback = "Report copied to clipboard."
                                    },
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                                ) {
                                    Icon(Icons.Filled.ContentCopy, null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Copy", fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }
                OutlinedButton(
                    onClick = {
                        com.jetsetslow.omniterm.data.CrashLog.clear(context)
                        entries = emptyList()
                        expandedIndex = -1
                        feedback = "Crash history cleared."
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Delete, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Clear history")
                }
            }
            if (feedback.isNotEmpty()) {
                Text(feedback, color = OmniColors.green, fontSize = 12.sp)
            }
        }
    }
}

/**
 * Standardized header for a settings section card. The title is uppercased, accent-colored, and
 * letter-spaced so it reads as a section header rather than just another bold setting label, and a
 * divider visually separates it from the rows below. This is what makes headers (e.g. "Display
 * Behavior") clearly distinct from their sub-settings, which previously shared the same bold style.
 */
@Composable
private fun SettingsCardHeader(title: String, subtitle: String, accent: Color) {
    Column {
        Text(
            title.uppercase(java.util.Locale.US),
            color = accent,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
            letterSpacing = 1.5.sp,
        )
        Text(subtitle, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.height(8.dp))
        HorizontalDivider(color = accent.copy(alpha = 0.35f))
        Spacer(modifier = Modifier.height(10.dp))
    }
}

/** A label/value row for the device diagnostics card; value is monospace for easy scanning. */
@Composable
private fun DiagnosticRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(label, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(96.dp))
        // weight + softWrap lets long values (e.g. the advertising ID) wrap instead of clipping.
        Text(value, fontSize = 13.sp, fontFamily = OmniFonts.mono, softWrap = true, modifier = Modifier.weight(1f))
    }
}

/**
 * Multi-line device/build summary for support requests. Kept in sync with the crash reporter's
 * environment block in MainActivity so a copied report and a copied diagnostics blob look alike.
 */
fun deviceDiagnostics(): String =
    "App version: ${com.jetsetslow.omniterm.BuildConfig.VERSION_NAME} " +
        "(${com.jetsetslow.omniterm.BuildConfig.VERSION_CODE}), ${com.jetsetslow.omniterm.BuildConfig.DISTRIBUTION_NAME}\n" +
        "Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}, " +
        "Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})\n" +
        "ABI: ${android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"}"

private const val GITHUB_URL = "https://github.com/jetsetslow-dev/OmniTerm"

private fun Float.fmtTier(): String =
    if (this == toLong().toFloat()) toLong().toString() else toString()

/** Holds the six editable strings for one metric's scoring tiers (stable across recomposition). */
private class TierFields(t: MetricTiers) {
    var warn by mutableStateOf(t.warnAt.fmtTier())
    var high by mutableStateOf(t.highAt.fmtTier())
    var crit by mutableStateOf(t.criticalAt.fmtTier())
    var warnPen by mutableStateOf(t.warnPenalty.toString())
    var highPen by mutableStateOf(t.highPenalty.toString())
    var critPen by mutableStateOf(t.criticalPenalty.toString())

    fun toTiers(d: MetricTiers) = MetricTiers(
        warn.toFloatOrNull() ?: d.warnAt, high.toFloatOrNull() ?: d.highAt, crit.toFloatOrNull() ?: d.criticalAt,
        warnPen.toIntOrNull() ?: d.warnPenalty, highPen.toIntOrNull() ?: d.highPenalty, critPen.toIntOrNull() ?: d.criticalPenalty,
    )
}

@Composable
private fun ScoreField(label: String, value: String, onValue: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = { onValue(it.filter { ch -> ch.isDigit() || ch == '.' }) },
        label = { Text(label, fontSize = 10.sp) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.width(82.dp),
    )
}

/** Dedicated Tools section hosting the health-scoring editor. */
@Composable
fun HealthScoringToolView(viewModel: AppViewModel) {
    ToolScaffold(viewModel, "Health scoring") {
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            HealthScoringCard(viewModel)
        }
    }
}

/** Editor for the health-scoring thresholds and per-tier penalty weights. */
@Composable
private fun HealthScoringCard(viewModel: AppViewModel) {
    val cfg = viewModel.healthConfig
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    var resetKey by remember { mutableStateOf(0) }
    // Re-seed local fields when the persisted config changes (save/reset) but not while typing.
    val cpu = remember(resetKey, cfg) { TierFields(cfg.cpu) }
    val mem = remember(resetKey, cfg) { TierFields(cfg.mem) }
    val disk = remember(resetKey, cfg) { TierFields(cfg.disk) }
    val lat = remember(resetKey, cfg) { TierFields(cfg.latency) }

    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Health scoring", fontWeight = FontWeight.Bold)
            Text(
                "Score starts at 100; each metric subtracts points when it reaches a tier " +
                    "(warn / high / critical). Edit the thresholds and the points each deducts.",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            @Composable
            fun block(name: String, unit: String, f: TierFields) {
                Text("$name · threshold ($unit) then penalty", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ScoreField("warn ≥", f.warn) { f.warn = it }
                    ScoreField("high ≥", f.high) { f.high = it }
                    ScoreField("crit ≥", f.crit) { f.crit = it }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    ScoreField("-pts", f.warnPen) { f.warnPen = it }
                    ScoreField("-pts", f.highPen) { f.highPen = it }
                    ScoreField("-pts", f.critPen) { f.critPen = it }
                }
            }

            block("CPU", "%", cpu)
            block("Memory", "%", mem)
            block("Disk", "%", disk)
            block("Latency", "ms", lat)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    confirm.ask(
                        "Save scoring config?",
                        "Replace the current health-scoring thresholds and penalties? Health scores for all hosts will be recalculated with the new values.",
                        confirmLabel = "Save",
                        destructive = false,
                    ) {
                        viewModel.saveHealthConfig(
                            HealthScoringConfig(
                                cpu = cpu.toTiers(HealthScoringConfig.DEFAULT.cpu),
                                mem = mem.toTiers(HealthScoringConfig.DEFAULT.mem),
                                disk = disk.toTiers(HealthScoringConfig.DEFAULT.disk),
                                latency = lat.toTiers(HealthScoringConfig.DEFAULT.latency),
                            )
                        )
                    }
                }) { Text("Save scoring") }
                OutlinedButton(onClick = {
                    confirm.ask(
                        "Reset to defaults?",
                        "Discard your custom health-scoring thresholds and penalties and restore the built-in defaults? This cannot be undone.",
                        confirmLabel = "Reset",
                    ) { viewModel.resetHealthConfig(); resetKey++ }
                }) { Text("Reset defaults") }
            }
        }
    }
}

@Composable
private fun DnsLookupTab(viewModel: AppViewModel) {
    var dropdownExpanded by remember { mutableStateOf(false) }
    val dnsTypes = listOf("A", "AAAA", "MX", "CNAME", "TXT", "NS")

    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = viewModel.dnsLookupTarget,
            onValueChange = { viewModel.dnsLookupTarget = it },
            label = { Text("Domain Name / Hostname") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri)
        )

        Box(modifier = Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = viewModel.dnsLookupType,
                onValueChange = { },
                readOnly = true,
                label = { Text("Query Type") },
                modifier = Modifier.fillMaxWidth(),
                trailingIcon = {
                    IconButton(onClick = { dropdownExpanded = true }) {
                        Icon(Icons.Filled.ArrowDropDown, "Pick Type")
                    }
                }
            )
            DropdownMenu(expanded = dropdownExpanded, onDismissRequest = { dropdownExpanded = false }) {
                dnsTypes.forEach { type ->
                    DropdownMenuItem(
                        text = { Text(type) },
                        onClick = {
                            viewModel.dnsLookupType = type
                            dropdownExpanded = false
                        }
                    )
                }
            }
        }

        Button(
            onClick = { viewModel.runDnsLookup() },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.dnsLookupTarget.isNotBlank() && !viewModel.isDnsLookupRunning
        ) {
            if (viewModel.isDnsLookupRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Querying...")
            } else {
                Text("Run DNS Query")
            }
        }

        if (viewModel.dnsLookupError != null) {
            Text(
                text = viewModel.dnsLookupError ?: "",
                color = OmniColors.red,
                fontSize = 13.sp,
                fontFamily = OmniFonts.mono,
                modifier = Modifier.padding(vertical = 4.dp)
            )
        }

        SelectionContainer(modifier = Modifier.weight(1f)) {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(viewModel.dnsLookupResults) { record ->
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                        Column(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(record.name, fontWeight = FontWeight.Bold, fontSize = 14.sp, modifier = Modifier.weight(1f))
                                Text(record.type, color = OmniColors.cyan, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            }
                            Spacer(modifier = Modifier.height(4.dp))
                            Text("Value: ${record.value}", fontSize = 13.sp, fontFamily = OmniFonts.mono)
                            Text("TTL: ${record.ttl}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun WhoisTab(viewModel: AppViewModel) {
    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = viewModel.whoisTarget,
            onValueChange = { viewModel.whoisTarget = it },
            label = { Text("Domain Name or IP Address") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri)
        )

        Button(
            onClick = { viewModel.runWhois() },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.whoisTarget.isNotBlank() && !viewModel.isWhoisRunning
        ) {
            if (viewModel.isWhoisRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Querying...")
            } else {
                Text("Run WHOIS Query")
            }
        }

        if (viewModel.whoisError != null) {
            Text(
                text = viewModel.whoisError ?: "",
                color = OmniColors.red,
                fontSize = 13.sp,
                fontFamily = OmniFonts.mono,
                modifier = Modifier.padding(vertical = 4.dp)
            )
        }

        if (viewModel.whoisResult.isNotBlank()) {
            OmniCard(modifier = Modifier.fillMaxWidth().weight(1f)) {
                val scrollState = rememberScrollState()
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(10.dp)
                        .verticalScroll(scrollState)
                ) {
                    SelectionContainer {
                        Text(
                            text = viewModel.whoisResult,
                            fontSize = 11.sp,
                            fontFamily = OmniFonts.mono,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SpeedTestTab(viewModel: AppViewModel) {
    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            "Measures this device's download throughput from a URL. Pick a test server near you (or one deliberately far away), or point the URL at your own server to test a specific link.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        var serverMenuOpen by remember { mutableStateOf(false) }
        val selectedServer = viewModel.speedTestServers.firstOrNull { it.second == viewModel.speedTestUrl }
        Box(modifier = Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = selectedServer?.first ?: "Custom URL",
                onValueChange = { },
                readOnly = true,
                label = { Text("Test Server") },
                modifier = Modifier.fillMaxWidth(),
                trailingIcon = {
                    IconButton(onClick = { serverMenuOpen = true }) {
                        Icon(Icons.Filled.ArrowDropDown, "Pick test server")
                    }
                },
            )
            DropdownMenu(expanded = serverMenuOpen, onDismissRequest = { serverMenuOpen = false }) {
                viewModel.speedTestServers.forEach { (label, url) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        onClick = {
                            viewModel.speedTestUrl = url
                            serverMenuOpen = false
                        },
                    )
                }
            }
        }
        OutlinedTextField(
            value = viewModel.speedTestUrl,
            onValueChange = { viewModel.speedTestUrl = it },
            label = { Text("Download URL") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        )

        // Live gauge card.
        val mbps = viewModel.speedTestMbps
        OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    if (mbps != null) String.format(LocalLocale.current.platformLocale, "%.1f", mbps) else "—",
                    fontSize = 44.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = OmniFonts.mono,
                    color = if (viewModel.isSpeedTestRunning) OmniColors.cyan else OmniColors.green,
                )
                Text("Mbps", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(formatBytes(viewModel.speedTestBytes), fontSize = 14.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold)
                        Text("downloaded", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    viewModel.speedTestLatencyMs?.let { lat ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("$lat ms", fontSize = 14.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold)
                            Text("time to first byte", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }

        Button(
            onClick = { if (viewModel.isSpeedTestRunning) viewModel.cancelSpeedTest() else viewModel.runSpeedTest() },
            modifier = Modifier.fillMaxWidth(),
            enabled = viewModel.speedTestUrl.isNotBlank(),
            colors = if (viewModel.isSpeedTestRunning) ButtonDefaults.buttonColors(containerColor = OmniColors.amber) else ButtonDefaults.buttonColors(),
        ) {
            if (viewModel.isSpeedTestRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Stop")
            } else {
                Text("Start Speed Test")
            }
        }

        if (viewModel.speedTestError != null) {
            Text(
                text = viewModel.speedTestError ?: "",
                color = OmniColors.red,
                fontSize = 13.sp,
                fontFamily = OmniFonts.mono,
            )
        }
    }
}

@Composable
private fun TunnelsTab(viewModel: AppViewModel) {
    val tunnels = viewModel.portForwards.collectAsStateWithLifecycle().value
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<PortForwardEntity?>(null) }
    var showEditor by remember { mutableStateOf(false) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("SSH Tunnels", fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Button(
                onClick = { editing = null; showEditor = true },
                enabled = servers.isNotEmpty(),
            ) {
                Icon(Icons.Filled.Add, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text("Add")
            }
        }
        Text(
            "Local (-L), remote (-R) and dynamic SOCKS (-D) forwards over a saved SSH host. Tunnels stay up until you stop them or leave the app.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (servers.isEmpty()) {
            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("Add an SSH host first.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else if (tunnels.isEmpty()) {
            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("No tunnels yet. Tap Add to create one.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                items(tunnels, key = { it.id }) { pf ->
                    val active = viewModel.isTunnelActive(pf.id)
                    val busy = viewModel.isTunnelBusy(pf.id)
                    val srvName = servers.find { it.id == pf.serverId }?.name ?: "(missing host)"
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = if (active) OmniColors.green else MaterialTheme.colorScheme.onSurfaceVariant) {
                        Column(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(pf.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                    Text(
                                        tunnelSummary(pf),
                                        fontSize = 12.sp,
                                        fontFamily = OmniFonts.mono,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Text("via $srvName", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                if (busy) {
                                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                                } else {
                                    Switch(checked = active, onCheckedChange = { viewModel.toggleTunnel(pf) })
                                }
                            }
                            viewModel.tunnelErrors[pf.id]?.let { err ->
                                Text(err, color = OmniColors.red, fontSize = 11.sp, fontFamily = OmniFonts.mono, modifier = Modifier.padding(top = 4.dp))
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), modifier = Modifier.fillMaxWidth()) {
                                TextButton(onClick = { editing = pf; showEditor = true }, enabled = !active) { Text("Edit") }
                                TextButton(onClick = {
                                    confirm.ask("Delete \"${pf.name}\"?", "Remove this saved tunnel? If it's running it will be stopped.", confirmLabel = "Delete") {
                                        viewModel.deletePortForward(pf)
                                    }
                                }) { Text("Delete", color = OmniColors.red) }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showEditor) {
        TunnelEditorDialog(
            viewModel = viewModel,
            existing = editing,
            servers = servers,
            onDismiss = { showEditor = false },
        )
    }
}

private fun tunnelSummary(pf: PortForwardEntity): String = when (pf.kind) {
    "remote" -> "-R ${pf.bindHost}:${pf.bindPort} → ${pf.destHost}:${pf.destPort}"
    "dynamic" -> "-D ${pf.bindHost}:${pf.bindPort} (SOCKS5)"
    else -> "-L ${pf.bindHost}:${pf.bindPort} → ${pf.destHost}:${pf.destPort}"
}

@Composable
private fun TunnelEditorDialog(
    viewModel: AppViewModel,
    existing: PortForwardEntity?,
    servers: List<ServerEntity>,
    onDismiss: () -> Unit,
) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var kind by remember { mutableStateOf(existing?.kind ?: "local") }
    var serverId by remember { mutableStateOf(existing?.serverId ?: servers.firstOrNull()?.id ?: 0) }
    var bindHost by remember { mutableStateOf(existing?.bindHost ?: "127.0.0.1") }
    var bindPort by remember { mutableStateOf(existing?.bindPort?.toString() ?: "") }
    var destHost by remember { mutableStateOf(existing?.destHost ?: "") }
    var destPort by remember { mutableStateOf(existing?.destPort?.toString() ?: "") }
    var autoStart by remember { mutableStateOf(existing?.autoStart ?: false) }
    var error by remember { mutableStateOf<String?>(null) }
    var serverMenu by remember { mutableStateOf(false) }
    var kindMenu by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing == null) "New tunnel" else "Edit tunnel") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())

                // Kind picker.
                Box {
                    OutlinedTextField(
                        value = when (kind) { "remote" -> "Remote (-R)"; "dynamic" -> "Dynamic SOCKS (-D)"; else -> "Local (-L)" },
                        onValueChange = {}, readOnly = true, label = { Text("Type") },
                        trailingIcon = { IconButton(onClick = { kindMenu = true }) { Icon(Icons.Filled.ArrowDropDown, null) } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    DropdownMenu(expanded = kindMenu, onDismissRequest = { kindMenu = false }) {
                        listOf("local" to "Local (-L)", "remote" to "Remote (-R)", "dynamic" to "Dynamic SOCKS (-D)").forEach { (k, label) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { kind = k; kindMenu = false })
                        }
                    }
                }

                // Server picker.
                Box {
                    OutlinedTextField(
                        value = servers.find { it.id == serverId }?.name ?: "Select host",
                        onValueChange = {}, readOnly = true, label = { Text("SSH host") },
                        trailingIcon = { IconButton(onClick = { serverMenu = true }) { Icon(Icons.Filled.ArrowDropDown, null) } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    DropdownMenu(expanded = serverMenu, onDismissRequest = { serverMenu = false }) {
                        servers.forEach { s ->
                            DropdownMenuItem(text = { Text(s.name) }, onClick = { serverId = s.id; serverMenu = false })
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = bindHost, onValueChange = { bindHost = it }, label = { Text(if (kind == "remote") "Remote bind host" else "Bind host") }, singleLine = true, modifier = Modifier.weight(1.4f))
                    OutlinedTextField(value = bindPort, onValueChange = { bindPort = it.filter(Char::isDigit).take(5) }, label = { Text("Port") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.weight(1f))
                }
                if (kind != "dynamic") {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = destHost, onValueChange = { destHost = it }, label = { Text("Dest host") }, singleLine = true, modifier = Modifier.weight(1.4f))
                        OutlinedTextField(value = destPort, onValueChange = { destPort = it.filter(Char::isDigit).take(5) }, label = { Text("Port") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.weight(1f))
                    }
                }
                Text(
                    when (kind) {
                        "remote" -> "The remote host listens on its bind port and forwards connections back to dest host:port reachable from this device."
                        "dynamic" -> "Opens a SOCKS5 proxy on the bind host:port; point apps at it to route through the SSH host."
                        else -> "This device listens on bind host:port and forwards to dest host:port reachable from the SSH host."
                    },
                    fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = autoStart, onCheckedChange = { autoStart = it })
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text("Start when OmniTerm opens", fontSize = 13.sp)
                        Text(
                            "The tunnel remains scoped to the app and stops when OmniTerm closes.",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                error?.let { Text(it, color = OmniColors.red, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            Button(onClick = {
                val pf = PortForwardEntity(
                    id = existing?.id ?: 0,
                    serverId = serverId,
                    name = name.trim(),
                    kind = kind,
                    bindHost = bindHost.trim().ifBlank { "127.0.0.1" },
                    bindPort = bindPort.toIntOrNull() ?: 0,
                    destHost = destHost.trim(),
                    destPort = destPort.toIntOrNull() ?: 0,
                    autoStart = autoStart,
                )
                viewModel.savePortForward(pf) { err ->
                    if (err == null) onDismiss() else error = err
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
