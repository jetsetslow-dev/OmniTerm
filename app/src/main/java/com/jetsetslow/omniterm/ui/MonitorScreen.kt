package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.data.*
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

@Composable
fun MonitorScreen(viewModel: AppViewModel) {
    val serversList by viewModel.servers.collectAsState()
    val onlineServers = serversList.filter { it.status == "online" }
    val srv = onlineServers.find { it.id == viewModel.selectedServerId } ?: onlineServers.firstOrNull()
    LaunchedEffect(srv?.id) {
        if (srv != null && viewModel.selectedServerId != srv.id) viewModel.selectedServerId = srv.id
    }
    if (srv == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No online hosts available to monitor. Offline hosts reappear after the next successful probe.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    var showScoreDialog by remember { mutableStateOf(false) }
    var showRebootDialog by remember { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxSize()) {
        ServerSelectorBar(
            viewModel = viewModel,
            onlineOnly = true,
            leadingContent = {
                Box(
                    modifier = Modifier.clickable { showScoreDialog = true }.padding(end = 4.dp),
                    contentAlignment = Alignment.Center
                ) {
                    ScoreRing(score = srv.healthScore, size = 32.dp)
                }
            },
            trailingContent = {
                RefreshCountdown(viewModel.lastTelemetryStartMs, viewModel.telemetryIntervalMs, size = 28.dp, color = getServerColor(srv))
                IconButton(onClick = { showRebootDialog = true }, enabled = srv.status == "online", modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.RestartAlt, contentDescription = "Reboot host", tint = OmniColors.red, modifier = Modifier.size(18.dp))
                }
            }
        )

        if (showRebootDialog) {
            AlertDialog(
                onDismissRequest = { showRebootDialog = false },
                title = { Text("Reboot ${srv.name}?") },
                text = { Text("This runs `sudo reboot` on ${srv.host}. The host will drop offline until it comes back up. Requires passwordless sudo for the SSH user.") },
                confirmButton = {
                    TextButton(onClick = {
                        showRebootDialog = false
                        viewModel.rebootSelectedServer()
                    }) { Text("Reboot", color = OmniColors.red) }
                },
                dismissButton = { TextButton(onClick = { showRebootDialog = false }) { Text("Cancel") } },
            )
        }

        // Subtabs selection navigation bar
        ScrollableTabRow(
            selectedTabIndex = viewModel.activeMonitorTab,
            edgePadding = 12.dp,
            modifier = Modifier.fillMaxWidth()
        ) {
            val tabs = listOf("Overview", "Processes", "Services", "Logs", "Scripts", "CRON")
            tabs.forEachIndexed { idx, title ->
                Tab(
                    selected = viewModel.activeMonitorTab == idx,
                    onClick = { viewModel.activeMonitorTab = idx }
                ) { Text(title, fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp), fontWeight = FontWeight.SemiBold) }
            }
        }

        // Selected Subview render container
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(horizontal = 12.dp, vertical = 6.dp)
        ) {
            when (viewModel.activeMonitorTab) {
                0 -> OverviewTab(viewModel, srv)
                1 -> ProcessesTab(viewModel, srv)
                2 -> ServicesTab(viewModel, srv)
                3 -> LogsTab(viewModel)
                4 -> QuickScriptsMonitorTab(viewModel, srv)
                5 -> CronMonitorTab(viewModel, srv)
            }
        }

        // Health score breakdown for the selected host (which metrics are deducting points).
        if (showScoreDialog) {
            HealthBreakdownDialog(viewModel, srv) { showScoreDialog = false }
        }
    }
}

