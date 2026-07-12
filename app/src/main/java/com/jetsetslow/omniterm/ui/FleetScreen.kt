package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.data.*

@Composable
fun FleetScreen(viewModel: AppViewModel) {
    val srvList by viewModel.servers.collectAsStateWithLifecycle()
    val onlineSrvList = srvList.filter { it.status == "online" }
    LaunchedEffect(onlineSrvList.map { it.id }) {
        val onlineIds = onlineSrvList.mapTo(HashSet()) { it.id }
        viewModel.broadcastTargetServerIds.removeAll { it !in onlineIds }
        viewModel.fleetLogSelectedServerIds.removeAll { it !in onlineIds }
        viewModel.broadcastTargetGroups.removeAll { group ->
            onlineSrvList.none { it.groupName.orEmpty() == group }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        FleetSummaryBar(viewModel, srvList)
        TabRow(selectedTabIndex = viewModel.fleetTabIndex) {
            Tab(
                selected = viewModel.fleetTabIndex == 0,
                onClick = { viewModel.fleetTabIndex = 0 }
            ) { Text("Dashboard", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(
                selected = viewModel.fleetTabIndex == 1,
                onClick = { viewModel.fleetTabIndex = 1 }
            ) { Text("Broadcast", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(
                selected = viewModel.fleetTabIndex == 2,
                onClick = { viewModel.fleetTabIndex = 2 }
            ) { Text("Logs", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(12.dp)
        ) {
            when (viewModel.fleetTabIndex) {
                1 -> FleetBroadcastView(viewModel, onlineSrvList)
                2 -> FleetLogsView(viewModel, onlineSrvList)
                else -> FleetDashboardView(viewModel, onlineSrvList)
            }
        }
    }
}

@Composable
fun FleetSummaryBar(viewModel: AppViewModel, srvList: List<ServerEntity>) {
    val total = srvList.size
    val online = srvList.count { it.status == "online" }
    val critical = srvList.count { it.status == "online" && it.healthScore < 50 }
    val avgScore = if (srvList.isNotEmpty()) srvList.map { it.healthScore }.average().toInt() else 100

    Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("FLEET", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 16.sp, letterSpacing = 1.sp)
                Text("Avg Score: $avgScore", fontSize = 12.sp, color = OmniColors.cyan, fontWeight = FontWeight.Bold)
                Text("$online / $total Online", fontSize = 12.sp, color = if (critical > 0) OmniColors.red else OmniColors.green)
            }
            RefreshCountdown(viewModel.lastTelemetryStartMs, viewModel.telemetryIntervalMs, size = 16.dp, color = OmniColors.green)
        }
    }
}

@Composable
fun FleetDashboardView(viewModel: AppViewModel, srvList: List<ServerEntity>) {
    var scoreDialogServer by remember { mutableStateOf<ServerEntity?>(null) }
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        item {
            // Aggregate Statistics Cards
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val total = srvList.size
                val online = srvList.count { it.status == "online" }
                val critical = srvList.count { it.status == "online" && it.healthScore < 50 }
                val avgScore = if (srvList.isNotEmpty()) srvList.map { it.healthScore }.average().toInt() else 100

                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$total", label = "Hosts") }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$online", label = "Online", color = OmniColors.green) }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$critical", label = "Critical", color = if (critical > 0) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant) }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$avgScore", label = "Avg Score", color = OmniColors.cyan) }
            }
        }

        if (srvList.isEmpty()) {
            item {
                Box(Modifier.fillParentMaxSize(), contentAlignment = Alignment.Center) {
                    Text("No online hosts available. Fleet details appear when hosts come back online.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        items(srvList, key = { it.id }) { s ->
            val accentColor = getServerColor(s)
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accentColor) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                StatusDot(online = s.status == "online", color = accentColor, size = 8.dp)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(s.name, fontWeight = FontWeight.Bold, fontSize = 16.sp, fontFamily = OmniFonts.mono)
                            }
                            Text(text = "${s.username}@${s.host}:${s.port}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }

                        Box(modifier = Modifier.clickable { scoreDialogServer = s }) {
                            ScoreRing(score = if (s.status == "online") s.healthScore else 0, size = 42.dp)
                        }
                    }

                    if (s.status == "online") {
                        Spacer(modifier = Modifier.height(10.dp))
                        // Labelled CPU% line chart (axes + current value).
                        MetricLineChart(
                            points = viewModel.fetchCachedSparkline(s.id),
                            color = accentColor,
                            label = "CPU",
                            unit = "%",
                        )

                        // Short macro run triggers that execute and navigate directly to Broadcast Tab output
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            val targetLabelAction = listOf("Uptime" to "uptime", "DF" to "df -h", "PS" to "ps aux | head -5")
                            targetLabelAction.forEach { (lbl, cmd) ->
                                OmniButton(
                                    label = lbl,
                                    onClick = {
                                        viewModel.broadcastTargetMode = FleetTargetMode.Servers
                                        viewModel.broadcastTargetGroups.clear()
                                        viewModel.broadcastTargetServerIds.clear()
                                        viewModel.broadcastTargetServerIds.add(s.id)
                                        viewModel.broadcastCommandText = cmd
                                        viewModel.runFleetBroadcast(cmd, resolvedIds = listOf(s.id))
                                    },
                                    color = accentColor,
                                    small = true
                                )
                            }
                        }
                    }

                    Spacer(modifier = Modifier.height(12.dp))
                    val upHours = ((viewModel.hostMetricsById[s.id]?.uptimeSeconds ?: 0L) / 3600L).toInt()
                    val haveData = s.status == "online" && upHours > 0
                    // Derived from the host's reported kernel uptime (= time since last boot). We can
                    // place the boot/reboot within the window; earlier than that is genuinely unknown
                    // (we weren't observing). No fabricated 24/7 history, no always-on app needed.
                    Text(
                        if (haveData) (if (upHours >= 24) "24H UPTIME · up >24h" else "24H UPTIME · booted ${upHours}h ago")
                        else "24H UPTIME · no data",
                        fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        repeat(24) { i ->
                            // i = 0 is 24h ago … 23 is the current hour.
                            val hoursAgo = 23 - i
                            val color = when {
                                !haveData -> Color.Gray.copy(alpha = 0.25f)              // unknown
                                upHours > hoursAgo -> Color(0xFF10B981).copy(alpha = 0.85f) // up this hour
                                upHours == hoursAgo -> OmniColors.amber.copy(alpha = 0.8f)  // booted this hour
                                else -> Color.Gray.copy(alpha = 0.25f)                    // before boot: unknown
                            }
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(10.dp)
                                    .clip(RoundedCornerShape(1f.dp))
                                    .background(color)
                            )
                        }
                    }
            }
        }
    }
    scoreDialogServer?.let { s ->
        HealthBreakdownDialog(viewModel, s) { scoreDialogServer = null }
    }
}

