package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.Proxmox
import com.jetsetslow.omniterm.data.ProxmoxApi
import com.jetsetslow.omniterm.data.ProxmoxServerEntity
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import java.text.DateFormat
import java.util.Date

/**
 * Tools → Proxmox VE: saved servers, each read over its API when the screen opens and on Refresh.
 * Guest power and snapshot actions run only from here, when the person holding the phone taps them;
 * Stop, Shut down, Reboot, Roll back and Delete ask first and name the guest.
 */
@Composable
fun ProxmoxToolView(viewModel: AppViewModel) {
    val servers by viewModel.proxmoxServers.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<ProxmoxServerEntity?>(null) }
    var guest by remember { mutableStateOf<Pair<ProxmoxServerEntity, Proxmox.Guest>?>(null) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    ToolScaffold(viewModel, stringResource(R.string.proxmox_title)) {
        ToolCardColumn {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.proxmox_intro), fontSize = 13.sp)
                    OmniButton(
                        stringResource(R.string.proxmox_add),
                        { editing = ProxmoxServerEntity(name = "", host = "") },
                        small = true,
                        modifier = Modifier.testTag("proxmox.add"),
                    )
                }
            }
            if (servers.isEmpty()) Text(stringResource(R.string.proxmox_none), fontSize = 13.sp, modifier = Modifier.padding(4.dp))
            servers.forEach { server ->
                ProxmoxServerCard(
                    viewModel, server,
                    onEdit = { editing = server },
                    onDelete = {
                        confirm.ask(
                            confirm.str(R.string.proxmox_delete_title, server.name),
                            confirm.str(R.string.proxmox_delete_text),
                            confirmLabel = confirm.str(R.string.remove),
                        ) { viewModel.deleteProxmoxServer(server) }
                    },
                    onGuest = { guest = server to it },
                )
            }
        }
    }
    editing?.let { ProxmoxServerDialog(viewModel, it) { editing = null } }
    guest?.let { (server, g) ->
        // The guest as last read, so its state follows a power action.
        val current = viewModel.proxmoxViews[server.id]?.overview?.guests?.firstOrNull { it.key == g.key } ?: g
        ProxmoxGuestDialog(viewModel, server, current, confirm) { guest = null }
    }
}

@Composable
private fun ProxmoxServerCard(
    viewModel: AppViewModel,
    server: ProxmoxServerEntity,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onGuest: (Proxmox.Guest) -> Unit,
) {
    val view = viewModel.proxmoxViews[server.id]
    LaunchedEffect(server) { viewModel.refreshProxmox(server) }
    val accent = when {
        view?.untrusted != null -> OmniColors.amber
        view?.error != null -> OmniColors.red
        view?.overview != null -> OmniColors.green
        else -> MaterialTheme.colorScheme.outlineVariant
    }
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("proxmox.server.${server.id}"), leftAccent = accent) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(server.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Text("${server.host}:${server.port} · ${server.tokenId}", fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                OmniButton(stringResource(R.string.proxmox_refresh), { viewModel.refreshProxmox(server) }, small = true, enabled = view?.loading != true, modifier = Modifier.testTag("proxmox.refresh.${server.id}"))
                Spacer(Modifier.width(6.dp))
                OmniButton(stringResource(R.string.edit), onEdit, small = true, modifier = Modifier.testTag("proxmox.edit.${server.id}"))
                Spacer(Modifier.width(6.dp))
                OmniButton(stringResource(R.string.delete), onDelete, small = true, color = OmniColors.red, modifier = Modifier.testTag("proxmox.delete.${server.id}"))
            }
            val untrusted = view?.untrusted
            when {
                untrusted != null -> {
                    Text(stringResource(R.string.proxmox_trust_title), fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                    Text(
                        stringResource(if (untrusted.changed) R.string.proxmox_trust_changed else R.string.proxmox_trust_new, server.host),
                        fontSize = 12.sp, color = if (untrusted.changed) OmniColors.red else MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.testTag("proxmox.status.${server.id}"),
                    )
                    SelectionContainer {
                        Text(untrusted.fingerprint, fontSize = 11.sp, fontFamily = OmniFonts.mono, modifier = Modifier.testTag("proxmox.fingerprint.${server.id}"))
                    }
                    OmniButton(
                        stringResource(R.string.proxmox_trust),
                        { viewModel.trustProxmoxCertificate(server, untrusted.fingerprint) },
                        small = true, color = if (untrusted.changed) OmniColors.red else OmniColors.cyan,
                        modifier = Modifier.testTag("proxmox.trust.${server.id}"),
                    )
                }
                view?.error != null -> Text(view.error, fontSize = 12.sp, color = OmniColors.red, modifier = Modifier.testTag("proxmox.status.${server.id}"))
                view?.overview == null -> Text(stringResource(R.string.proxmox_loading), fontSize = 12.sp, modifier = Modifier.testTag("proxmox.status.${server.id}"))
            }
            view?.overview?.let { ProxmoxOverviewView(server.id, it, onGuest) }
        }
    }
}