@Composable
fun QuickScriptsMonitorTab(viewModel: AppViewModel, srv: ServerEntity) {
    val scripts by viewModel.quickScripts.collectAsState()
    val metrics = viewModel.hostMetricsById[srv.id]
    var customCommand by remember { mutableStateOf("") }
    var showSaveDialog by remember { mutableStateOf(false) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    // Show what will run where before executing — a stray tap on a script card must not be
    // enough to run an arbitrary command on the host. Mirrors the fleet broadcast dialog,
    // including the destructive-command heuristic.
    fun confirmAndRun(title: String, command: String) {
        val danger = commandDangerHits(command)
        confirm.ask(
            title = "Run on ${srv.name}?",
            message = buildString {
                appendLine("$ $command")
                appendLine()
                append("Runs on ${srv.username}@${srv.host}.")
                if (danger.isNotEmpty()) {
                    appendLine()
                    appendLine()
                    append("⚠ This command looks destructive (${danger.joinToString(", ")}).")
                }
            },
            confirmLabel = "Run",
            destructive = danger.isNotEmpty(),
        ) { viewModel.runStreamingAction(title, command) }
    }
    val visibleScripts = scripts
        .filter { quickScriptMatchesHost(it, metrics) }
        .sortedWith(compareBy<QuickScriptEntity> { it.category }.thenBy { it.sortOrder }.thenBy { it.name.lowercase() })
    val grouped = visibleScripts.groupBy { it.category.ifBlank { "General" } }

    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        item {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                Text("Custom command", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = customCommand,
                    onValueChange = { customCommand = it },
                    placeholder = { Text("Enter host command script here...") },
                    prefix = { Text("$ ", fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold) },
                    textStyle = LocalTextStyle.current.copy(fontFamily = OmniFonts.mono, fontSize = 14.sp),
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                    shape = RoundedCornerShape(8.dp),
                    colors = omniTextFieldColors(),
                )
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        enabled = customCommand.isNotBlank(),
                        onClick = { showSaveDialog = true },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Save")
                    }
                    Button(
                        enabled = customCommand.isNotBlank() && srv.status == "online",
                        onClick = { confirmAndRun("custom · ${srv.name}", customCommand) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Run")
                    }
                }
            }
        }

        if (metrics == null) {
            item {
                Text(
                    "Host OS and system details will appear after the next monitor refresh.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        if (visibleScripts.isEmpty()) {
            item {
                OmniCard(modifier = Modifier.fillMaxWidth()) {
                    Text("No quick scripts match this host.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            grouped.forEach { (category, items) ->
                item {
                    Text(
                        text = category,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp,
                        color = OmniColors.cyan,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                }
                items(items, key = { it.id }) { script ->
                    OmniCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = srv.status == "online") {
                                confirmAndRun("${script.emoji} ${script.name}", script.command)
                            },
                        leftAccent = getServerColor(srv),
                    ) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("${script.emoji} ${script.name}", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    script.command,
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    fontFamily = OmniFonts.mono,
                                    maxLines = 3,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                if (!script.targetOs.equals("Any", ignoreCase = true)) OmniTag(script.targetOs, color = OmniColors.amber)
                                if (!script.targetSystem.equals("Any", ignoreCase = true)) OmniTag(script.targetSystem, color = OmniColors.purple)
                            }
                        }
                    }
                }
            }
        }
    }

    if (showSaveDialog) {
        SharedScriptEditorDialog(
            existing = null,
            title = "Save script",
            initialCommand = customCommand,
            defaultAvailableForQuick = true,
            defaultAvailableForFleet = false,
            defaultTargetOs = metrics?.os?.ifBlank { "Any" } ?: "Any",
            onDismiss = { showSaveDialog = false },
            onSave = { draft ->
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
                )
                showSaveDialog = false
            }
        )
    }
}