@Composable
fun FleetBroadcastView(viewModel: AppViewModel, srvList: List<ServerEntity>) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val quickScripts by viewModel.quickScripts.collectAsStateWithLifecycle()
    var confirmClearOutputs by remember { mutableStateOf(false) }
    var showPresetPicker by remember { mutableStateOf(false) }
    var showPresetEditor by remember { mutableStateOf(false) }
    var presetSearch by remember { mutableStateOf("") }
    val commandPresets = quickScripts
        .filter { it.availableForFleet }
        .sortedWith(compareBy<QuickScriptEntity> { it.sortOrder }.thenBy { it.name.lowercase() })
    val filteredPresets = commandPresets.filter { preset ->
        val query = presetSearch.trim()
        query.isBlank() ||
            preset.name.contains(query, ignoreCase = true) ||
            preset.command.contains(query, ignoreCase = true)
    }
    val groups = srvList.mapNotNull { it.groupName?.takeIf { group -> group.isNotBlank() } }.distinct().sorted()
    val selectedTargetCount = when (viewModel.broadcastTargetMode) {
        FleetTargetMode.Servers -> viewModel.broadcastTargetServerIds.size
        FleetTargetMode.Groups -> srvList.count { it.status == "online" && it.groupName.orEmpty() in viewModel.broadcastTargetGroups }
    }
    var controlsExpanded by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        viewModel.seedFleetPresetsIfMissing()
    }
    LaunchedEffect(viewModel.broadcastResults.size) {
        if (viewModel.broadcastResults.isNotEmpty()) controlsExpanded = false
    }

    fun openPresetEditor() {
        showPresetPicker = false
        showPresetEditor = true
    }

    // Snapshot the targets at tap time, show exactly what will run where, and execute that exact
    // list on confirm — group membership/online status is not re-resolved after the dialog.
    fun confirmAndRunBroadcast() {
        val cmd = viewModel.broadcastCommandText.trim()
        if (cmd.isBlank() || viewModel.isBroadcastExecuting) return
        val targets = when (viewModel.broadcastTargetMode) {
            FleetTargetMode.Servers -> srvList.filter { it.id in viewModel.broadcastTargetServerIds }
            FleetTargetMode.Groups -> srvList.filter { it.status == "online" && it.groupName.orEmpty() in viewModel.broadcastTargetGroups }
        }
        if (targets.isEmpty()) return
        val danger = fleetCommandDangerWarning(cmd)
        confirm.ask(
            title = "Run on ${targets.size} host${if (targets.size == 1) "" else "s"}?",
            message = buildString {
                appendLine("$ $cmd")
                appendLine()
                targets.forEach { appendLine("• ${it.name} (${it.username}@${it.host})") }
                if (danger != null) {
                    appendLine()
                    append("⚠ $danger")
                }
            }.trimEnd(),
            confirmLabel = "Run",
            destructive = danger != null,
        ) {
            viewModel.runFleetBroadcast(cmd, targets.map { it.id })
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Broadcast controls", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    "$selectedTargetCount target(s) · ${if (viewModel.broadcastCommandText.isBlank()) "no command" else viewModel.broadcastCommandText}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = { controlsExpanded = !controlsExpanded }) {
                Icon(
                    if (controlsExpanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = if (controlsExpanded) "Collapse controls" else "Expand controls",
                )
            }
        }

        if (controlsExpanded) {
            BroadcastTargetPicker(viewModel, srvList, groups)

            Spacer(modifier = Modifier.height(8.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(
                    onClick = {
                        presetSearch = ""
                        showPresetPicker = true
                    },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.Search, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Presets")
                }
                OutlinedButton(
                    enabled = viewModel.broadcastCommandText.isNotBlank(),
                    onClick = { openPresetEditor() },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Save")
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            // Monospace code CLI line prefix text entry block
            OutlinedTextField(
                value = viewModel.broadcastCommandText,
                onValueChange = { viewModel.broadcastCommandText = it },
                placeholder = { Text("Enter bash command script here...") },
                prefix = { Text("$ ", fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold) },
                textStyle = LocalTextStyle.current.copy(fontFamily = OmniFonts.mono, fontSize = 14.sp),
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                shape = RoundedCornerShape(8.dp),
                colors = omniTextFieldColors()
            )

            Spacer(modifier = Modifier.height(12.dp))

            // Parallel executor actions buttons
            OmniButton(
                label = if (viewModel.isBroadcastExecuting) "STOP BROADCAST" else "RUN ON $selectedTargetCount HOSTS",
                onClick = { if (viewModel.isBroadcastExecuting) viewModel.stopFleetBroadcast() else confirmAndRunBroadcast() },
                modifier = Modifier.fillMaxWidth(),
                color = if (viewModel.isBroadcastExecuting) OmniColors.red else OmniColors.cyan
            )
        } else {
            OmniButton(
                label = if (viewModel.isBroadcastExecuting) "STOP" else "RUN $selectedTargetCount",
                onClick = { if (viewModel.isBroadcastExecuting) viewModel.stopFleetBroadcast() else confirmAndRunBroadcast() },
                modifier = Modifier.fillMaxWidth(),
                color = if (viewModel.isBroadcastExecuting) OmniColors.red else OmniColors.cyan,
                small = true,
            )
        }

        Spacer(modifier = Modifier.height(8.dp))

        // Terminal text nodes feed displaying returned parallel response packages
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text("Execution outputs", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (viewModel.broadcastResults.isNotEmpty() && !viewModel.isBroadcastExecuting) {
                Text(
                    "Clear Outputs",
                    fontSize = 11.sp,
                    color = Color.Red,
                    modifier = Modifier.clickable { confirmClearOutputs = true }
                )
            }
        }

        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(top = 6.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            items(viewModel.broadcastResults, key = { it.serverId }) { item ->
                val accent = when (item.status) {
                    BroadcastStatus.Running -> OmniColors.cyan
                    BroadcastStatus.Success -> OmniColors.green
                    BroadcastStatus.Failure -> OmniColors.red
                }
                var expanded by remember(item.serverId) { mutableStateOf(true) }
                val outScroll = rememberScrollState()
                LaunchedEffect(item.output, expanded) {
                    if (expanded) outScroll.scrollTo(outScroll.maxValue)
                }
                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.hostColor(item.serverName)) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp).clickable { expanded = !expanded },
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                                Icon(
                                    if (expanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    contentDescription = if (expanded) "Collapse output" else "Expand output",
                                    tint = MaterialTheme.colorScheme.primary,
                                )
                                Text(item.serverName, fontWeight = FontWeight.Bold, fontSize = 14.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.primary)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                if (item.status == BroadcastStatus.Running) {
                                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = accent)
                                }
                                Text(
                                    when (item.status) {
                                        BroadcastStatus.Running -> "streaming"
                                        BroadcastStatus.Success -> "complete"
                                        BroadcastStatus.Failure -> "failed"
                                    },
                                    fontSize = 10.sp,
                                    color = accent,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                        if (expanded) {
                            SelectionContainer {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 72.dp, max = 260.dp)
                                        .background(Color.Black)
                                        .verticalScroll(outScroll)
                                        .padding(8.dp)
                                ) {
                                    Text(
                                        text = buildString {
                                            if (item.truncated) append("[Output truncated; showing latest ${120_000} characters]\n")
                                            append(item.output.ifBlank {
                                                if (item.status == BroadcastStatus.Running) "Waiting for output..." else "Done (no output)"
                                            })
                                        },
                                        fontFamily = OmniFonts.mono,
                                        fontSize = 12.sp,
                                        color = Color.White
                                    )
                                }
                            }
                        }
                }
            }
        }
    }

    if (showPresetPicker) {
        AlertDialog(
            onDismissRequest = { showPresetPicker = false },
            title = {
                Text("Choose fleet script")
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = presetSearch,
                        onValueChange = { presetSearch = it },
                        label = { Text("Search presets") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (filteredPresets.isEmpty()) {
                        Text(
                            if (commandPresets.isEmpty()) "No fleet presets saved yet." else "No presets match your search.",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        LazyColumn(
                            modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            items(filteredPresets, key = { it.id }) { preset ->
                                ListItem(
                                    headlineContent = {
                                        Text("${preset.emoji} ${preset.name}", fontWeight = FontWeight.Bold)
                                    },
                                    supportingContent = {
                                        Text(
                                            preset.command,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                            fontFamily = OmniFonts.mono,
                                            fontSize = 11.sp,
                                        )
                                    },
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .clickable {
                                            viewModel.broadcastCommandText = preset.command
                                            showPresetPicker = false
                                        },
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showPresetPicker = false }) { Text("Close") }
            },
        )
    }

    if (showPresetEditor) {
        SharedScriptEditorDialog(
            existing = null,
            title = "Save script",
            initialCommand = viewModel.broadcastCommandText,
            initialCategory = "Fleet",
            defaultAvailableForQuick = false,
            defaultAvailableForFleet = true,
            onDismiss = { showPresetEditor = false },
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
                    notes = draft.notes,
                )
                showPresetEditor = false
            },
        )
    }

    if (confirmClearOutputs) {
        AlertDialog(
            onDismissRequest = { confirmClearOutputs = false },
            title = { Text("Clear broadcast output?") },
            text = { Text("This clears the visible Fleet broadcast output history.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.broadcastResults.clear()
                        confirmClearOutputs = false
                    }
                ) { Text("Clear", color = Color.Red) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearOutputs = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun BroadcastTargetPicker(viewModel: AppViewModel, srvList: List<ServerEntity>, groups: List<String>) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(8.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Broadcast Targets", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = viewModel.broadcastTargetMode == FleetTargetMode.Servers,
                    onClick = { viewModel.broadcastTargetMode = FleetTargetMode.Servers },
                    label = { Text("Servers", fontSize = 11.sp) },
                )
                FilterChip(
                    selected = viewModel.broadcastTargetMode == FleetTargetMode.Groups,
                    onClick = { viewModel.broadcastTargetMode = FleetTargetMode.Groups },
                    label = { Text("Groups", fontSize = 11.sp) },
                )
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            Text(
                if (viewModel.broadcastTargetMode == FleetTargetMode.Servers) "All Online" else "All Groups",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable {
                    if (viewModel.broadcastTargetMode == FleetTargetMode.Servers) {
                        viewModel.broadcastTargetServerIds.clear()
                        viewModel.broadcastTargetServerIds.addAll(srvList.filter { it.status == "online" }.map { it.id })
                    } else {
                        viewModel.broadcastTargetGroups.clear()
                        viewModel.broadcastTargetGroups.addAll(groups)
                    }
                }
            )
            Spacer(Modifier.width(12.dp))
            Text(
                "Clear",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = Color.Red,
                modifier = Modifier.clickable {
                    viewModel.broadcastTargetServerIds.clear()
                    viewModel.broadcastTargetGroups.clear()
                }
            )
        }

        if (viewModel.broadcastTargetMode == FleetTargetMode.Servers) {
            // A dialog picker instead of a horizontal chip strip: with more than a few hosts the
            // strip hides most of the fleet offscreen, so selection state becomes invisible.
            HostPickerField(
                label = "Target hosts",
                servers = srvList,
                selectedIds = viewModel.broadcastTargetServerIds.toSet(),
                onToggle = { id ->
                    if (!viewModel.broadcastTargetServerIds.remove(id)) viewModel.broadcastTargetServerIds.add(id)
                },
                isSelectable = { it.status == "online" },
                onSelectAll = {
                    viewModel.broadcastTargetServerIds.clear()
                    viewModel.broadcastTargetServerIds.addAll(srvList.filter { it.status == "online" }.map { it.id })
                },
                onClear = { viewModel.broadcastTargetServerIds.clear() },
                modifier = Modifier.padding(top = 4.dp),
            )
        } else {
            // Groups stay as chips (there are few of them), but wrapped so all remain visible.
            @OptIn(ExperimentalLayoutApi::class)
            FlowRow(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                groups.forEach { group ->
                    val isChecked = viewModel.broadcastTargetGroups.contains(group)
                    ElevatedFilterChip(
                        selected = isChecked,
                        onClick = {
                            if (isChecked) viewModel.broadcastTargetGroups.remove(group) else viewModel.broadcastTargetGroups.add(group)
                        },
                        label = {
                            Text("$group (${srvList.count { it.status == "online" && it.groupName == group }})", fontFamily = OmniFonts.mono, fontSize = 11.sp)
                        },
                    )
                }
            }
        }
    }
}

@Composable
fun StatBox(value: String, label: String, tint: Color = MaterialTheme.colorScheme.onSurface, modifier: Modifier = Modifier) {
    OmniCard(modifier = modifier) { OmniStatBox(value = value, label = label, color = tint) }
}

/**
 * Compact line chart with a labelled Y axis (0..[maxY]), baseline gridlines, the current value,
 * and an oldest→newest X caption — so the trend reads clearly instead of being a bare line.
 */
@Composable
fun MetricLineChart(
    points: List<Float>,
    modifier: Modifier = Modifier,
    color: Color = OmniColors.cyan,
    label: String = "CPU",
    unit: String = "%",
    maxY: Float = 100f,
) {
    val axisColor = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("$label · ${points.size} samples", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
            Text(
                points.lastOrNull()?.let { "${it.toInt()}$unit" } ?: "—",
                fontSize = 10.sp, color = color, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(2.dp))
        Row(Modifier.fillMaxWidth().height(56.dp)) {
            Column(
                Modifier.fillMaxHeight().width(28.dp).padding(end = 4.dp),
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("${maxY.toInt()}", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
                Text("${(maxY / 2).toInt()}", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
                Text("0", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
            }
            Canvas(Modifier.fillMaxHeight().weight(1f)) {
                // Baseline gridlines at 0 / 50 / 100.
                listOf(0f, 0.5f, 1f).forEach { f ->
                    val y = size.height * f
                    drawLine(OmniColors.border, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                }
                if (points.size > 1) {
                    val path = Path()
                    val dx = size.width / (points.size - 1)
                    points.forEachIndexed { i, p ->
                        val x = i * dx
                        val y = size.height - (p / maxY).coerceIn(0f, 1f) * size.height
                        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                    }
                    drawPath(path, color = color, style = Stroke(width = 1.5.dp.toPx()))
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 28.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("oldest", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
            Text("now", fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
        }
    }
}

@Composable
fun FleetLogsView(viewModel: AppViewModel, srvList: List<ServerEntity>) {
    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Select hosts then tap Fetch Logs:", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        HostPickerField(
            label = "Log hosts",
            servers = srvList,
            selectedIds = viewModel.fleetLogSelectedServerIds.toSet(),
            onToggle = { viewModel.toggleFleetLogServer(it) },
            onSelectAll = {
                viewModel.fleetLogSelectedServerIds.clear()
                viewModel.fleetLogSelectedServerIds.addAll(srvList.map { it.id })
            },
            onClear = { viewModel.fleetLogSelectedServerIds.clear() },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OmniButton(
                label = if (viewModel.isFleetLogsLoading) "Loading…" else "Fetch Logs",
                onClick = { if (!viewModel.isFleetLogsLoading) viewModel.loadFleetLogs() },
                color = OmniColors.cyan,
            )
            if (viewModel.fleetLogs.isNotEmpty()) {
                Text("${viewModel.fleetLogs.size} entries", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        val logs = viewModel.fleetLogs
        if (logs.isEmpty() && !viewModel.isFleetLogsLoading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No logs. Select hosts and tap Fetch Logs.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(logs) { entry ->
                    val levelColor = when (entry.level) {
                        "ERROR" -> OmniColors.red
                        "WARN" -> OmniColors.amber
                        else -> MaterialTheme.colorScheme.onSurface
                    }
                    OmniCard(modifier = Modifier.fillMaxWidth()) {
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Column(modifier = Modifier.weight(1f)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(entry.serverName, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = OmniColors.cyan)
                                    Text(entry.timestamp, fontSize = 10.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text(
                                    entry.message,
                                    fontSize = 11.sp,
                                    fontFamily = OmniFonts.mono,
                                    color = levelColor,
                                    maxLines = 3,
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

/**
 * Heuristic check for commands that commonly destroy data or take hosts down. Returns a warning
 * string for the broadcast confirmation dialog, or null when nothing suspicious matched. This is
 * a guard rail, not a sandbox — an empty result does not mean the command is safe.
 */
internal fun fleetCommandDangerWarning(command: String): String? {
    val hits = commandDangerHits(command)
    if (hits.isEmpty()) return null
    return "This command looks destructive (${hits.joinToString(", ")}) and will run on every host listed above."
}

/** The matched danger labels for [command] (empty when nothing suspicious matched). */
internal fun commandDangerHits(command: String): List<String> {
    val patterns = listOf(
        Regex("""\brm\s+(-+\w*[rfRF]\w*\s+)+""") to "recursive/forced delete",
        Regex("""\b(mkfs|wipefs|blkdiscard|mkswap)\b""") to "filesystem format/wipe",
        Regex("""\b(fdisk|parted|sgdisk|sfdisk)\b""") to "partition table changes",
        Regex("""\bdd\s+\S*of=""") to "raw write with dd",
        Regex(""">+\s*/dev/(sd|nvme|mmcblk|vd|hd)""") to "writing directly to a block device",
        Regex("""\b(shutdown|poweroff|halt)\b""") to "host shutdown",
        Regex("""\breboot\b|\binit\s+[06]\b|\bsystemctl\s+(reboot|poweroff|halt|kexec|emergency|rescue)\b""") to "host reboot/shutdown",
        Regex("""\b(userdel|groupdel)\b""") to "account deletion",
        Regex("""\biptables\s+(-\w+\s+)*-F\b|\bnft\s+flush\b|\bufw\s+disable\b""") to "firewall teardown",
        Regex("""\bchmod\s+(-\w+\s+)*[0-7]*777\s+/\S*""") to "world-writable permission change",
        Regex(""":\s*\(\s*\)\s*\{""") to "fork bomb",
        Regex("""\btruncate\s+(-\w+\s+)*-s\s*0\b""") to "file truncation",
    )
    return patterns.mapNotNull { (re, label) -> label.takeIf { re.containsMatchIn(command) } }.distinct()
}
