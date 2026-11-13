package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.FlowRow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AlertSubjects
import com.jetsetslow.omniterm.data.SnmpDeviceEntity
import com.jetsetslow.omniterm.data.SnmpDevices
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import kotlinx.coroutines.delay

/** How often the SNMP tab polls its devices while it is open. */
private const val SNMP_TAB_POLL_MS = 30_000L

/**
 * Network → SNMP: saved devices, each polled from the phone while this tab is open, every 30
 * seconds, for its name, uptime, CPU, memory, disks, interfaces with their traffic, errors and
 * discards, and a UPS's power source and battery.
 */
@Composable
internal fun SnmpTab(viewModel: AppViewModel) {
    val devices by viewModel.snmpDevices.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<SnmpDeviceEntity?>(null) }
    var deleting by remember { mutableStateOf<SnmpDeviceEntity?>(null) }
    LaunchedEffect(devices.map { it.id to it.hashCode() }) {
        while (true) {
            devices.forEach(viewModel::pollSnmpDevice)
            delay(SNMP_TAB_POLL_MS)
        }
    }
    Column(Modifier.fillMaxSize().padding(top = 8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.snmp_intro), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            OmniButton(
                label = stringResource(R.string.snmp_add),
                onClick = { editing = SnmpDeviceEntity(name = "", host = "") },
                small = true,
                modifier = Modifier.testTag("snmp.add"),
            )
        }
        Spacer(Modifier.size(8.dp))
        if (devices.isEmpty()) {
            Text(stringResource(R.string.snmp_none), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 32.dp))
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxSize()) {
            items(devices, key = { it.id }) { device ->
                SnmpDeviceCard(
                    device,
                    viewModel.snmpReadings[device.id],
                    polling = device.id in viewModel.snmpPolling,
                    onPoll = { viewModel.pollSnmpDevice(device) },
                    onEdit = { editing = device },
                    onDelete = { deleting = device },
                    alerts = { DeviceAlertsLine(viewModel, AlertSubjects.snmp(device.id), "snmp.alerts.${device.id}") },
                )
            }
        }
    }
    editing?.let { device ->
        SnmpDeviceDialog(viewModel, device) { editing = null }
    }
    deleting?.let { device ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.snmp_delete_title, device.name)) },
            text = { Text(stringResource(R.string.snmp_delete_text)) },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteSnmpDevice(device); deleting = null }, modifier = Modifier.testTag("snmp.delete.confirm")) {
                    Text(stringResource(R.string.delete), color = OmniColors.red)
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun SnmpDeviceCard(
    device: SnmpDeviceEntity,
    reading: AppViewModel.SnmpReading?,
    polling: Boolean,
    onPoll: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    alerts: @Composable () -> Unit = {},
) {
    val outcome = reading?.outcome
    val accent = when (outcome) {
        is SnmpDevices.Outcome.Answered -> when {
            outcome.snapshot.ups?.batteryLow == true -> OmniColors.red
            outcome.snapshot.ups?.onBattery == true || outcome.snapshot.interfacesDown.isNotEmpty() -> OmniColors.amber
            else -> OmniColors.green
        }
        is SnmpDevices.Outcome.Failed -> OmniColors.red
        null -> MaterialTheme.colorScheme.outlineVariant
    }
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("snmp.device.${device.id}"), leftAccent = accent) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(device.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Text(
                        "${device.host}:${device.port} · SNMP ${if (device.version == 3) "v3" else "v2c"}",
                        fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono,
                    )
                }
                OmniButton(stringResource(R.string.snmp_poll), onPoll, small = true, enabled = !polling, modifier = Modifier.testTag("snmp.poll.${device.id}"))
                Spacer(Modifier.width(6.dp))
                OmniButton(stringResource(R.string.edit), onEdit, small = true, modifier = Modifier.testTag("snmp.edit.${device.id}"))
                Spacer(Modifier.width(6.dp))
                OmniButton(stringResource(R.string.delete), onDelete, small = true, color = OmniColors.red, modifier = Modifier.testTag("snmp.delete.${device.id}"))
            }
            alerts()
            Spacer(Modifier.size(6.dp))
            when (outcome) {
                null -> Text(stringResource(if (polling) R.string.snmp_polling else R.string.snmp_not_polled), fontSize = 12.sp, modifier = Modifier.testTag("snmp.status.${device.id}"))
                is SnmpDevices.Outcome.Failed ->
                    Text(outcome.reason, fontSize = 12.sp, color = OmniColors.red, modifier = Modifier.testTag("snmp.status.${device.id}"))
                is SnmpDevices.Outcome.Answered -> SnmpSnapshotView(device.id, outcome.snapshot, reading.rates, reading.problems)
            }
        }
    }
}

