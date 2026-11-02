package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.ui.platform.LocalDensity
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
import androidx.compose.ui.platform.testTag
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
import androidx.compose.ui.res.stringResource
import com.jetsetslow.omniterm.R

@Composable
fun FleetScreen(viewModel: AppViewModel) {
    val srvList by viewModel.servers.collectAsStateWithLifecycle()
    val onlineSrvList = srvList.filter { viewModel.isPickableHost(it) }
    // Broadcast picks survive a host going offline, which is skipped until it is back; dropping it
    // meant a brief drop silently shrank the next run. Only a removed host or group leaves the picks.
    LaunchedEffect(srvList.map { it.id to it.groupName }) {
        val ids = srvList.mapTo(HashSet()) { it.id }
        viewModel.broadcastTargetServerIds.removeAll { it !in ids }
        viewModel.broadcastTargetGroups.removeAll { group ->
            srvList.none { it.groupName.orEmpty() == group }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        if (!typingInLandscape()) {
            FleetSummaryBar(viewModel, srvList)
            PrimaryTabRow(selectedTabIndex = viewModel.fleetTabIndex) {
                Tab(
                    selected = viewModel.fleetTabIndex == 0,
                    onClick = { viewModel.fleetTabIndex = 0 }
                ) { Text(stringResource(R.string.dashboard), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
                Tab(
                    selected = viewModel.fleetTabIndex == 1,
                    onClick = { viewModel.fleetTabIndex = 1 }
                ) { Text(stringResource(R.string.broadcast), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(12.dp)
        ) {
            when (viewModel.fleetTabIndex) {
                1 -> FleetBroadcastView(viewModel, onlineSrvList, allHosts = srvList)
                else -> FleetDashboardView(viewModel, onlineSrvList, allHosts = srvList)
            }
        }
    }
}

/** Host counts for the fleet summary; [avgScore] is -1 while no host has a health score. */
private data class FleetTotals(val total: Int, val online: Int, val critical: Int, val avgScore: Int)

private fun fleetTotals(viewModel: AppViewModel, srvList: List<ServerEntity>) = FleetTotals(
    total = srvList.size,
    online = srvList.count { it.status == "online" },
    critical = srvList.count { it.status == "online" && viewModel.currentHealthScore(it) in 0..49 },
    avgScore = srvList.map { viewModel.currentHealthScore(it) }.filter { it >= 0 }.takeIf { it.isNotEmpty() }?.average()?.toInt() ?: -1,
)

@Composable
fun FleetSummaryBar(viewModel: AppViewModel, srvList: List<ServerEntity>) {
    val (total, online, critical, avgScore) = fleetTotals(viewModel, srvList)

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
                Text(stringResource(R.string.fleet_2), fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 16.sp, letterSpacing = 1.sp)
                Text(stringResource(R.string.avg_score, if (avgScore < 0) "—" else avgScore), fontSize = 12.sp, color = OmniColors.cyan, fontWeight = FontWeight.Bold)
                Text(stringResource(R.string.online_2, online, total), fontSize = 12.sp, color = if (critical > 0) OmniColors.red else OmniColors.green)
            }
            RefreshCountdown(viewModel.lastTelemetryStartMs, viewModel.telemetryIntervalMs, size = 16.dp, color = OmniColors.green)
        }
    }
}

/** Fleet's dashboard: cards for the online hosts in [srvList], and totals over [allHosts]. */
@Composable
fun FleetDashboardView(viewModel: AppViewModel, srvList: List<ServerEntity>, allHosts: List<ServerEntity>) {
    var scoreDialogServer by remember { mutableStateOf<ServerEntity?>(null) }
    OverflowLazyColumn(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        item {
            // Aggregate Statistics Cards
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val (total, online, critical, avgScore) = fleetTotals(viewModel, allHosts)

                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$total", label = stringResource(R.string.hosts)) }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$online", label = stringResource(R.string.online_3), color = OmniColors.green) }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = "$critical", label = stringResource(R.string.critical), color = if (critical > 0) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant) }
                OmniCard(modifier = Modifier.weight(1f)) { OmniStatBox(value = if (avgScore < 0) "—" else "$avgScore", label = stringResource(R.string.avg_score_2), color = OmniColors.cyan) }
            }
        }

        if (srvList.isEmpty()) {
            item {
                Box(Modifier.fillParentMaxSize(), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.no_online_hosts_available_fleet_details), color = MaterialTheme.colorScheme.onSurfaceVariant)
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
                            Text(text = "${HostDisplay.userAtHost(s)}:${s.port}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }

                        Box(modifier = Modifier.clickable { scoreDialogServer = s }) {
                            ScoreRing(score = viewModel.currentHealthScore(s), size = 42.dp)
                        }
                    }

                    if (s.status == "online") {
                        Spacer(modifier = Modifier.height(10.dp))
                        // Labelled CPU% line chart (axes + current value).
                        MetricLineChart(
                            points = viewModel.fetchCachedSparkline(s.id),
                            timestamps = viewModel.fetchCachedSparklineTimestamps(s.id),
                            color = accentColor,
                            label = stringResource(R.string.cpu_2),
                            unit = "%",
                        )

                        // Single-host diagnostics have their own visible output; never overwrite Broadcast.
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            RemoteCommands.QuickCheck.entries.forEach { check ->
                                OmniButton(
                                    label = check.label,
                                    modifier = Modifier.testTag("fleet.host.${s.id}.${check.label.lowercase()}"),
                                    onClick = { viewModel.runQuickCheck(s, check) },
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
fun FleetBroadcastView(viewModel: AppViewModel, srvList: List<ServerEntity>, allHosts: List<ServerEntity> = srvList) {
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
    // A picked group stays listed while all its hosts are offline, so it can be unpicked.
    val groups = (srvList.mapNotNull { it.groupName?.takeIf { group -> group.isNotBlank() } } + viewModel.broadcastTargetGroups)
        .distinct().sorted()
    // Picked hosts that are offline right now: they stay picked, and a run skips them.
    val offlinePicks = allHosts.filter { host ->
        !viewModel.isPickableHost(host) && when (viewModel.broadcastTargetMode) {
            FleetTargetMode.Servers -> host.id in viewModel.broadcastTargetServerIds
            FleetTargetMode.Groups -> host.groupName.orEmpty() in viewModel.broadcastTargetGroups
        }
    }
    val selectedTargetCount = when (viewModel.broadcastTargetMode) {
        FleetTargetMode.Servers -> srvList.count { it.id in viewModel.broadcastTargetServerIds }
        FleetTargetMode.Groups -> srvList.count { viewModel.isPickableHost(it) && it.groupName.orEmpty() in viewModel.broadcastTargetGroups }
    }
    // Stop always works; Run needs a command and at least one online target.
    val canRunOrStop = viewModel.isBroadcastExecuting ||
        (viewModel.broadcastCommandText.isNotBlank() && selectedTargetCount > 0)
    val dismissKeyboard = rememberDismissKeyboard()
    var controlsExpanded by remember { mutableStateOf(true) }

    LaunchedEffect(viewModel.broadcastResults.size) {
        if (viewModel.broadcastResults.isNotEmpty()) controlsExpanded = false
    }

    // Expanded output cards, by server id. Cards start collapsed, so a run on many hosts shows every
    // host's status at once and a card opens only when its output is wanted. Held here, not per
    // item: LazyColumn drops item state once a card scrolls out of view, which would collapse a card
    // the user opened as soon as they scrolled. Held only while Broadcast is shown, so coming back
    // from another tab or screen finds every card collapsed again. Only the user tapping a card
    // header writes to it.
    val expandedOutputs = remember { mutableStateMapOf<Int, Boolean>() }

    // A new broadcast, or cleared outputs, starts every card collapsed again.
    LaunchedEffect(viewModel.isBroadcastExecuting, viewModel.broadcastResults.isEmpty()) {
        if (viewModel.isBroadcastExecuting || viewModel.broadcastResults.isEmpty()) {
            expandedOutputs.clear()
        }
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
        dismissKeyboard()
        val targets = when (viewModel.broadcastTargetMode) {
            FleetTargetMode.Servers -> srvList.filter { it.id in viewModel.broadcastTargetServerIds }
            FleetTargetMode.Groups -> srvList.filter { viewModel.isPickableHost(it) && it.groupName.orEmpty() in viewModel.broadcastTargetGroups }
        }
        if (targets.isEmpty()) return
        val skipped = offlinePicks
        val danger = fleetCommandDangerWarning(cmd)
        confirm.ask(
            title = confirm.str(R.string.run_on_host, targets.size, if (targets.size == 1) "" else "s"),
            message = buildString {
                appendLine("$ $cmd")
                appendLine()
                targets.forEach { appendLine("• ${HostDisplay.name(it)} (${HostDisplay.userAtHost(it)})") }
                if (skipped.isNotEmpty()) {
                    appendLine()
                    appendLine(confirm.str(R.string.broadcast_skipped_offline, skipped.joinToString(", ") { HostDisplay.name(it) }))
                }
                appendLine()
                appendLine(confirm.str(if (viewModel.broadcastInTmux) R.string.broadcast_tmux_confirm else R.string.broadcast_drop_warning))
                if (danger != null) {
                    appendLine()
                    append("⚠ $danger")
                }
            }.trimEnd(),
            confirmLabel = confirm.str(R.string.run),
            destructive = danger != null,
        ) {
            viewModel.runFleetBroadcast(cmd, targets.map { it.id })
        }
    }

    // The inputs stay above an output list that scrolls on its own, and scroll themselves within the
    // room the outputs leave. Run stays outside them, so it is never scrolled away or left under the
    // keyboard or the ad banner. Below a usable height (the keyboard open in a short window) the tab
    // becomes one scrolling page with a fixed-height output pane, and Run sits at its foot.
    val header = @Composable {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.broadcast_controls), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    stringResource(R.string.target_s, selectedTargetCount, if (viewModel.broadcastCommandText.isBlank()) "no command" else viewModel.broadcastCommandText),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = { controlsExpanded = !controlsExpanded }) {
                Icon(
                    if (controlsExpanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = if (controlsExpanded) stringResource(R.string.collapse_controls) else stringResource(R.string.expand_controls),
                )
            }
        }
    }
    val inputs = @Composable {
        BroadcastTargetPicker(viewModel, srvList, groups, offlinePicks)

        Spacer(modifier = Modifier.height(8.dp))

        OutlinedTextField(
            value = viewModel.broadcastCommandText,
            onValueChange = { viewModel.broadcastCommandText = it },
            label = { Text(stringResource(R.string.command)) },
            placeholder = { Text(stringResource(R.string.enter_bash_command_script_here)) },
            prefix = { Text("$ ", fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold) },
            textStyle = LocalTextStyle.current.copy(fontFamily = OmniFonts.mono, fontSize = 14.sp),
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            shape = RoundedCornerShape(8.dp),
            colors = omniTextFieldColors()
        )
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.run_in_tmux), fontWeight = FontWeight.Bold)
                Text(
                    stringResource(R.string.run_in_tmux_explained),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = viewModel.broadcastInTmux,
                onCheckedChange = viewModel::updateBroadcastInTmux,
                enabled = !viewModel.isBroadcastExecuting,
                modifier = Modifier.testTag("fleet.broadcast.tmux"),
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        Text(stringResource(R.string.command_presets), fontWeight = FontWeight.Bold)
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
                Text(stringResource(R.string.presets))
            }
            OutlinedButton(
                enabled = viewModel.broadcastCommandText.isNotBlank(),
                onClick = { openPresetEditor() },
                modifier = Modifier.weight(1f),
            ) {
                Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.save_command))
            }
        }
    }
    val runButton = @Composable {
        if (controlsExpanded) {
            OmniButton(
                label = if (viewModel.isBroadcastExecuting) "STOP BROADCAST" else "RUN ON $selectedTargetCount HOSTS",
                onClick = { if (viewModel.isBroadcastExecuting) viewModel.stopFleetBroadcast() else confirmAndRunBroadcast() },
                modifier = Modifier.fillMaxWidth().testTag("fleet.broadcast.run"),
                color = if (viewModel.isBroadcastExecuting) OmniColors.red else OmniColors.cyan,
                enabled = canRunOrStop,
            )
        } else {
            OmniButton(
                label = if (viewModel.isBroadcastExecuting) "STOP" else "RUN $selectedTargetCount",
                onClick = { if (viewModel.isBroadcastExecuting) viewModel.stopFleetBroadcast() else confirmAndRunBroadcast() },
                modifier = Modifier.fillMaxWidth().testTag("fleet.broadcast.run"),
                color = if (viewModel.isBroadcastExecuting) OmniColors.red else OmniColors.cyan,
                small = true,
                enabled = canRunOrStop,
            )
        }
    }
    val outputsHeader = @Composable {
        // Terminal text nodes feed displaying returned parallel response packages
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.execution_outputs), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (viewModel.broadcastResults.isNotEmpty() && !viewModel.isBroadcastExecuting) {
                Text(stringResource(R.string.clear_outputs),
                    fontSize = 11.sp,
                    color = Color.Red,
                    modifier = Modifier.clickable { confirmClearOutputs = true }
                )
            }
        }
    }
    val outputs = @Composable { modifier: Modifier ->
        OverflowLazyColumn(
            modifier = modifier.fillMaxWidth().padding(top = 6.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            items(viewModel.broadcastResults, key = { it.serverId }) { item ->
                val accent = when (item.status) {
                    BroadcastStatus.Running -> OmniColors.cyan
                    BroadcastStatus.Success -> OmniColors.green
                    BroadcastStatus.Failure -> OmniColors.red
                    BroadcastStatus.Reconnecting, BroadcastStatus.Detached, BroadcastStatus.NeedsTmux -> OmniColors.amber
                }
                val expanded = expandedOutputs[item.serverId] == true
                OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = hostAccent(allHosts, item.serverId)) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp)
                                .clickable { expandedOutputs[item.serverId] = !expanded },
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                                Icon(
                                    if (expanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    contentDescription = if (expanded) stringResource(R.string.collapse_output) else stringResource(R.string.expand_output),
                                    tint = MaterialTheme.colorScheme.primary,
                                )
                                Text(item.serverName, fontWeight = FontWeight.Bold, fontSize = 14.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.primary)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                if (item.status == BroadcastStatus.Running || item.status == BroadcastStatus.Reconnecting) {
                                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = accent)
                                }
                                Text(
                                    when (item.status) {
                                        BroadcastStatus.Running -> "streaming"
                                        BroadcastStatus.Success -> "complete"
                                        BroadcastStatus.Failure -> "failed"
                                        BroadcastStatus.Reconnecting -> "reconnecting"
                                        BroadcastStatus.Detached -> "disconnected"
                                        BroadcastStatus.NeedsTmux -> "needs tmux"
                                    },
                                    fontSize = 10.sp,
                                    color = accent,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                        if (expanded) {
                            StreamOutputBox(
                                buildString {
                                    if (item.truncated) append("[Output truncated; showing latest ${120_000} characters]\n")
                                    append(item.output.ifBlank {
                                        when (item.status) {
                                            BroadcastStatus.Running, BroadcastStatus.Reconnecting -> "Waiting for output..."
                                            BroadcastStatus.Success -> "Done (no output)"
                                            else -> "No output"
                                        }
                                    })
                                },
                                modifier = Modifier.heightIn(min = 72.dp, max = 260.dp),
                                look = StreamOutputLook.Terminal,
                                fontSize = 12.sp,
                            )
                        }
                        BroadcastHostFooter(viewModel, item, accent)
                }
            }
        }
    }
    val pageScroll = rememberScrollState()
    val inputsScroll = rememberScrollState()
    val fontScale = LocalDensity.current.fontScale.coerceIn(1f, 2f)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // The headers and Run grow with the text size, so the room kept for them grows too.
        val inputsMaxHeight = (maxHeight - 210.dp * fontScale).coerceAtLeast(0.dp)
        // Opening the keyboard switches between the two, so they share one tree and differ only in
        // modifiers: rebuilding the focused command field would drop focus and close the keyboard.
        val onePage = maxHeight < 320.dp
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).then(if (onePage) Modifier.verticalScrollWithIndicators(pageScroll) else Modifier)) {
                header()
                if (controlsExpanded) {
                    Column(
                        if (onePage) Modifier else
                            Modifier.heightIn(max = inputsMaxHeight).verticalScrollWithIndicators(inputsScroll),
                    ) {
                        inputs()
                    }
                }
                if (!onePage) {
                    if (controlsExpanded) Spacer(modifier = Modifier.height(20.dp))
                    runButton()
                }
                Spacer(modifier = Modifier.height(8.dp))
                outputsHeader()
                outputs(if (onePage) Modifier.height(160.dp) else Modifier.weight(1f))
            }
            if (onePage) {
                Spacer(modifier = Modifier.height(8.dp))
                runButton()
            }
        }
    }

    if (showPresetPicker) {
        AlertDialog(
            onDismissRequest = { showPresetPicker = false },
            title = {
                Text(stringResource(R.string.choose_fleet_script))
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = presetSearch,
                        onValueChange = { presetSearch = it },
                        label = { Text(stringResource(R.string.search_presets)) },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (filteredPresets.isEmpty()) {
                        Text(
                            if (commandPresets.isEmpty()) stringResource(R.string.no_fleet_presets_saved_yet) else stringResource(R.string.no_presets_match_your_search),
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        OverflowLazyColumn(
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
                TextButton(onClick = { showPresetPicker = false }) { Text(stringResource(R.string.close)) }
            },
        )
    }

    if (showPresetEditor) {
        SharedScriptEditorDialog(
            existing = null,
            title = stringResource(R.string.save_script),
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
            title = { Text(stringResource(R.string.clear_broadcast_output)) },
            text = { Text(stringResource(R.string.this_clears_the_visible_fleet_broadcast)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.broadcastResults.clear()
                        confirmClearOutputs = false
                    }
                ) { Text(stringResource(R.string.clear), color = Color.Red) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearOutputs = false }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@Composable
private fun BroadcastTargetPicker(
    viewModel: AppViewModel,
    srvList: List<ServerEntity>,
    groups: List<String>,
    offlinePicks: List<ServerEntity>,
) {
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
            Text(stringResource(R.string.broadcast_targets), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = viewModel.broadcastTargetMode == FleetTargetMode.Servers,
                    onClick = { viewModel.broadcastTargetMode = FleetTargetMode.Servers },
                    label = { Text(stringResource(R.string.servers), fontSize = 11.sp) },
                )
                FilterChip(
                    selected = viewModel.broadcastTargetMode == FleetTargetMode.Groups,
                    onClick = { viewModel.broadcastTargetMode = FleetTargetMode.Groups },
                    label = { Text(stringResource(R.string.groups), fontSize = 11.sp) },
                )
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            Text(
                if (viewModel.broadcastTargetMode == FleetTargetMode.Servers) stringResource(R.string.all_online) else stringResource(R.string.all_groups),
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable {
                    if (viewModel.broadcastTargetMode == FleetTargetMode.Servers) {
                        viewModel.broadcastTargetServerIds.clear()
                        viewModel.broadcastTargetServerIds.addAll(srvList.filter { viewModel.isPickableHost(it) }.map { it.id })
                    } else {
                        viewModel.broadcastTargetGroups.clear()
                        viewModel.broadcastTargetGroups.addAll(groups)
                    }
                }
            )
            Spacer(Modifier.width(12.dp))
            Text(stringResource(R.string.clear),
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
                label = stringResource(R.string.target_hosts),
                servers = srvList + offlinePicks,
                selectedIds = viewModel.broadcastTargetServerIds.toSet(),
                onToggle = { id ->
                    if (!viewModel.broadcastTargetServerIds.remove(id)) viewModel.broadcastTargetServerIds.add(id)
                },
                isSelectable = { viewModel.isPickableHost(it) },
                onSelectAll = {
                    viewModel.broadcastTargetServerIds.clear()
                    viewModel.broadcastTargetServerIds.addAll(srvList.filter { viewModel.isPickableHost(it) }.map { it.id })
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
                            Text("$group (${srvList.count { viewModel.isPickableHost(it) && it.groupName == group }})", fontFamily = OmniFonts.mono, fontSize = 11.sp)
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
 * and real endpoint timestamps — so the trend reads clearly instead of being a bare line.
 */
@Composable
fun MetricLineChart(
    points: List<Float>,
    timestamps: List<Long> = emptyList(),
    modifier: Modifier = Modifier,
    color: Color = OmniColors.cyan,
    label: String = "CPU",
    unit: String = "%",
    maxY: Float = 100f,
) {
    val axisColor = MaterialTheme.colorScheme.onSurfaceVariant
    val endpointLabels = remember(timestamps) { chartEndpointLabels(timestamps) }
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            // "1 samples" is the first thing shown after connecting to a host, which is exactly
            // when someone is deciding whether this app is careful.
            Text(
                "$label · ${points.size} ${if (points.size == 1) "sample" else "samples"}",
                fontSize = 10.sp,
                color = axisColor,
                fontFamily = OmniFonts.mono,
            )
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
            Text(endpointLabels.first, fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
            Text(endpointLabels.second, fontSize = 10.sp, color = axisColor, fontFamily = OmniFonts.mono)
        }
    }
}

/**
 * Under a broadcast card's output: why the host ended as it did or what it waits for, and what can
 * be done about it (reconnect to a dropped tmux run, attach to a running one, or deal with a host
 * that has no tmux).
 */
@Composable
private fun BroadcastHostFooter(viewModel: AppViewModel, item: BroadcastResultItem, accent: Color) {
    item.note?.let {
        Text(
            it,
            fontSize = 11.sp,
            color = accent,
            modifier = Modifier.padding(top = 6.dp).testTag("fleet.broadcast.${item.serverId}.note"),
        )
    }
    val actions = buildList {
        when (item.status) {
            BroadcastStatus.Reconnecting -> add(stringResource(R.string.reconnect_now) to { viewModel.reconnectBroadcastHost(item.serverId) })
            BroadcastStatus.Detached -> add(stringResource(R.string.reconnect) to { viewModel.reconnectBroadcastHost(item.serverId) })
            BroadcastStatus.Running -> if (item.tmuxRunId != null) {
                add(stringResource(R.string.attach) to { viewModel.attachBroadcastTmux(item.serverId) })
            }
            BroadcastStatus.NeedsTmux -> {
                add(stringResource(R.string.install_tool, "tmux") to { viewModel.installTmuxForBroadcast(item.serverId) })
                add(stringResource(R.string.run_without_tmux) to { viewModel.runBroadcastHostWithoutTmux(item.serverId) })
            }
            BroadcastStatus.Success, BroadcastStatus.Failure -> Unit
        }
    }
    if (actions.isNotEmpty()) {
        Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            actions.forEach { (label, onClick) -> OmniButton(label = label, onClick = onClick, color = accent, small = true) }
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
        // `[^;&|\n]*` rather than `\S*`: `\S*` cannot cross a space, so it only reached an `of=`
        // inside the same token. `dd if=/dev/zero of=/dev/sda` — the textbook disk-destroyer, and
        // the way every tutorial writes it — was the one form this did not catch.
        Regex("""\bdd\s+[^;&|\n]*of=""") to "raw write with dd",
        Regex(""">+\s*/dev/(sd|nvme|mmcblk|vd|hd)""") to "writing directly to a block device",
        Regex("""\b(shutdown|poweroff|halt)\b""") to "host shutdown",
        Regex("""\breboot\b|\binit\s+[06]\b|\bsystemctl\s+(reboot|poweroff|halt|kexec|emergency|rescue)\b""") to "host reboot/shutdown",
        Regex("""\b(userdel|groupdel)\b""") to "account deletion",
        // Same shape: `(-\w+\s+)*` stops at the first non-flag token, so `iptables -t nat -F`
        // slipped through because `nat` is not a flag.
        Regex("""\biptables\s+[^;&|\n]*-F\b|\bnft\s+flush\b|\bufw\s+disable\b""") to "firewall teardown",
        Regex("""\bchmod\s+(-\w+\s+)*[0-7]*777\s+/\S*""") to "world-writable permission change",
        Regex(""":\s*\(\s*\)\s*\{""") to "fork bomb",
        Regex("""\btruncate\s+(-\w+\s+)*-s\s*0\b""") to "file truncation",
    )
    return patterns.mapNotNull { (re, label) -> label.takeIf { re.containsMatchIn(command) } }.distinct()
}
