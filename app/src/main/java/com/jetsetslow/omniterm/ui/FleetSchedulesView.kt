package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.UnattendedScripts
import com.jetsetslow.omniterm.ui.theme.OmniColors
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

/**
 * Fleet's Schedules tab: each schedule with when it runs next and how its last run went, a switch
 * to pause it, Run now, and its editor. Its runs are in Broadcast's history as Scheduled.
 *
 * Idea credit: Termix's Automations (scheduled runs across hosts).
 */
@Composable
internal fun FleetSchedulesView(viewModel: AppViewModel, allHosts: List<ServerEntity>) {
    val schedules by viewModel.fleetSchedules.collectAsStateWithLifecycle()
    val scripts by viewModel.quickScripts.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<FleetScheduleEntity?>(null) }
    var deleting by remember { mutableStateOf<FleetScheduleEntity?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val started = stringResource(R.string.fleet_schedule_started)
    val notStarted = stringResource(R.string.fleet_schedule_not_started)

    LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxSize().testTag("fleet.schedules")) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.fleet_schedules_intro), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton(
                    onClick = { editing = FleetScheduleEntity(name = "", scriptId = 0, mode = viewModel.broadcastTargets.mode.name) },
                    modifier = Modifier.testTag("fleet.schedules.new"),
                ) {
                    Icon(Icons.Default.Add, contentDescription = null)
                    Text(stringResource(R.string.fleet_schedule_new))
                }
                notice?.let { Text(it, fontSize = 12.sp, color = OmniColors.cyan, modifier = Modifier.testTag("fleet.schedules.notice")) }
                if (schedules.isEmpty()) {
                    Text(stringResource(R.string.fleet_schedules_empty), fontSize = 12.sp, modifier = Modifier.testTag("fleet.schedules.empty"))
                }
            }
        }
        items(schedules, key = { it.id }) { schedule ->
            FleetScheduleCard(
                viewModel, schedule, scripts.firstOrNull { it.id == schedule.scriptId }, allHosts,
                onRunNow = { notice = if (viewModel.runFleetScheduleNow(schedule.id)) started else notStarted },
                onEdit = { editing = schedule },
                onDelete = { deleting = schedule },
            )
        }
    }

    editing?.let { schedule ->
        FleetScheduleEditor(
            viewModel, schedule, scripts.filter { it.availableForFleet || it.id == schedule.scriptId }, allHosts,
            onDismiss = { editing = null },
        )
    }
    deleting?.let { schedule ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.fleet_schedule_delete_title)) },
            text = { Text(stringResource(R.string.fleet_schedule_delete_body, schedule.name)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteFleetSchedule(schedule.id)
                        deleting = null
                    },
                    modifier = Modifier.testTag("fleet.schedule.delete.confirm"),
                ) { Text(stringResource(R.string.delete), color = OmniColors.red) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun FleetScheduleCard(
    viewModel: AppViewModel,
    schedule: FleetScheduleEntity,
    script: QuickScriptEntity?,
    allHosts: List<ServerEntity>,
    onRunNow: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val tag = "fleet.schedule.${schedule.id}"
    val toggleLabel = stringResource(R.string.fleet_schedule_toggle_cd, schedule.name)
    OmniCard(modifier = Modifier.fillMaxWidth().testTag(tag), leftAccent = if (schedule.enabled) OmniColors.cyan else null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(schedule.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                Text(
                    script?.name ?: stringResource(R.string.fleet_schedule_script_gone),
                    fontSize = 12.sp,
                    color = if (script == null) OmniColors.red else MaterialTheme.colorScheme.onSurface,
                )
                Text(scheduleTiming(schedule), fontSize = 12.sp, modifier = Modifier.testTag("$tag.timing"))
                Text(
                    savedTargetsSummary(FleetTargets.of(schedule), allHosts),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (!schedule.enabled) stringResource(R.string.fleet_schedule_off)
                    else schedule.nextRunAt?.let { stringResource(R.string.fleet_schedule_next, formatShortDateTime(it)) }.orEmpty(),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("$tag.next"),
                )
            }
            Switch(
                checked = schedule.enabled,
                onCheckedChange = { viewModel.setFleetScheduleEnabled(schedule.id, it) },
                modifier = Modifier.testTag("$tag.toggle").semantics { contentDescription = toggleLabel },
            )
        }
        Row {
            TextButton(onClick = onRunNow, modifier = Modifier.testTag("$tag.run")) { Text(stringResource(R.string.fleet_schedule_run_now)) }
            TextButton(onClick = onEdit, modifier = Modifier.testTag("$tag.edit")) { Text(stringResource(R.string.edit)) }
            TextButton(onClick = onDelete, modifier = Modifier.testTag("$tag.delete")) { Text(stringResource(R.string.delete)) }
        }
        val lastAt = schedule.lastRunAt
        val lastOutcome = schedule.lastOutcome
        if (lastAt != null && lastOutcome != null) {
            Text(stringResource(R.string.fleet_schedule_last), fontSize = 11.sp, fontWeight = FontWeight.Bold)
            TokenUseRow(lastAt, lastOutcome, schedule.lastDetail, schedule.lastRunKey, viewModel::openFleetRun, tag = "$tag.last")
        }
    }
}