/** A UPS's state: its source, battery and time left, then its lines; amber on battery, red when low. */
@Composable
private fun UpsLines(id: Int, ups: SnmpDevices.Ups) {
    val source = when (ups.source) {
        SnmpDevices.PowerSource.MAINS -> R.string.snmp_ups_mains
        SnmpDevices.PowerSource.BATTERY -> R.string.snmp_ups_battery
        SnmpDevices.PowerSource.BYPASS -> R.string.snmp_ups_bypass
        SnmpDevices.PowerSource.OTHER -> R.string.snmp_ups_other
        null -> R.string.snmp_ups_source_unknown
    }
    val battery = when (ups.battery) {
        SnmpDevices.BatteryState.NORMAL -> R.string.snmp_battery_normal
        SnmpDevices.BatteryState.LOW -> R.string.snmp_battery_low
        SnmpDevices.BatteryState.DEPLETED -> R.string.snmp_battery_depleted
        SnmpDevices.BatteryState.FAULT -> R.string.snmp_battery_fault
        SnmpDevices.BatteryState.UNKNOWN -> null
    }
    val state = listOfNotNull(
        stringResource(source),
        ups.secondsOnBattery?.takeIf { ups.onBattery && it > 0 }?.let { stringResource(R.string.snmp_ups_on_battery_for, formatUptime(it)) },
        battery?.let { stringResource(it) },
        ups.chargePercent?.let { stringResource(R.string.snmp_ups_charge, it) },
        ups.minutesLeft?.let { stringResource(R.string.snmp_ups_minutes, it) },
    ).joinToString(" · ")
    Text(
        stringResource(R.string.snmp_ups_line, ups.model.ifBlank { "UPS" }, state),
        fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
        color = when {
            ups.batteryLow -> OmniColors.red
            ups.onBattery -> OmniColors.amber
            else -> MaterialTheme.colorScheme.onSurface
        },
        modifier = Modifier.testTag("snmp.ups.$id"),
    )
    val lines = listOfNotNull(
        ups.inputVolts.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.snmp_ups_input, it.joinToString(" / ")) },
        ups.outputVolts.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.snmp_ups_output, it.joinToString(" / ")) },
        ups.loadPercent.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.snmp_ups_load, it.joinToString(" / ")) },
    )
    if (lines.isNotEmpty()) {
        Text(lines.joinToString(" · "), fontSize = 11.sp, fontFamily = OmniFonts.mono, modifier = Modifier.testTag("snmp.ups.lines.$id"))
    }
}

/** Errors and discards on an interface that has any, each with what was added since the last poll. */
@Composable
private fun InterfaceProblems(id: Int, i: SnmpDevices.Interface, new: SnmpDevices.NewProblems?) {
    val counts = listOf(i.inErrors, i.outErrors, i.inDiscards, i.outDiscards)
    if (counts.all { (it ?: 0L) == 0L }) return
    val added = listOf(new?.inErrors, new?.outErrors, new?.inDiscards, new?.outDiscards)
    val shown = counts.zip(added) { total, plus -> (total?.toString() ?: "–") + if ((plus ?: 0L) > 0L) " (+$plus)" else "" }
    Text(
        stringResource(R.string.snmp_if_problems, shown[0], shown[1], shown[2], shown[3]),
        fontSize = 10.sp, fontFamily = OmniFonts.mono,
        color = if ((new?.errors ?: 0L) > 0L) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 12.dp).testTag("snmp.ifproblems.$id.${i.index}"),
    )
}