@Composable
private fun ProxmoxOverviewView(id: Int, overview: Proxmox.Overview, onGuest: (Proxmox.Guest) -> Unit) {
    Text(stringResource(R.string.proxmox_version, overview.version), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("proxmox.version.$id"))
    for (n in overview.nodes) {
        val parts = listOfNotNull(
            stringResource(if (n.online) R.string.proxmox_online else R.string.proxmox_offline),
            n.cpu?.let { stringResource(R.string.proxmox_cpu, (it * 100).toInt()) },
            if (n.memUsed != null && n.memTotal != null) stringResource(R.string.proxmox_mem, formatBytes(n.memUsed), formatBytes(n.memTotal)) else null,
            n.uptime?.takeIf { it > 0 }?.let { stringResource(R.string.proxmox_up, formatUptime(it)) },
        )
        Text(
            stringResource(R.string.proxmox_node_line, n.name, parts.joinToString(" · ")),
            fontSize = 11.sp, fontFamily = OmniFonts.mono, color = if (n.online) MaterialTheme.colorScheme.onSurface else OmniColors.red,
            modifier = Modifier.testTag("proxmox.node.$id.${n.name}"),
        )
    }
    Spacer(Modifier.size(4.dp))
    Text(stringResource(R.string.proxmox_guests), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    if (overview.guests.isEmpty()) Text(stringResource(R.string.proxmox_no_guests), fontSize = 11.sp)
    for (g in overview.guests) {
        Text(
            guestLine(g),
            fontSize = 12.sp, fontFamily = OmniFonts.mono,
            color = if (g.running) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().clickable { onGuest(g) }.padding(vertical = 4.dp).testTag("proxmox.guest.$id.${g.vmid}"),
        )
    }
    Spacer(Modifier.size(4.dp))
    Text(stringResource(R.string.proxmox_backups), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    if (overview.backups.isEmpty()) Text(stringResource(R.string.proxmox_no_backups), fontSize = 11.sp)
    overview.backups.forEachIndexed { i, t ->
        val result = when {
            t.running -> stringResource(R.string.proxmox_backup_running)
            else -> t.status
        }
        val guests = overview.runs.firstOrNull { it.task.upid == t.upid }?.guests?.keys?.sorted().orEmpty()
        val what = t.id.ifBlank { if (guests.isEmpty()) stringResource(R.string.proxmox_backup_all) else guests.joinToString(", ") }
        val at = t.start?.let { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it * 1000)) }.orEmpty()
        Text(
            "$what · $result · $at · ${t.node}",
            fontSize = 11.sp, fontFamily = OmniFonts.mono,
            color = when {
                t.running -> MaterialTheme.colorScheme.onSurface
                t.ok -> OmniColors.green
                else -> OmniColors.red
            },
            modifier = Modifier.testTag("proxmox.backup.$id.$i"),
        )
    }
}

@Composable
private fun guestLine(g: Proxmox.Guest): String {
    val parts = listOfNotNull(
        g.label,
        if (g.template) stringResource(R.string.proxmox_template) else g.status,
        g.cpu?.takeIf { g.running }?.let { stringResource(R.string.proxmox_cpu, (it * 100).toInt()) },
        if (g.running && g.memUsed != null && g.memTotal != null) stringResource(R.string.proxmox_mem, formatBytes(g.memUsed), formatBytes(g.memTotal)) else null,
        g.uptime?.takeIf { g.running && it > 0 }?.let { stringResource(R.string.proxmox_up, formatUptime(it)) },
        g.node,
    )
    return parts.joinToString(" · ")
}

