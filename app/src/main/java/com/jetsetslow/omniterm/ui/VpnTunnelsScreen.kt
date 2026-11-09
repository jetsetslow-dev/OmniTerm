package com.jetsetslow.omniterm.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.TunnelEntity
import com.jetsetslow.omniterm.data.tunnel.TunnelStatus
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Tools → VPN tunnels: WireGuard tunnels the user sets up once and picks per host. A tunnel runs
 * inside OmniTerm only, starts when a host needs it and stops when nothing has used it for a while;
 * the phone's own VPN is never used, and nothing else on the phone goes through it.
 */
@Composable
fun VpnTunnelsToolView(viewModel: AppViewModel) {
    val tunnels by viewModel.tunnels.collectAsStateWithLifecycle()
    val statuses by viewModel.tunnelStatuses.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<TunnelEntity?>(null) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<TunnelEntity?>(null) }

    ToolScaffold(viewModel, stringResource(R.string.vpn_title)) {
        ToolCardColumn {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.vpn_intro), fontSize = 13.sp)
                    Text(stringResource(R.string.vpn_never_direct), fontSize = 12.sp, color = OmniColors.amber)
                    Button(onClick = { adding = true }, modifier = Modifier.testTag("vpn.add")) {
                        Text(stringResource(R.string.vpn_add_wireguard))
                    }
                }
            }
            if (tunnels.isEmpty()) {
                Text(stringResource(R.string.vpn_none_yet), fontSize = 13.sp, modifier = Modifier.padding(4.dp))
            }
            tunnels.forEach { tunnel ->
                val users = servers.filter { it.tunnelId == tunnel.id }.map { it.name }
                TunnelCard(
                    tunnel = tunnel,
                    status = statuses[tunnel.id],
                    users = users,
                    onEdit = { editing = tunnel },
                    onStop = { viewModel.stopTunnelNow(tunnel.id) },
                    onDelete = { deleting = tunnel },
                )
            }
        }
    }

    if (adding || editing != null) {
        TunnelEditDialog(viewModel, editing) {
            adding = false
            editing = null
        }
    }
    deleting?.let { tunnel ->
        var problem by remember(tunnel.id) { mutableStateOf<String?>(null) }
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.vpn_delete_title, tunnel.name)) },
            text = {
                Text(problem ?: stringResource(R.string.vpn_delete_body), modifier = Modifier.testTag("vpn.delete.message"))
            },
            confirmButton = {
                if (problem == null) {
                    TextButton(
                        onClick = { viewModel.deleteTunnel(tunnel.id) { err -> if (err == null) deleting = null else problem = err } },
                        modifier = Modifier.testTag("vpn.delete.confirm"),
                    ) { Text(stringResource(R.string.vpn_delete), color = MaterialTheme.colorScheme.error) }
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.vpn_cancel)) } },
        )
    }
}