/** When [schedule] runs, in a line: "Every 30 minutes", "Every day at 03:00", "Every Monday at 03:00". */
@Composable
internal fun scheduleTiming(schedule: FleetScheduleEntity): String {
    val time = FleetScheduleTiming.formatTime(schedule.minuteOfDay)
    return when (schedule.repeat) {
        FleetScheduleTiming.EVERY -> schedule.everyMinutes.let { minutes ->
            if (minutes % 60 == 0) pluralStringResource(R.plurals.fleet_schedule_every_hours, minutes / 60, minutes / 60)
            else pluralStringResource(R.plurals.fleet_schedule_every_minutes, minutes, minutes)
        }
        FleetScheduleTiming.WEEKLY -> stringResource(R.string.fleet_schedule_weekly_at, dayName(schedule.dayOfWeek, TextStyle.FULL), time)
        else -> stringResource(R.string.fleet_schedule_daily_at, time)
    }
}

private fun dayName(day: Int, style: TextStyle): String = DayOfWeek.of(day.coerceIn(1, 7)).getDisplayName(style, Locale.getDefault())

/**
 * A schedule's editor: its name, its script (one that may run with nobody there), its hosts
 * (Broadcast's picks or a saved set, taken when it is saved), when it repeats, and its notification.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FleetScheduleEditor(
    viewModel: AppViewModel,
    initial: FleetScheduleEntity,
    scripts: List<QuickScriptEntity>,
    allHosts: List<ServerEntity>,
    onDismiss: () -> Unit,
) {
    val sets by viewModel.fleetTargetSets.collectAsStateWithLifecycle()
    var name by remember { mutableStateOf(initial.name) }
    var scriptId by remember { mutableStateOf(initial.scriptId) }
    var targets by remember {
        mutableStateOf(if (initial.id == 0) viewModel.broadcastTargets else FleetTargets.of(initial))
    }
    var repeat by remember { mutableStateOf(initial.repeat) }
    var everyMinutes by remember { mutableStateOf(initial.everyMinutes) }
    var timeText by remember { mutableStateOf(FleetScheduleTiming.formatTime(initial.minuteOfDay)) }
    var dayOfWeek by remember { mutableStateOf(initial.dayOfWeek) }
    var notify by remember { mutableStateOf(RunNotify.of(initial.notify)) }
    var pickingScript by remember { mutableStateOf(false) }

    val script = scripts.firstOrNull { it.id == scriptId }
    val problem = script?.let { UnattendedScripts.problem(it, commandDangerHits(it.command), UnattendedScripts.Runner.SCHEDULE) }
    val minuteOfDay = FleetScheduleTiming.parseTime(timeText)
    val needsTime = repeat != FleetScheduleTiming.EVERY
    val hostsNow = allHosts.count(targets::matches)
    val canSave = name.isNotBlank() && script != null && problem == null && !targets.isEmpty && (!needsTime || minuteOfDay != null)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (initial.id == 0) R.string.fleet_schedule_new else R.string.fleet_schedule_edit_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(FleetTargets.MAX_NAME) },
                    label = { Text(stringResource(R.string.fleet_schedule_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("fleet.schedule.name"),
                )

                Text(stringResource(R.string.fleet_schedule_script), fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Box {
                    OutlinedButton(onClick = { pickingScript = true }, modifier = Modifier.fillMaxWidth().testTag("fleet.schedule.script")) {
                        Text(script?.name ?: stringResource(R.string.fleet_schedule_pick_script), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    DropdownMenu(expanded = pickingScript, onDismissRequest = { pickingScript = false }) {
                        scripts.forEach { s ->
                            DropdownMenuItem(
                                text = { Text(s.name) },
                                onClick = {
                                    scriptId = s.id
                                    pickingScript = false
                                },
                                modifier = Modifier.testTag("fleet.schedule.script.${s.id}"),
                            )
                        }
                    }
                }
                problem?.let { Text(it, fontSize = 12.sp, color = OmniColors.amber, modifier = Modifier.testTag("fleet.schedule.problem")) }
                Text(stringResource(R.string.fleet_schedules_unattended), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

                Text(stringResource(R.string.fleet_schedule_hosts), fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Text(
                    if (targets.isEmpty) stringResource(R.string.fleet_schedule_no_targets)
                    else pluralStringResource(R.plurals.fleet_schedule_hosts_now, hostsNow, savedTargetsSummary(targets, allHosts), hostsNow),
                    fontSize = 12.sp,
                    modifier = Modifier.testTag("fleet.schedule.targets"),
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val broadcast = viewModel.broadcastTargets
                    AssistChip(
                        onClick = { targets = broadcast },
                        enabled = !broadcast.isEmpty,
                        label = { Text(stringResource(R.string.fleet_schedule_use_broadcast), fontSize = 12.sp) },
                        modifier = Modifier.testTag("fleet.schedule.targets.broadcast"),
                    )
                    sets.forEach { set ->
                        AssistChip(
                            onClick = { targets = FleetTargets.of(set) },
                            label = { Text(set.name, fontSize = 12.sp) },
                            modifier = Modifier.testTag("fleet.schedule.targets.set.${set.id}"),
                        )
                    }
                }
                Text(stringResource(R.string.fleet_schedule_hosts_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

                Text(stringResource(R.string.fleet_schedule_repeat), fontWeight = FontWeight.Bold, fontSize = 13.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (choice in FleetScheduleTiming.REPEATS) {
                        FilterChip(
                            selected = repeat == choice,
                            onClick = { repeat = choice },
                            label = {
                                Text(
                                    stringResource(
                                        when (choice) {
                                            FleetScheduleTiming.EVERY -> R.string.fleet_schedule_repeat_every
                                            FleetScheduleTiming.WEEKLY -> R.string.fleet_schedule_repeat_weekly
                                            else -> R.string.fleet_schedule_repeat_daily
                                        },
                                    ),
                                    fontSize = 12.sp,
                                )
                            },
                            modifier = Modifier.testTag("fleet.schedule.repeat.$choice"),
                        )
                    }
                }
                if (repeat == FleetScheduleTiming.EVERY) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (minutes in FleetScheduleTiming.EVERY_MINUTES) {
                            FilterChip(
                                selected = everyMinutes == minutes,
                                onClick = { everyMinutes = minutes },
                                label = {
                                    Text(
                                        if (minutes % 60 == 0) stringResource(R.string.fleet_schedule_hours, minutes / 60)
                                        else stringResource(R.string.fleet_schedule_minutes, minutes),
                                        fontSize = 12.sp,
                                    )
                                },
                                modifier = Modifier.testTag("fleet.schedule.every.$minutes"),
                            )
                        }
                    }
                } else {
                    if (repeat == FleetScheduleTiming.WEEKLY) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            for (day in 1..7) {
                                FilterChip(
                                    selected = dayOfWeek == day,
                                    onClick = { dayOfWeek = day },
                                    label = { Text(dayName(day, TextStyle.SHORT), fontSize = 12.sp) },
                                    modifier = Modifier.testTag("fleet.schedule.day.$day"),
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = timeText,
                        onValueChange = { timeText = it.take(5) },
                        label = { Text(stringResource(R.string.fleet_schedule_time)) },
                        isError = minuteOfDay == null,
                        supportingText = if (minuteOfDay == null) {
                            { Text(stringResource(R.string.fleet_schedule_time_invalid)) }
                        } else null,
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("fleet.schedule.time"),
                    )
                }
                Text(stringResource(R.string.fleet_schedules_timing_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)

                RunNotifyPicker(notify, { notify = it }, "fleet.schedule.notify")
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    viewModel.saveFleetSchedule(
                        initial.copy(
                            name = name,
                            scriptId = scriptId,
                            repeat = repeat,
                            everyMinutes = everyMinutes,
                            minuteOfDay = minuteOfDay ?: initial.minuteOfDay,
                            dayOfWeek = dayOfWeek,
                            notify = notify,
                        ),
                        targets,
                    )
                    onDismiss()
                },
                enabled = canSave,
                modifier = Modifier.testTag("fleet.schedule.save"),
            ) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