/** One guest: its power actions and snapshots. */
@Composable
private fun ProxmoxGuestDialog(viewModel: AppViewModel, server: ProxmoxServerEntity, guest: Proxmox.Guest, confirm: ConfirmController, onDone: () -> Unit) {
    var snapshots by remember { mutableStateOf<List<Proxmox.Snapshot>?>(null) }
    var snapshotsError by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    var newName by remember { mutableStateOf("") }
    var newDescription by remember { mutableStateOf("") }
    var reload by remember { mutableStateOf(0) }
    val doneText = stringResource(R.string.proxmox_done)
    LaunchedEffect(guest.key, reload) {
        viewModel.proxmoxSnapshots(server, guest) { r ->
            r.onSuccess { snapshots = it; snapshotsError = null }.onFailure { snapshotsError = it.message }
        }
    }
    val busy = viewModel.proxmoxBusy
    fun run(busyText: String, action: suspend ProxmoxApi.() -> String) {
        result = null
        viewModel.proxmoxAction(server, busyText, action) { failed ->
            result = if (failed == null) true to doneText else false to failed
            reload++
        }
    }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(guest.label) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(guestLine(guest), fontSize = 11.sp, fontFamily = OmniFonts.mono, modifier = Modifier.testTag("proxmox.guest.status"))
                if (!guest.template) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        val enabled = busy == null
                        if (!guest.running) {
                            OmniButton(stringResource(R.string.proxmox_start), {
                                run(confirm.str(R.string.proxmox_starting, guest.label)) { power(guest, Proxmox.Power.START) }
                            }, small = true, enabled = enabled, modifier = Modifier.testTag("proxmox.power.start"))
                        } else {
                            OmniButton(stringResource(R.string.proxmox_shutdown), {
                                confirm.ask(confirm.str(R.string.proxmox_shutdown_title, guest.label), confirm.str(R.string.proxmox_shutdown_text),
                                    confirmLabel = confirm.str(R.string.proxmox_shutdown), destructive = false) {
                                    run(confirm.str(R.string.proxmox_shutting_down, guest.label)) { power(guest, Proxmox.Power.SHUTDOWN) }
                                }
                            }, small = true, enabled = enabled, modifier = Modifier.testTag("proxmox.power.shutdown"))
                            OmniButton(stringResource(R.string.proxmox_reboot), {
                                confirm.ask(confirm.str(R.string.proxmox_reboot_title, guest.label), confirm.str(R.string.proxmox_reboot_text),
                                    confirmLabel = confirm.str(R.string.proxmox_reboot), destructive = false) {
                                    run(confirm.str(R.string.proxmox_rebooting, guest.label)) { power(guest, Proxmox.Power.REBOOT) }
                                }
                            }, small = true, enabled = enabled, modifier = Modifier.testTag("proxmox.power.reboot"))
                            OmniButton(stringResource(R.string.proxmox_stop), {
                                confirm.ask(confirm.str(R.string.proxmox_stop_title, guest.label), confirm.str(R.string.proxmox_stop_text),
                                    confirmLabel = confirm.str(R.string.proxmox_stop)) {
                                    run(confirm.str(R.string.proxmox_stopping, guest.label)) { power(guest, Proxmox.Power.STOP) }
                                }
                            }, small = true, color = OmniColors.red, enabled = enabled, modifier = Modifier.testTag("proxmox.power.stop"))
                        }
                    }
                }
                busy?.let { Text(it, fontSize = 12.sp, modifier = Modifier.testTag("proxmox.busy")) }
                result?.let { (ok, text) ->
                    Text(text, fontSize = 12.sp, color = if (ok) OmniColors.green else OmniColors.red, modifier = Modifier.testTag("proxmox.result"))
                }
                Spacer(Modifier.size(4.dp))
                Text(stringResource(R.string.proxmox_snapshots), fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                snapshotsError?.let { Text(it, fontSize = 12.sp, color = OmniColors.red, modifier = Modifier.testTag("proxmox.snap.error")) }
                val list = snapshots
                if (list != null && list.isEmpty()) Text(stringResource(R.string.proxmox_no_snapshots), fontSize = 12.sp)
                list?.forEach { s ->
                    val at = s.time?.let { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it * 1000)) }.orEmpty()
                    Column(Modifier.fillMaxWidth().testTag("proxmox.snap.${s.name}")) {
                        Text(s.name, fontSize = 12.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.SemiBold)
                        Text(listOf(at, s.description).filter { it.isNotBlank() }.joinToString(" · "), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Row {
                            OmniButton(stringResource(R.string.proxmox_rollback), {
                                confirm.ask(confirm.str(R.string.proxmox_rollback_title, guest.label, s.name), confirm.str(R.string.proxmox_rollback_text),
                                    confirmLabel = confirm.str(R.string.proxmox_rollback)) {
                                    run(confirm.str(R.string.proxmox_rolling_back, guest.label, s.name)) { rollback(guest, s.name) }
                                }
                            }, small = true, color = OmniColors.amber, enabled = busy == null, modifier = Modifier.testTag("proxmox.snap.rollback.${s.name}"))
                            Spacer(Modifier.width(6.dp))
                            OmniButton(stringResource(R.string.delete), {
                                confirm.ask(confirm.str(R.string.proxmox_delete_snapshot_title, guest.label, s.name), confirm.str(R.string.proxmox_delete_snapshot_text),
                                    confirmLabel = confirm.str(R.string.delete)) {
                                    run(confirm.str(R.string.proxmox_deleting_snapshot, guest.label, s.name)) { deleteSnapshot(guest, s.name) }
                                }
                            }, small = true, color = OmniColors.red, enabled = busy == null, modifier = Modifier.testTag("proxmox.snap.delete.${s.name}"))
                        }
                    }
                }
                if (!guest.template) {
                    OutlinedTextField(newName, { newName = it.trim() }, label = { Text(stringResource(R.string.proxmox_snapshot_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("proxmox.snap.name"))
                    OutlinedTextField(newDescription, { newDescription = it }, label = { Text(stringResource(R.string.proxmox_snapshot_description)) }, modifier = Modifier.fillMaxWidth().testTag("proxmox.snap.description"))
                    val nameProblem = newName.takeIf { it.isNotEmpty() }?.let(Proxmox::snapshotNameProblem)
                    nameProblem?.let { Text(it, fontSize = 11.sp, color = OmniColors.amber) }
                    OmniButton(stringResource(R.string.proxmox_take_snapshot), {
                        val name = newName
                        val description = newDescription
                        run(confirm.str(R.string.proxmox_taking_snapshot, guest.label, name)) { createSnapshot(guest, name, description) }
                        newName = ""
                        newDescription = ""
                    }, small = true, enabled = busy == null && newName.isNotEmpty() && nameProblem == null, modifier = Modifier.testTag("proxmox.snap.take"))
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone, modifier = Modifier.testTag("proxmox.guest.close")) { Text(stringResource(R.string.close)) } },
    )
}

