package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.ui.theme.OmniColors

/*
 * Form pieces shared by the dialogs for things that are not hosts but are reached from the phone:
 * SNMP devices and Proxmox servers.
 */

/**
 * The add or edit dialog: [title], the scrolling [fields], then [error] in red (tagged
 * `<tagPrefix>.error`), Save (`<tagPrefix>.save`, off while [saving]) and Cancel.
 */
@Composable
internal fun DeviceFormDialog(
    title: String,
    tagPrefix: String,
    error: String?,
    saving: Boolean,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
    fields: @Composable ColumnScope.() -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                fields()
                error?.let { Text(it, color = OmniColors.red, fontSize = 12.sp, modifier = Modifier.testTag("$tagPrefix.error")) }
            }
        },
        confirmButton = {
            TextButton(enabled = !saving, onClick = onSave, modifier = Modifier.testTag("$tagPrefix.save")) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Name, address and port, tagged `<tagPrefix>.field.name`, `.host` and `.port`. The address is
 * trimmed as it is typed and the port keeps up to five digits.
 */
@Composable
internal fun NameAddressPortFields(
    name: String,
    onName: (String) -> Unit,
    host: String,
    onHost: (String) -> Unit,
    port: String,
    onPort: (String) -> Unit,
    addressLabel: String,
    portLabel: String,
    tagPrefix: String,
) {
    OutlinedTextField(name, onName, label = { Text(stringResource(R.string.snmp_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("$tagPrefix.field.name"))
    OutlinedTextField(host, { onHost(it.trim()) }, label = { Text(addressLabel) }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("$tagPrefix.field.host"))
    OutlinedTextField(
        port, { onPort(it.filter(Char::isDigit).take(5)) }, label = { Text(portLabel) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth().testTag("$tagPrefix.field.port"),
    )
}

/**
 * "Reach it through": Direct or one of the saved VPN tunnels. Shown only when there are tunnels;
 * [note] explains what a tunnel means for this kind of thing, under the chips while one is picked.
 */
@Composable
internal fun TunnelChoice(viewModel: AppViewModel, tunnelId: Int?, onChange: (Int?) -> Unit, note: String, tagPrefix: String) {
    val tunnels by viewModel.tunnels.collectAsStateWithLifecycle()
    if (tunnels.isEmpty()) return
    Text(stringResource(R.string.snmp_tunnel), fontSize = 12.sp)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        FilterChip(tunnelId == null, { onChange(null) }, label = { Text(stringResource(R.string.snmp_direct)) }, modifier = Modifier.testTag("$tagPrefix.tunnel.none"))
        tunnels.forEach { t ->
            FilterChip(tunnelId == t.id, { onChange(t.id) }, label = { Text(t.name) }, modifier = Modifier.testTag("$tagPrefix.tunnel.${t.id}"))
        }
    }
    if (tunnelId != null) Text(note, fontSize = 11.sp, color = OmniColors.amber)
}