@Composable
fun CronMonitorTab(viewModel: AppViewModel, srv: ServerEntity) {
    LaunchedEffect(srv.id) { viewModel.loadCron() }
    var editorTarget by remember { mutableStateOf<CronLine?>(null) }
    var createNew by remember { mutableStateOf(false) }
    val cronLines = remember(viewModel.cronText) { parseCronLines(viewModel.cronText) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(srv.name, fontWeight = FontWeight.Bold)
                        Text("${srv.username}@${srv.host}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedButton(onClick = { viewModel.loadCron() }, enabled = !viewModel.cronLoading) {
                            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Reload", fontSize = 12.sp)
                        }
                        Button(onClick = { createNew = true }, enabled = !viewModel.cronLoading) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Add", fontSize = 12.sp)
                        }
                    }
                }
            }
        }
        if (viewModel.cronStatus.isNotBlank()) {
            item {
                Text(
                    viewModel.cronStatus,
                    fontSize = 12.sp,
                    color = if (viewModel.cronStatus.contains("saved", ignoreCase = true)) OmniColors.green else OmniColors.red,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }
        }
        item {
            when {
                viewModel.cronLoading && viewModel.cronText.isEmpty() ->
                    Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    }
                else -> {
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
                        if (cronLines.isEmpty()) {
                            Text("No crontab entries for ${srv.username}.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                        } else {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                cronLines.forEach { line ->
                                    CronLineCard(
                                        line = line,
                                        onEdit = { if (line.editable) editorTarget = line },
                                        onDelete = {
                                            confirm.ask(
                                                "Delete cron entry?",
                                                "Delete this crontab entry for ${srv.username}@${srv.host}? This rewrites the remote user's crontab.",
                                                confirmLabel = "Delete",
                                            ) {
                                                val next = cronLines.filterNot { it.index == line.index }.joinToString("\n") { it.raw }
                                                viewModel.saveCron(next)
                                            }
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (createNew) {
        CronScheduleDialog(
            title = "Add cron schedule",
            initial = null,
            onDismiss = { createNew = false },
            onSave = { line ->
                val next = (cronLines.map { it.raw } + line).joinToString("\n")
                viewModel.saveCron(next)
                createNew = false
            },
        )
    }

    editorTarget?.let { target ->
        CronScheduleDialog(
            title = "Edit cron schedule",
            initial = target,
            onDismiss = { editorTarget = null },
            onSave = { line ->
                val next = cronLines.map { if (it.index == target.index) line else it.raw }.joinToString("\n")
                viewModel.saveCron(next)
                editorTarget = null
            },
        )
    }
}

private data class CronLine(
    val index: Int,
    val raw: String,
    val expression: String,
    val command: String,
    val editable: Boolean,
)

private fun parseCronLines(text: String): List<CronLine> =
    text.lines()
        .mapIndexedNotNull { index, raw ->
            val trimmed = raw.trim()
            if (trimmed.isBlank()) return@mapIndexedNotNull null
            val parts = trimmed.split(Regex("\\s+"), limit = 6)
            val editable = parts.size == 6 && !trimmed.startsWith("#") && "=" !in parts.first()
            CronLine(
                index = index,
                raw = trimmed,
                expression = if (editable) parts.take(5).joinToString(" ") else "",
                command = if (editable) parts[5] else trimmed,
                editable = editable,
            )
        }

@Composable
private fun CronLineCard(line: CronLine, onEdit: () -> Unit, onDelete: () -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                if (line.editable) cronSummary(line.expression) else "Raw crontab line",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                if (line.editable) line.command else line.raw,
                fontFamily = OmniFonts.mono,
                fontSize = 11.sp,
                color = if (line.raw.startsWith("#")) Color.Gray else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            if (line.editable) {
                Text(line.expression, fontFamily = OmniFonts.mono, fontSize = 10.sp, color = OmniColors.amber)
            }
        }
        Row {
            IconButton(onClick = onEdit, enabled = line.editable, modifier = Modifier.size(34.dp)) {
                Icon(Icons.Filled.Edit, contentDescription = "Edit cron entry", modifier = Modifier.size(18.dp))
            }
            IconButton(onClick = onDelete, modifier = Modifier.size(34.dp)) {
                Icon(Icons.Filled.Delete, contentDescription = "Delete cron entry", tint = OmniColors.red, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
private fun CronScheduleDialog(
    title: String,
    initial: CronLine?,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var name by remember(initial?.raw) { mutableStateOf(initial?.command?.substringAfter("# OmniTerm:", "")?.trim()?.takeIf { it.isNotBlank() } ?: "") }
    var command by remember(initial?.raw) { mutableStateOf(initial?.command?.substringBefore("# OmniTerm:")?.trim() ?: "") }
    var preset by remember(initial?.raw) { mutableStateOf(cronPresetFor(initial?.expression)) }
    var minute by remember(initial?.raw) { mutableStateOf(initial?.expression?.cronPart(0) ?: "0") }
    var hour by remember(initial?.raw) { mutableStateOf(initial?.expression?.cronPart(1) ?: "2") }
    var day by remember(initial?.raw) { mutableStateOf(initial?.expression?.cronPart(2) ?: "*") }
    var month by remember(initial?.raw) { mutableStateOf(initial?.expression?.cronPart(3) ?: "*") }
    var weekday by remember(initial?.raw) { mutableStateOf(initial?.expression?.cronPart(4) ?: "*") }

    fun applyPreset(next: String) {
        preset = next
        when (next) {
            "hourly" -> { minute = "0"; hour = "*"; day = "*"; month = "*"; weekday = "*" }
            "daily" -> { minute = "0"; hour = "2"; day = "*"; month = "*"; weekday = "*" }
            "weekly" -> { minute = "0"; hour = "2"; day = "*"; month = "*"; weekday = "0" }
            "monthly" -> { minute = "0"; hour = "2"; day = "1"; month = "*"; weekday = "*" }
        }
    }

    val expression = "$minute $hour $day $month $weekday"
    val valid = command.isNotBlank() && isCronPartValid(minute, 0, 59) &&
        isCronPartValid(hour, 0, 23) &&
        isCronPartValid(day, 1, 31) &&
        isCronPartValid(month, 1, 12) &&
        isCronPartValid(weekday, 0, 7)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("Schedule", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                    listOf("hourly" to "Hourly", "daily" to "Daily", "weekly" to "Weekly", "monthly" to "Monthly", "custom" to "Custom").forEach { (key, label) ->
                        FilterChip(
                            selected = preset == key,
                            onClick = { applyPreset(key) },
                            label = { Text(label, fontSize = 11.sp) },
                        )
                    }
                }
                CronPartField("Minute", minute, { minute = it; preset = "custom" }, "0-59, *, */5")
                CronPartField("Hour", hour, { hour = it; preset = "custom" }, "0-23, *, */2")
                CronPartField("Day", day, { day = it; preset = "custom" }, "1-31 or *")
                CronPartField("Month", month, { month = it; preset = "custom" }, "1-12 or *")
                CronPartField("Weekday", weekday, { weekday = it; preset = "custom" }, "0-7, Sunday=0/7")
                Text("Preview: ${cronSummary(expression)}", fontSize = 12.sp, color = OmniColors.amber)
                Text(expression, fontSize = 12.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Label (optional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = command,
                    onValueChange = { command = it },
                    label = { Text("Command") },
                    textStyle = LocalTextStyle.current.copy(fontFamily = OmniFonts.mono, fontSize = 12.sp),
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            Button(
                enabled = valid,
                onClick = {
                    val label = name.trim().takeIf { it.isNotBlank() }?.let { " # OmniTerm: $it" } ?: ""
                    onSave("$expression ${command.trim()}$label")
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun CronPartField(label: String, value: String, onChange: (String) -> Unit, hint: String) {
    OutlinedTextField(
        value = value,
        onValueChange = { raw -> onChange(raw.filter { it.isDigit() || it in setOf('*', '/', ',', '-') }.take(24)) },
        label = { Text(label) },
        placeholder = { Text(hint) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun String.cronPart(index: Int): String =
    split(Regex("\\s+")).getOrNull(index) ?: "*"

private fun cronPresetFor(expression: String?): String =
    when (expression?.trim()) {
        "0 * * * *" -> "hourly"
        "0 2 * * *" -> "daily"
        "0 2 * * 0" -> "weekly"
        "0 2 1 * *" -> "monthly"
        else -> "custom"
    }

private fun isCronPartValid(part: String, min: Int, max: Int): Boolean {
    if (part == "*") return true
    val cleaned = part.removePrefix("*/")
    return cleaned.split(",", "-").all { token ->
        token == "*" || token.toIntOrNull()?.let { it in min..max } == true
    }
}

private fun cronSummary(expression: String): String =
    when (expression.trim()) {
        "0 * * * *" -> "Every hour"
        "0 2 * * *" -> "Every day at 02:00"
        "0 2 * * 0" -> "Every Sunday at 02:00"
        "0 2 1 * *" -> "Monthly on day 1 at 02:00"
        else -> "Custom schedule"
    }

@Composable
fun OverviewTab(viewModel: AppViewModel, srv: ServerEntity) {
    // Seed instantly from the shared telemetry map so switching hosts shows cached values right
    // away, then trigger a single fresh fetch. Continuous updates are driven by the central
    // telemetry poller (which keeps hostMetrics live) instead of a second redundant SSH loop here.
    LaunchedEffect(srv.id) {
        viewModel.seedHostMetricsFromCache(srv.id)
        viewModel.loadHostMetrics()
        viewModel.loadMetricsHistory(srv.id)
    }
    val m = viewModel.hostMetrics
    val accent = getServerColor(srv)
    val spark = viewModel.fetchCachedSparkline(srv.id)

    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        // The header's RefreshCountdown is the single refresh indicator — no separate spinner here.
        item {
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text("CPU UTILISATION", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("Load: ${m.load1} · ${m.load5} · ${m.load15}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        m.cpuTempC?.let {
                            Text("Temp: ${it.roundToInt()}°C", fontSize = 12.sp, color = if (it >= 80f) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text("${m.cpuPercent.roundToInt()}%", fontSize = 28.sp, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, color = accent)
                }
                Spacer(modifier = Modifier.height(12.dp))
                MetricLineChart(
                    points = spark,
                    color = accent,
                    label = "CPU utilisation",
                    unit = "%",
                )
                if (m.perCoreCpu.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(10.dp))
                    Text("PER-CORE (${m.perCoreCpu.size})", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(modifier = Modifier.height(4.dp))
                    m.perCoreCpu.forEachIndexed { i, v ->
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 1.dp)) {
                            Text("c$i", fontSize = 10.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(26.dp))
                            GaugeBar(value = v, color = accent, height = 5.dp, modifier = Modifier.weight(1f))
                            Text("${v.roundToInt()}%", fontSize = 10.sp, fontFamily = OmniFonts.mono, modifier = Modifier.width(36.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
                        }
                    }
                }
            }
        }

        item {
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Text("MEMORY OCCUPANCY", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    "${RemoteParsers.humanBytes(m.memUsedBytes)} of ${RemoteParsers.humanBytes(m.memTotalBytes)} occupied (${m.memPercent.roundToInt()}%)",
                    fontSize = 14.sp
                )
                Spacer(modifier = Modifier.height(10.dp))
                GaugeBar(value = m.memPercent, color = OmniColors.amber, height = 7.dp)
            }
        }

        item {
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Disk Mounts", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (m.diskReadPerSec > 0 || m.diskWritePerSec > 0) {
                        Text(
                            "R ${RemoteParsers.humanBytes(m.diskReadPerSec)}/s · W ${RemoteParsers.humanBytes(m.diskWritePerSec)}/s",
                            fontSize = 10.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(modifier = Modifier.height(6.dp))
                // All real mounts when available; fall back to the root summary otherwise.
                val mounts = m.disks.ifEmpty {
                    if (m.diskTotalBytes > 0) listOf(DiskUsage("/", "", m.diskTotalBytes, m.diskUsedBytes)) else emptyList()
                }
                if (mounts.isEmpty()) {
                    Text("—", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    mounts.forEach { d ->
                        Spacer(modifier = Modifier.height(6.dp))
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                                Text(d.mount, fontSize = 14.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                if (d.health.isNotBlank()) {
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Text(
                                        d.health,
                                        fontSize = 10.sp, fontFamily = OmniFonts.mono,
                                        color = if (d.health.equals("Passed", true) || d.health.equals("OK", true)) OmniColors.green else OmniColors.red,
                                    )
                                }
                            }
                            Text(
                                "${RemoteParsers.humanBytes(d.usedBytes)} / ${RemoteParsers.humanBytes(d.totalBytes)} (${d.percent.roundToInt()}%)",
                                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(modifier = Modifier.height(4.dp))
                        GaugeBar(value = d.percent, color = OmniColors.purple, height = 6.dp)
                    }
                }
            }
        }

        item {
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Network", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("TCP: ${m.tcpConnections}", fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    "↓ ${RemoteParsers.humanBytes(m.netRxPerSec)}/s   ↑ ${RemoteParsers.humanBytes(m.netTxPerSec)}/s",
                    fontSize = 14.sp, fontFamily = OmniFonts.mono, color = accent,
                )
                if (m.netInterfaces.isEmpty()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text("Per-interface rates appear after the next refresh.", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    m.netInterfaces.forEach { iface ->
                        Spacer(modifier = Modifier.height(4.dp))
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(iface.name, fontSize = 12.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold)
                            Text(
                                "↓${RemoteParsers.humanBytes(iface.rxPerSec)}/s ↑${RemoteParsers.humanBytes(iface.txPerSec)}/s",
                                fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Text(
                            "total ↓${RemoteParsers.humanBytes(iface.rxBytes)} ↑${RemoteParsers.humanBytes(iface.txBytes)}",
                            fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        item {
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                SectionHeader("System", modifier = Modifier.padding(0.dp))
                if (m.os.isNotBlank()) StatRow("OS", m.os)
                StatRow("Uptime", formatUptime(m.uptimeSeconds))
                StatRow("Processes", if (m.procCount > 0) m.procCount.toString() else "—")
                StatRow("Latency", if (srv.status == "online") "${srv.lastLatency} ms" else "—")
                StatRow("Status", if (srv.status == "online") "Online" else "Offline")
            }
        }

        val history = viewModel.metricsHistory
        if (history.size >= 2) {
            item {
                OmniCard(modifier = Modifier.fillMaxWidth()) {
                    Text("7-DAY HISTORY", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))
                    val hourlyBuckets = history.groupBy { it.timestamp / (3_600_000L) }
                        .entries.sortedBy { it.key }
                    val cpuPoints = hourlyBuckets.map { (_, rows) -> rows.map { it.cpuUsage }.average().toFloat() }
                    val ramPoints = hourlyBuckets.map { (_, rows) -> rows.map { it.ramUsage }.average().toFloat() }
                    MetricLineChart(points = cpuPoints, color = accent, label = "CPU (hourly avg)", unit = "%")
                    Spacer(Modifier.height(12.dp))
                    MetricLineChart(points = ramPoints, color = OmniColors.amber, label = "RAM (hourly avg)", unit = "%")
                    Spacer(Modifier.height(4.dp))
                    Text("${history.size} data points over the last 7 days", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}



@Composable
private fun StatRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
    }
}

@Composable
fun ProcessesTab(viewModel: AppViewModel, srv: ServerEntity) {
    // Real process list from `ps` over SSH; reloads on host change or sort toggle.
    LaunchedEffect(srv.id, viewModel.processSortByCpu) { viewModel.loadProcesses() }
    val simProcesses = viewModel.processes
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Column(modifier = Modifier.fillMaxSize()) {
        if (viewModel.processesLoading && simProcesses.isEmpty()) {
            Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = viewModel.processSortByCpu,
                    onClick = { viewModel.processSortByCpu = true },
                    label = { Text("↓ CPU") }
                )
                FilterChip(
                    selected = !viewModel.processSortByCpu,
                    onClick = { viewModel.processSortByCpu = false },
                    label = { Text("↓ MEM") }
                )
            }
            Text("${simProcesses.size} Procs", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            items(simProcesses) { proc ->
                val isExpanded = viewModel.expandedProcessPid == proc.pid
                OmniCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            viewModel.expandedProcessPid = if (isExpanded) null else proc.pid
                        }
                ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(proc.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 14.sp)
                                    Spacer(modifier = Modifier.width(6.dp))
                                    OmniTag(proc.state, color = if (proc.state == "R") OmniColors.green else OmniColors.cyan)
                                }
                                Text(
                                    "PID ${proc.pid} · ${proc.owner}" + (if (proc.uptime.isNotBlank()) " · up ${proc.uptime}" else ""),
                                    fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }

                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Column(horizontalAlignment = Alignment.End) {
                                    Text("${proc.cpu}%", fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (proc.cpu > 20f) Color.Red else MaterialTheme.colorScheme.onSurface)
                                    Text("CPU", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Column(horizontalAlignment = Alignment.End) {
                                    Text("${proc.mem}%", fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (proc.mem > 20f) Color.Red else MaterialTheme.colorScheme.onSurface)
                                    Text("MEM", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }

                        if (isExpanded) {
                            androidx.compose.material3.HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                            Text("Virtual Memory Size (VMS): ${proc.vms}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(modifier = Modifier.height(12.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)
                            ) {
                                OmniButton(
                                    label = "KILL -15",
                                    onClick = {
                                        confirm.ask(
                                            "Send SIGTERM?",
                                            "Gracefully terminate PID ${proc.pid} (${proc.name}) with kill -15?",
                                            confirmLabel = "Kill -15",
                                        ) {
                                            viewModel.killProcess(proc.pid, 15)
                                            viewModel.expandedProcessPid = null
                                        }
                                    },
                                    color = OmniColors.amber,
                                    small = true
                                )
                                OmniButton(
                                    label = "KILL -9",
                                    onClick = {
                                        confirm.ask(
                                            "Force kill (SIGKILL)?",
                                            "Forcibly kill PID ${proc.pid} (${proc.name}) with kill -9? Unsaved work in that process is lost.",
                                            confirmLabel = "Kill -9",
                                        ) {
                                            viewModel.killProcess(proc.pid, 9)
                                            viewModel.expandedProcessPid = null
                                        }
                                    },
                                    color = OmniColors.red,
                                    small = true
                                )
                            }
                        }
                }
            }
        }
    }
}

@Composable
fun ServicesTab(viewModel: AppViewModel, srv: ServerEntity) {
    LaunchedEffect(srv.id) { viewModel.loadServices() }
    val simServices = viewModel.services
    val serviceOutputFeedback = viewModel.serviceActionFeedback
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Column(modifier = Modifier.fillMaxSize()) {
        if (viewModel.servicesLoading && simServices.isEmpty()) {
            Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
        serviceOutputFeedback?.let {
            OmniCard(modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp), leftAccent = OmniColors.cyan) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(it, fontSize = 14.sp)
                    IconButton(onClick = { viewModel.serviceActionFeedback = null }) {
                        Icon(Icons.Filled.Close, contentDescription = null)
                    }
                }
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(simServices) { svc ->
                OmniCard(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    StatusDot(online = svc.status == "running", color = OmniColors.green, size = 8.dp)
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text(svc.name, fontWeight = FontWeight.Bold, fontSize = 16.sp, fontFamily = OmniFonts.mono)
                                }
                                Text(svc.desc, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }

                            OmniTag(
                                svc.subState,
                                color = when(svc.subState) {
                                    "active" -> OmniColors.green
                                    "failed" -> OmniColors.red
                                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                                }
                            )
                        }

                        Spacer(modifier = Modifier.height(12.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)
                        ) {
                            OmniButton(
                                label = "Restart",
                                onClick = {
                                    confirm.ask(
                                        "Restart ${svc.name}?",
                                        "Run systemctl restart on ${svc.name}? The service will briefly stop and start again.",
                                        confirmLabel = "Restart",
                                    ) { viewModel.runServiceCommand(svc.name, "restart") }
                                },
                                color = OmniColors.cyan,
                                small = true
                            )
                            if (svc.status == "running") {
                                OmniButton(
                                    label = "Stop",
                                    onClick = {
                                        confirm.ask(
                                            "Stop ${svc.name}?",
                                            "Run systemctl stop on ${svc.name}? It will remain down until started again.",
                                            confirmLabel = "Stop",
                                        ) { viewModel.runServiceCommand(svc.name, "stop") }
                                    },
                                    color = OmniColors.red,
                                    small = true
                                )
                            } else {
                                OmniButton(
                                    label = "Start",
                                    onClick = { viewModel.runServiceCommand(svc.name, "start") },
                                    color = OmniColors.green,
                                    small = true
                                )
                            }
                            if (svc.enabled) {
                                OmniButton(
                                    label = "Disable",
                                    onClick = {
                                        confirm.ask("Disable ${svc.name}?", "Stop ${svc.name} from starting at boot.", confirmLabel = "Disable") {
                                            viewModel.runServiceCommand(svc.name, "disable")
                                        }
                                    },
                                    color = OmniColors.amber, small = true
                                )
                            } else {
                                OmniButton(
                                    label = "Enable",
                                    onClick = { viewModel.runServiceCommand(svc.name, "enable") },
                                    color = OmniColors.purple, small = true
                                )
                            }
                        }
                }
            }
        }
    }
}

@Composable
fun LogsTab(viewModel: AppViewModel) {
    val loadedLogs = viewModel.logs

    // Pull real journalctl output; refresh every 5s while "LIVE" is on.
    LaunchedEffect(viewModel.selectedServerId, viewModel.logFilterType, viewModel.isLogsLive) {
        while (true) {
            viewModel.loadLogs(viewModel.logFilterType)
            if (!viewModel.isLogsLive) break
            delay(5000)
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                val filters = listOf("ALL", "INFO", "WARN", "ERROR")
                filters.forEach { flt ->
                    FilterChip(
                        selected = viewModel.logFilterType == flt,
                        onClick = { viewModel.logFilterType = flt },
                        label = { Text(flt, fontSize = 11.sp) }
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("LIVE", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Switch(
                    checked = viewModel.isLogsLive,
                    onCheckedChange = { viewModel.isLogsLive = it },
                    modifier = Modifier.padding(start = 6.dp)
                )
            }
        }

        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(Color.Black)
                .padding(8.dp)
        ) {
            items(loadedLogs) { entry ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                ) {
                    Text(
                        text = "[${entry.time}]",
                        color = Color.LightGray,
                        fontFamily = OmniFonts.mono,
                        fontSize = 11.sp,
                        modifier = Modifier.width(72.dp)
                    )
                    Text(
                        text = entry.level.padEnd(5),
                        color = when (entry.level) {
                            "ERROR" -> Color.Red
                            "WARN" -> Color(0xFFF59E0B)
                            else -> Color(0xFF14B8A6)
                        },
                        fontSize = 11.sp,
                        fontFamily = OmniFonts.mono,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.width(48.dp)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "${entry.source}: ${entry.message}",
                            color = Color.White,
                            fontFamily = OmniFonts.mono,
                            fontSize = 12.sp,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}
