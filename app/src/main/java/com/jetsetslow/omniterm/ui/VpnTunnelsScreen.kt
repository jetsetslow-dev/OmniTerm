package com.jetsetslow.omniterm.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
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
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.tunnel.CurrentWifi
import com.jetsetslow.omniterm.data.tunnel.TailscaleSettings
import com.jetsetslow.omniterm.data.tunnel.TunnelNetworks
import com.jetsetslow.omniterm.data.tunnel.TunnelStates
import com.jetsetslow.omniterm.data.tunnel.TunnelStatus
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Tools → VPN tunnels: WireGuard and Tailscale (or Headscale) tunnels the user sets up once and
 * picks per host. A tunnel runs inside OmniTerm only, starts when a host needs it and stops when
 * nothing has used it for a while; the phone's own VPN is never used, and nothing else on the phone
 * goes through it.
 */
@Composable
fun VpnTunnelsToolView(viewModel: AppViewModel) {
    val tunnels by viewModel.tunnels.collectAsStateWithLifecycle()
    val statuses by viewModel.tunnelStatuses.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val problems by viewModel.tunnelProblems.collectAsStateWithLifecycle()
    val wifi by CurrentWifi.state.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<TunnelEntity?>(null) }
    // The kind of tunnel being added, or null.
    var adding by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<TunnelEntity?>(null) }

    ToolScaffold(viewModel, stringResource(R.string.vpn_title)) {
        ToolCardColumn {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.vpn_intro), fontSize = 13.sp)
                    Text(stringResource(R.string.vpn_never_direct), fontSize = 12.sp, color = OmniColors.amber)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Button(onClick = { adding = TunnelKinds.WIREGUARD }, modifier = Modifier.testTag("vpn.add")) {
                            Text(stringResource(R.string.vpn_add_wireguard))
                        }
                        Button(onClick = { adding = TunnelKinds.TAILSCALE }, modifier = Modifier.testTag("vpn.add.tailscale")) {
                            Text(stringResource(R.string.vpn_add_tailscale))
                        }
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
                    problem = problems[tunnel.id],
                    users = users,
                    wifi = wifi.name,
                    onConnect = { viewModel.connectTunnel(tunnel.id) },
                    onEdit = { editing = tunnel },
                    onStop = { viewModel.stopTunnelNow(tunnel.id) },
                    onDelete = { deleting = tunnel },
                )
            }
        }
    }

    val kind = editing?.kind ?: adding
    if (kind != null) {
        val done = {
            adding = null
            editing = null
        }
        if (kind == TunnelKinds.TAILSCALE) TailscaleEditDialog(viewModel, editing, done) else TunnelEditDialog(viewModel, editing, done)
    }
    deleting?.let { tunnel ->
        var problem by remember(tunnel.id) { mutableStateOf<String?>(null) }
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.vpn_delete_title, tunnel.name)) },
            text = {
                Text(
                    problem ?: stringResource(if (tunnel.kind == TunnelKinds.TAILSCALE) R.string.vpn_ts_delete_body else R.string.vpn_delete_body),
                    modifier = Modifier.testTag("vpn.delete.message"),
                )
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
    problem: String?,
    users: List<String>,
    wifi: String?,
    onConnect: () -> Unit,
    onEdit: () -> Unit,
    onStop: () -> Unit,
    onDelete: () -> Unit,
) {
    val tailscale = tunnel.kind == TunnelKinds.TAILSCALE
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("vpn.item.${tunnel.id}")) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(tunnel.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Text(
                stringResource(if (tailscale) R.string.vpn_kind_tailscale else R.string.vpn_kind_wireguard),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("vpn.kind.${tunnel.id}"),
            )
            Text(
                if (tailscale) tailscaleStatusText(status) else tunnelStatusText(status),
                fontSize = 12.sp,
                modifier = Modifier.testTag("vpn.status.${tunnel.id}"),
            )
            (problem ?: status?.problem?.takeIf { it.isNotEmpty() })?.let {
                Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.problem.${tunnel.id}"))
            }
            Text(
                if (users.isEmpty()) stringResource(R.string.vpn_used_by_none) else stringResource(R.string.vpn_used_by, users.joinToString(", ")),
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val directOn = TunnelNetworks.names(tunnel.directWifi)
            if (directOn.isNotEmpty()) {
                Text(
                    if (wifi != null && wifi in directOn) {
                        stringResource(R.string.vpn_direct_now, wifi)
                    } else {
                        stringResource(R.string.vpn_direct_on, directOn.joinToString(", "))
                    },
                    fontSize = 12.sp,
                    color = if (wifi != null && wifi in directOn) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("vpn.direct.${tunnel.id}"),
                )
                if (!CurrentWifi.mayReadName(LocalContext.current)) {
                    Text(stringResource(R.string.vpn_direct_wifi_blocked), fontSize = 12.sp, color = OmniColors.amber)
                }
            }
            FlowRow {
                val signIn = status?.authUrl.orEmpty()
                if (tailscale && signIn.isNotEmpty()) {
                    val uri = LocalUriHandler.current
                    TextButton(onClick = { runCatching { uri.openUri(signIn) } }, modifier = Modifier.testTag("vpn.signin.${tunnel.id}")) {
                        Text(stringResource(R.string.vpn_ts_sign_in))
                    }
                }
                if (tailscale && status == null) {
                    TextButton(onClick = onConnect, modifier = Modifier.testTag("vpn.connect.${tunnel.id}")) {
                        Text(stringResource(R.string.vpn_ts_connect))
                    }
                }
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

@Composable
private fun tailscaleStatusText(status: TunnelStatus?): String {
    if (status == null) return stringResource(R.string.vpn_ts_status_down)
    return when (status.state) {
        TunnelStates.NEEDS_LOGIN ->
            stringResource(if (status.authUrl.isEmpty()) R.string.vpn_ts_status_signed_out else R.string.vpn_ts_status_needs_login)
        TunnelStates.NEEDS_APPROVAL -> stringResource(R.string.vpn_ts_status_needs_approval)
        TunnelStates.RUNNING -> stringResource(
            R.string.vpn_ts_status_up,
            status.addresses.substringBefore(',').ifEmpty { "…" },
            pluralStringResource(R.plurals.vpn_connections, status.connections, status.connections),
        )
        else -> stringResource(R.string.vpn_ts_status_starting)
    }
}

private fun formatAgo(seconds: Long): String = when {
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60}m"
    else -> "${seconds / 3600}h"
}

/**
 * Adds a tunnel ([existing] null), or renames one, sets the Wi-Fi networks it is not needed on
 * and, optionally, replaces its configuration.
 */
@Composable
private fun TunnelEditDialog(viewModel: AppViewModel, existing: TunnelEntity?, onDone: () -> Unit) {
    val context = LocalContext.current
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var config by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    var checkMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var directWifi by remember { mutableStateOf(TunnelNetworks.names(existing?.directWifi.orEmpty())) }
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
    TunnelEditorFrame(
        title = stringResource(if (existing == null) R.string.vpn_add_title else R.string.vpn_edit_title),
        name = name,
        onName = { name = it },
        saving = saving,
        canSave = !saving && checkMessage == null,
        onSave = {
            saving = true
            problem = null
            viewModel.saveTunnel(existing?.id, name, config.takeIf { it.isNotBlank() }, directWifi) { err ->
                saving = false
                if (err == null) onDone() else problem = err
            }
        },
        onDone = onDone,
    ) {
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
        TunnelDirectWifiEditor(directWifi) { directWifi = it }
        Text(stringResource(R.string.vpn_privacy), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Adds a Tailscale tunnel ([existing] null) or edits one: its control server (Tailscale's own, or a
 * Headscale server), an optional auth key, which an edit keeps unless a new one is typed, the
 * device name the phone has in the tailnet, and the Wi-Fi networks it is not needed on.
 */
@Composable
private fun TailscaleEditDialog(viewModel: AppViewModel, existing: TunnelEntity?, onDone: () -> Unit) {
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var control by remember { mutableStateOf("") }
    var authKey by remember { mutableStateOf("") }
    var device by remember { mutableStateOf(if (existing == null) TailscaleSettings.deviceName(android.os.Build.MODEL.orEmpty()) else "") }
    var hasKey by remember { mutableStateOf(false) }
    var before by remember { mutableStateOf<TailscaleSettings?>(null) }
    var loaded by remember { mutableStateOf(existing == null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var checkMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var directWifi by remember { mutableStateOf(TunnelNetworks.names(existing?.directWifi.orEmpty())) }
    LaunchedEffect(existing?.id) {
        val id = existing?.id ?: return@LaunchedEffect
        viewModel.loadTailscaleSettings(id) { settings, key ->
            settings?.let {
                control = it.controlUrl
                device = it.hostname
                before = it
            }
            hasKey = key
            loaded = true
        }
    }
    val settings = TailscaleSettings(control, authKey, device)
    LaunchedEffect(control, authKey, device) {
        checkMessage = withContext(Dispatchers.Default) { viewModel.checkTunnelConfig(settings.toConfig(), TunnelKinds.TAILSCALE) }
    }
    TunnelEditorFrame(
        title = stringResource(if (existing == null) R.string.vpn_ts_add_title else R.string.vpn_edit_title),
        name = name,
        onName = { name = it },
        saving = saving,
        canSave = loaded && !saving && checkMessage == null,
        onSave = {
            saving = true
            problem = null
            viewModel.saveTailscaleTunnel(existing?.id, name, settings, directWifi) { err ->
                saving = false
                if (err == null) onDone() else problem = err
            }
        },
        onDone = onDone,
    ) {
        OutlinedTextField(
            value = control,
            onValueChange = { control = it },
            label = { Text(stringResource(R.string.vpn_ts_control)) },
            supportingText = { Text(stringResource(R.string.vpn_ts_control_help), fontSize = 11.sp) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("vpn.ts.control"),
        )
        if (settings.plainHttp()) {
            PlainHttpWarning(stringResource(R.string.vpn_ts_plain_http), Modifier.testTag("vpn.ts.plainhttp"))
        }
        before?.let { old ->
            if (!old.sameServerAs(settings)) {
                Text(stringResource(R.string.vpn_ts_server_change), fontSize = 12.sp, color = OmniColors.amber, modifier = Modifier.testTag("vpn.ts.newnode"))
            }
        }
        OmniPasswordField(
            value = authKey,
            onValueChange = { authKey = it },
            label = stringResource(if (hasKey) R.string.vpn_ts_auth_key_keep else R.string.vpn_ts_auth_key),
            modifier = Modifier.fillMaxWidth().testTag("vpn.ts.authkey"),
        )
        Text(stringResource(R.string.vpn_ts_auth_key_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(
            value = device,
            onValueChange = { device = it },
            label = { Text(stringResource(R.string.vpn_ts_device)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("vpn.ts.device"),
        )
        checkMessage?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.check")) }
        problem?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.problem")) }
        Text(stringResource(R.string.vpn_ts_routes), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TunnelDirectWifiEditor(directWifi) { directWifi = it }
        Text(stringResource(R.string.vpn_ts_privacy), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** What both tunnel editors share: the title, the tunnel's name above [fields], and Save and Cancel. */
@Composable
private fun TunnelEditorFrame(
    title: String,
    name: String,
    onName: (String) -> Unit,
    saving: Boolean,
    canSave: Boolean,
    onSave: () -> Unit,
    onDone: () -> Unit,
    fields: @Composable ColumnScope.() -> Unit,
) {
    AlertDialog(
        onDismissRequest = { if (!saving) onDone() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(
                    value = name,
                    onValueChange = onName,
                    label = { Text(stringResource(R.string.vpn_name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("vpn.name"),
                )
                fields()
            }
        },
        confirmButton = {
            TextButton(enabled = canSave, onClick = onSave, modifier = Modifier.testTag("vpn.save")) { Text(stringResource(R.string.vpn_save)) }
        },
        dismissButton = { TextButton(onClick = onDone, enabled = !saving) { Text(stringResource(R.string.vpn_cancel)) } },
    )
}

/**
 * The Wi-Fi networks a tunnel is not needed on ([TunnelNetworks]): typed, or taken from the Wi-Fi
 * the phone is on. Android gives that name only with the precise location permission, which is
 * asked for here, when the user wants it, and nowhere else.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TunnelDirectWifiEditor(names: List<String>, onChange: (List<String>) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var typed by remember { mutableStateOf("") }
    var note by remember { mutableStateOf<String?>(null) }
    var mayRead by remember { mutableStateOf(CurrentWifi.mayReadName(context)) }
    val tooLong = stringResource(R.string.vpn_direct_wifi_too_long)
    val full = stringResource(R.string.vpn_direct_wifi_full, TunnelNetworks.MAX_NAMES)
    val notWifi = stringResource(R.string.vpn_direct_wifi_not_wifi)
    val withheld = stringResource(R.string.vpn_direct_wifi_withheld)

    fun add(name: String) {
        note = when {
            name.isEmpty() || name in names -> null
            TunnelNetworks.tooLong(name) -> tooLong
            names.size >= TunnelNetworks.MAX_NAMES -> full
            else -> {
                onChange(names + name)
                null
            }
        }
    }

    fun addCurrent() {
        scope.launch {
            // Asked again, so a name Android withheld until now comes with the answer.
            CurrentWifi.refresh()
            val name = CurrentWifi.name()
            when {
                name != null -> add(name)
                CurrentWifi.state.value.onWifi -> note = withheld
                else -> note = notWifi
            }
        }
    }

    val askPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        mayRead = CurrentWifi.mayReadName(context)
        if (mayRead) addCurrent() else CurrentWifi.refresh()
    }
    val permissions = arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION, android.Manifest.permission.ACCESS_COARSE_LOCATION)

    Text(stringResource(R.string.vpn_direct_wifi_header), fontWeight = FontWeight.Bold, fontSize = 13.sp)
    Text(stringResource(R.string.vpn_direct_wifi_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (names.isNotEmpty()) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            names.forEach { name ->
                InputChip(
                    selected = false,
                    onClick = { onChange(names - name) },
                    label = { Text(name, fontSize = 12.sp) },
                    trailingIcon = { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.vpn_direct_wifi_remove, name)) },
                    modifier = Modifier.testTag("vpn.wifi.item.$name"),
                )
            }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = typed,
            onValueChange = { typed = it },
            label = { Text(stringResource(R.string.vpn_direct_wifi_name)) },
            singleLine = true,
            modifier = Modifier.weight(1f).testTag("vpn.wifi.name"),
        )
        TextButton(
            onClick = {
                add(typed.trim())
                if (note == null) typed = ""
            },
            enabled = typed.isNotBlank(),
            modifier = Modifier.testTag("vpn.wifi.add"),
        ) { Text(stringResource(R.string.vpn_direct_wifi_add)) }
    }
    TextButton(
        onClick = { if (mayRead) addCurrent() else askPermission.launch(permissions) },
        modifier = Modifier.testTag("vpn.wifi.current"),
    ) { Text(stringResource(R.string.vpn_direct_wifi_add_current)) }
    note?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("vpn.wifi.note")) }
    if (names.isNotEmpty()) {
        when {
            !mayRead -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.vpn_direct_wifi_permission),
                    fontSize = 11.sp,
                    color = OmniColors.amber,
                    modifier = Modifier.weight(1f).testTag("vpn.wifi.permission"),
                )
                TextButton(onClick = { askPermission.launch(permissions) }, modifier = Modifier.testTag("vpn.wifi.allow")) {
                    Text(stringResource(R.string.vpn_direct_wifi_allow))
                }
            }
            !CurrentWifi.locationOn(context) ->
                Text(stringResource(R.string.vpn_direct_wifi_location_off), fontSize = 11.sp, color = OmniColors.amber)
            else ->
                Text(stringResource(R.string.vpn_direct_wifi_background), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
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
        val directOn = TunnelNetworks.names(tunnels.firstOrNull { it.id == selected }?.directWifi.orEmpty())
        if (directOn.isNotEmpty()) {
            Text(
                stringResource(R.string.vpn_host_direct_on_wifi, directOn.joinToString(", ")),
                fontSize = 11.sp,
                color = OmniColors.amber,
                modifier = Modifier.testTag("host.tunnel.directWifi"),
            )
        }
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