/** Adds or edits a server. The token's secret is shown hidden and saved encrypted. */
@Composable
private fun ProxmoxServerDialog(viewModel: AppViewModel, start: ProxmoxServerEntity, onDone: () -> Unit) {
    var s by remember { mutableStateOf(start) }
    var portText by remember { mutableStateOf(start.port.toString()) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    fun save() {
        // A new address or port is another server: its certificate is trusted afresh.
        val port = portText.toIntOrNull() ?: 0
        val moved = s.host != start.host || port != start.port
        val toSave = s.copy(port = port, tunnelHost = if (s.tunnelId == null) "" else s.tunnelHost, fingerprint = if (moved) "" else s.fingerprint)
        saving = true
        viewModel.saveProxmoxServer(toSave) { r ->
            saving = false
            r.onSuccess { onDone() }.onFailure { error = it.message }
        }
    }
    DeviceFormDialog(
        stringResource(if (start.id == 0) R.string.proxmox_add_title else R.string.proxmox_edit_title), "proxmox", error, saving, ::save, onDone,
    ) {
        NameAddressPortFields(
            s.name, { s = s.copy(name = it) }, s.host, { s = s.copy(host = it) }, portText, { portText = it },
            stringResource(R.string.proxmox_address), stringResource(R.string.proxmox_port), "proxmox",
        )
        OutlinedTextField(s.tokenId, { s = s.copy(tokenId = it.trim()) }, label = { Text(stringResource(R.string.proxmox_token_id)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("proxmox.field.tokenId"))
        OmniPasswordField(s.tokenSecret, { s = s.copy(tokenSecret = it.trim()) }, stringResource(R.string.proxmox_token_secret), Modifier.fillMaxWidth().testTag("proxmox.field.tokenSecret"))
        TunnelChoice(viewModel, s.tunnelId, { s = s.copy(tunnelId = it) }, stringResource(R.string.proxmox_tunnel_note), "proxmox")
        if (s.tunnelId != null) {
            OutlinedTextField(s.tunnelHost, { s = s.copy(tunnelHost = it.trim()) }, label = { Text(stringResource(R.string.proxmox_tunnel_host)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("proxmox.field.tunnelHost"))
        }
        OutlinedTextField(s.notes, { s = s.copy(notes = it) }, label = { Text(stringResource(R.string.notes_optional)) }, modifier = Modifier.fillMaxWidth())
    }
}