@Composable
private fun TunnelCard(
    tunnel: TunnelEntity,
    status: TunnelStatus?,
    users: List<String>,
    onEdit: () -> Unit,
    onStop: () -> Unit,
    onDelete: () -> Unit,
) {
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("vpn.item.${tunnel.id}")) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(tunnel.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Text(stringResource(R.string.vpn_kind_wireguard), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(tunnelStatusText(status), fontSize = 12.sp, modifier = Modifier.testTag("vpn.status.${tunnel.id}"))
            Text(
                if (users.isEmpty()) stringResource(R.string.vpn_used_by_none) else stringResource(R.string.vpn_used_by, users.joinToString(", ")),
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row {
                TextButton(onClick = onEdit, modifier = Modifier.testTag("vpn.edit.${tunnel.id}")) { Text(stringResource(R.string.vpn_edit)) }
                if (status != null) {
                    TextButton(onClick = onStop, modifier = Modifier.testTag("vpn.stop.${tunnel.id}")) { Text(stringResource(R.string.vpn_stop)) }
                }
                TextButton(onClick = onDelete, modifier = Modifier.testTag("vpn.delete.${tunnel.id}")) {
                    Text(stringResource(R.string.vpn_delete), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun tunnelStatusText(status: TunnelStatus?): String {
    if (status == null) return stringResource(R.string.vpn_status_down)
    val connections = pluralStringResource(R.plurals.vpn_connections, status.connections, status.connections)
    if (status.lastHandshake <= 0) return stringResource(R.string.vpn_status_no_handshake, connections)
    val ago = ((System.currentTimeMillis() / 1000 - status.lastHandshake).coerceAtLeast(0))
    return stringResource(R.string.vpn_status_up, connections, formatAgo(ago))
}

private fun formatAgo(seconds: Long): String = when {
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60}m"
    else -> "${seconds / 3600}h"
}

/** Adds a tunnel ([existing] null) or renames one and, optionally, replaces its configuration. */
@Composable
private fun TunnelEditDialog(viewModel: AppViewModel, existing: TunnelEntity?, onDone: () -> Unit) {
    val context = LocalContext.current
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var config by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    var checkMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val importFailed = stringResource(R.string.vpn_import_failed)
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val text = runCatching {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val bytes = input.readNBytesCapped(MAX_CONFIG_BYTES + 1)
                    if (bytes.size > MAX_CONFIG_BYTES) null else bytes.toString(Charsets.UTF_8)
                }
            }.getOrNull()
            if (text == null) problem = importFailed else config = text
        }
    }
    LaunchedEffect(config) {
        checkMessage = if (config.isBlank()) null else withContext(Dispatchers.Default) { viewModel.checkTunnelConfig(config) }
    }
    AlertDialog(
        onDismissRequest = { if (!saving) onDone() },
        title = { Text(stringResource(if (existing == null) R.string.vpn_add_title else R.string.vpn_edit_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.vpn_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("vpn.name"),
                )
                OutlinedTextField(
                    value = config,
                    onValueChange = { config = it },
                    label = { Text(stringResource(R.string.vpn_config)) },
                    placeholder = {
                        Text(stringResource(if (existing == null) R.string.vpn_config_hint else R.string.vpn_config_keep), fontSize = 12.sp)
                    },
                    textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 11.sp),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp, max = 260.dp).testTag("vpn.config"),
                )
                TextButton(onClick = { importLauncher.launch(arrayOf("*/*")) }, modifier = Modifier.testTag("vpn.import")) {
                    Text(stringResource(R.string.vpn_import))
                }
                checkMessage?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.check")) }
                problem?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.problem")) }
                Text(stringResource(R.string.vpn_privacy), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving && checkMessage == null,
                onClick = {
                    saving = true
                    problem = null
                    viewModel.saveTunnel(existing?.id, name, config.takeIf { it.isNotBlank() }) { err ->
                        saving = false
                        if (err == null) onDone() else problem = err
                    }
                },
                modifier = Modifier.testTag("vpn.save"),
            ) { Text(stringResource(R.string.vpn_save)) }
        },
        dismissButton = { TextButton(onClick = onDone, enabled = !saving) { Text(stringResource(R.string.vpn_cancel)) } },
    )
}

/**
 * The host editor's VPN tunnel choice: none (connect directly) or one tunnel, which the host then
 * always goes through, and the host's address through it when that differs.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun HostVpnTunnelPicker(
    tunnels: List<TunnelEntity>,
    selected: Int?,
    onSelect: (Int?) -> Unit,
    tunnelHost: String,
    onTunnelHostChange: (String) -> Unit,
) {
    Text(stringResource(R.string.vpn_host_header), fontWeight = FontWeight.Bold, fontSize = 14.sp)
    if (tunnels.isEmpty() && selected == null) {
        Text(stringResource(R.string.vpn_host_none_set_up), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(vertical = 4.dp),
    ) {
        FilterChip(
            selected = selected == null,
            onClick = { onSelect(null) },
            label = { Text(stringResource(R.string.vpn_host_direct), fontSize = 11.sp) },
            modifier = Modifier.testTag("host.tunnel.none"),
        )
        tunnels.forEach { tunnel ->
            FilterChip(
                selected = selected == tunnel.id,
                onClick = { onSelect(tunnel.id) },
                label = { Text(tunnel.name, fontSize = 11.sp) },
                modifier = Modifier.testTag("host.tunnel.${tunnel.id}"),
            )
        }
    }
    if (selected != null) {
        if (tunnels.none { it.id == selected }) {
            Text(stringResource(R.string.vpn_host_tunnel_gone), fontSize = 11.sp, color = MaterialTheme.colorScheme.error)
        }
        Text(stringResource(R.string.vpn_host_never_direct), fontSize = 11.sp, color = OmniColors.amber)
        OutlinedTextField(
            value = tunnelHost,
            onValueChange = onTunnelHostChange,
            label = { Text(stringResource(R.string.vpn_host_address)) },
            supportingText = { Text(stringResource(R.string.vpn_host_address_help), fontSize = 11.sp) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("host.tunnelHost"),
        )
    } else {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.vpn_host_direct_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun java.io.InputStream.readNBytesCapped(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(8192)
    while (out.size() < limit) {
        val n = read(buf, 0, minOf(buf.size, limit - out.size()))
        if (n < 0) break
        out.write(buf, 0, n)
    }
    return out.toByteArray()
}

private const val MAX_CONFIG_BYTES = 64 * 1024