@Composable
private fun SnmpSnapshotView(id: Int, snap: SnmpDevices.Snapshot, rates: Map<Int, Pair<Long, Long>>, problems: Map<Int, SnmpDevices.NewProblems>) {
    val headline = listOfNotNull(
        snap.name.ifBlank { null },
        snap.uptimeSeconds?.let { stringResource(R.string.snmp_up, formatUptime(it)) },
        snap.cpuPercent?.let { stringResource(R.string.snmp_cpu, it.toInt()) },
    ).joinToString(" · ")
    Text(headline, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("snmp.status.$id"))
    if (snap.description.isNotBlank()) {
        Text(snap.description, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
    if (snap.location.isNotBlank()) Text(stringResource(R.string.snmp_location, snap.location), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    snap.ups?.let { UpsLines(id, it) }
    for (s in snap.storage) {
        val pct = s.usedPercent ?: continue
        Text(
            stringResource(R.string.snmp_storage, s.name.ifBlank { s.kind.name }, pct.toInt(), formatBytes(s.usedBytes), formatBytes(s.totalBytes)),
            fontSize = 11.sp, color = if (pct >= 90f) OmniColors.amber else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.testTag("snmp.storage.$id.${s.index}"),
        )
    }
    if (snap.interfaces.isNotEmpty()) {
        Spacer(Modifier.size(4.dp))
        val down = snap.interfacesDown.size
        Text(
            pluralStringResource(R.plurals.snmp_interfaces, snap.interfaces.size, snap.interfaces.size)
                .let { if (down > 0) stringResource(R.string.snmp_interfaces_down, it, down) else it },
            fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (down > 0) OmniColors.amber else MaterialTheme.colorScheme.onSurface,
        )
        // Down first, then the ones passing traffic; at most 24, a big switch is read in full elsewhere.
        val shown = snap.interfaces.sortedWith(compareByDescending<SnmpDevices.Interface> { it.down }.thenBy { it.operUp != true }.thenBy { it.index }).take(24)
        for (i in shown) {
            val state = when {
                i.down -> stringResource(R.string.snmp_if_down)
                i.operUp == true -> stringResource(R.string.snmp_if_up)
                i.adminUp == false -> stringResource(R.string.snmp_if_off)
                else -> stringResource(R.string.snmp_if_unknown)
            }
            val traffic = rates[i.index]?.let { (rx, tx) -> " · ↓ ${formatBytes(rx)}/s ↑ ${formatBytes(tx)}/s" }.orEmpty()
            val speed = i.speedMbps?.let { " · ${if (it >= 1000 && it % 1000 == 0L) "${it / 1000} Gb/s" else "$it Mb/s"}" }.orEmpty()
            Text(
                "${i.name}${if (i.alias.isNotBlank()) " (${i.alias})" else ""}: $state$speed$traffic",
                fontSize = 11.sp, fontFamily = OmniFonts.mono,
                color = if (i.down) OmniColors.amber else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.testTag("snmp.if.$id.${i.index}"),
            )
            InterfaceProblems(id, i, problems[i.index])
        }
    }
}

/** Adds or edits a device. Secrets are shown hidden and saved encrypted. */
@Composable
private fun SnmpDeviceDialog(viewModel: AppViewModel, start: SnmpDeviceEntity, onDone: () -> Unit) {
    var d by remember { mutableStateOf(start) }
    var portText by remember { mutableStateOf(start.port.toString()) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    fun save() {
        val port = portText.toIntOrNull() ?: 0
        // Only the chosen version's secrets are kept.
        val toSave = if (d.version == 2) d.copy(port = port, user = "", authProtocol = "", authPassword = "", privProtocol = "", privPassword = "")
        else d.copy(port = port, community = "", authPassword = d.authPassword.takeIf { d.authProtocol.isNotEmpty() }.orEmpty(),
            privPassword = d.privPassword.takeIf { d.privProtocol.isNotEmpty() }.orEmpty())
        saving = true
        viewModel.saveSnmpDevice(toSave) { problem ->
            saving = false
            if (problem == null) onDone() else error = problem
        }
    }
    DeviceFormDialog(
        stringResource(if (start.id == 0) R.string.snmp_add_title else R.string.snmp_edit_title), "snmp", error, saving, ::save, onDone,
    ) {
        NameAddressPortFields(
            d.name, { d = d.copy(name = it) }, d.host, { d = d.copy(host = it) }, portText, { portText = it },
            stringResource(R.string.snmp_address), stringResource(R.string.snmp_port), "snmp",
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FilterChip(d.version == 2, { d = d.copy(version = 2) }, label = { Text("v2c") }, modifier = Modifier.testTag("snmp.version.2"))
            FilterChip(d.version == 3, { d = d.copy(version = 3) }, label = { Text("v3") }, modifier = Modifier.testTag("snmp.version.3"))
        }
        if (d.version == 2) {
            OmniPasswordField(d.community, { d = d.copy(community = it) }, stringResource(R.string.snmp_community), Modifier.fillMaxWidth().testTag("snmp.field.community"))
        } else {
            OutlinedTextField(d.user, { d = d.copy(user = it.trim()) }, label = { Text(stringResource(R.string.snmp_user)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("snmp.field.user"))
            Text(stringResource(R.string.snmp_auth), fontSize = 12.sp)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (listOf("") + SnmpDevices.AUTH_PROTOCOLS).forEach { p ->
                    FilterChip(d.authProtocol == p, { d = d.copy(authProtocol = p, privProtocol = if (p.isEmpty()) "" else d.privProtocol) },
                        label = { Text(p.ifEmpty { stringResource(R.string.snmp_none_protocol) }) }, modifier = Modifier.testTag("snmp.auth.${p.ifEmpty { "none" }}"))
                }
            }
            if (d.authProtocol.isNotEmpty()) {
                OmniPasswordField(d.authPassword, { d = d.copy(authPassword = it) }, stringResource(R.string.snmp_auth_password), Modifier.fillMaxWidth().testTag("snmp.field.authPassword"))
                Text(stringResource(R.string.snmp_priv), fontSize = 12.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    (listOf("") + SnmpDevices.PRIV_PROTOCOLS).forEach { p ->
                        FilterChip(d.privProtocol == p, { d = d.copy(privProtocol = p) },
                            label = { Text(p.ifEmpty { stringResource(R.string.snmp_none_protocol) }) }, modifier = Modifier.testTag("snmp.priv.${p.ifEmpty { "none" }}"))
                    }
                }
                if (d.privProtocol.isNotEmpty()) {
                    OmniPasswordField(d.privPassword, { d = d.copy(privPassword = it) }, stringResource(R.string.snmp_priv_password), Modifier.fillMaxWidth().testTag("snmp.field.privPassword"))
                }
            }
        }
        TunnelChoice(viewModel, d.tunnelId, { d = d.copy(tunnelId = it) }, stringResource(R.string.snmp_tunnel_note), "snmp")
        OutlinedTextField(d.notes, { d = d.copy(notes = it) }, label = { Text(stringResource(R.string.notes_optional)) }, modifier = Modifier.fillMaxWidth())
    }
}
