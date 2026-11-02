package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.serial.SerialParity
import com.jetsetslow.omniterm.data.serial.SerialSettings
import com.jetsetslow.omniterm.data.serial.SerialStopBits
import com.jetsetslow.omniterm.data.serial.UsbSerialAdapter
import com.jetsetslow.omniterm.data.telnet.TelnetSession
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Telnet from the Terminal: the saved connections, tap one to open it, and a form for another,
 * optionally saved. Telnet sends everything, passwords included, unencrypted, and says so.
 */
@Composable
fun TelnetConnectDialog(viewModel: AppViewModel) {
    val saved by viewModel.telnetHosts.collectAsStateWithLifecycle()
    var host by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf(TelnetSession.DEFAULT_PORT.toString()) }
    var name by rememberSaveable { mutableStateOf("") }
    var save by rememberSaveable { mutableStateOf(true) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val portIssue = portError(port)
    fun dismiss() {
        viewModel.telnetSheetOpen = false
    }

    AlertDialog(
        onDismissRequest = ::dismiss,
        title = { Text(stringResource(R.string.telnet)) },
        text = {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 560.dp).verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(stringResource(R.string.telnet_is_not_encrypted), fontSize = 12.sp, color = OmniColors.amber)
                if (saved.isNotEmpty()) {
                    saved.forEach { entry ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clickable {
                                    viewModel.connectTelnet(entry.name, entry.host, entry.port, save = false) { errorText = it }
                                }
                                .testTag("telnet.saved.${entry.id}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                Text(entry.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                                val address = if (entry.port == TelnetSession.DEFAULT_PORT) entry.host else "${entry.host}:${entry.port}"
                                Text(HostDisplay.sensitive(address), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { viewModel.deleteTelnetHost(entry) }) {
                                Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.remove_saved_telnet, entry.name))
                            }
                        }
                    }
                    HorizontalDivider()
                }
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it; errorText = null },
                    label = { Text(stringResource(R.string.hostname_or_ip)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth().testTag("telnet.host"),
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it.filter(Char::isDigit).take(5); errorText = null },
                    label = { Text(stringResource(R.string.port)) },
                    singleLine = true,
                    isError = portIssue != null,
                    supportingText = portIssue?.let { { Text(it) } },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth().testTag("telnet.port"),
                )
                Row(
                    Modifier.fillMaxWidth().toggleable(value = save, role = Role.Checkbox, onValueChange = { save = it }),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = save, onCheckedChange = null)
                    Text(stringResource(R.string.save_this_connection), Modifier.padding(start = 8.dp))
                }
                if (save) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text(stringResource(R.string.name_optional)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("telnet.name"),
                    )
                }
                errorText?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = host.isNotBlank() && portIssue == null && !viewModel.isTerminalConnecting,
                onClick = { viewModel.connectTelnet(name, host, port.toInt(), save) { errorText = it } },
                modifier = Modifier.testTag("telnet.connect"),
            ) { Text(stringResource(R.string.connect)) }
        },
        dismissButton = { TextButton(onClick = ::dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * USB serial from the Terminal: the adapters plugged in now, and the line settings, which start
 * from the ones used last. Android asks the user to allow the adapter the first time.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SerialConnectDialog(viewModel: AppViewModel) {
    var adapters by remember { mutableStateOf(viewModel.usbSerialAdapters()) }
    var chosen by remember { mutableStateOf(adapters.firstOrNull()?.device?.deviceName) }
    val last = viewModel.lastSerialSettings
    var baud by rememberSaveable { mutableStateOf(last.baudRate.toString()) }
    var dataBits by rememberSaveable { mutableStateOf(last.dataBits) }
    var parity by rememberSaveable { mutableStateOf(last.parity) }
    var stopBits by rememberSaveable { mutableStateOf(last.stopBits) }
    var baudMenu by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val baudRate = baud.toIntOrNull()?.takeIf { it in 50..12_000_000 }
    val adapter = adapters.find { it.device.deviceName == chosen }
    fun dismiss() {
        viewModel.serialSheetOpen = false
    }
    fun refresh() {
        adapters = viewModel.usbSerialAdapters()
        if (adapters.none { it.device.deviceName == chosen }) chosen = adapters.firstOrNull()?.device?.deviceName
        errorText = null
    }

    AlertDialog(
        onDismissRequest = ::dismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.usb_serial), Modifier.weight(1f))
                IconButton(onClick = ::refresh, modifier = Modifier.testTag("serial.refresh")) {
                    Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.refresh))
                }
            }
        },
        text = {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 560.dp).verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (adapters.isEmpty()) {
                    Text(
                        stringResource(R.string.no_usb_serial_adapter),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag("serial.none"),
                    )
                }
                adapters.forEach { item: UsbSerialAdapter ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .selectable(selected = item.device.deviceName == chosen, role = Role.RadioButton) { chosen = item.device.deviceName },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = item.device.deviceName == chosen, onClick = null)
                        Column(Modifier.padding(start = 8.dp)) {
                            Text(item.label, fontWeight = FontWeight.Bold)
                            Text(item.chip.label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                HorizontalDivider()
                Box {
                    OutlinedTextField(
                        value = baud,
                        onValueChange = { baud = it.filter(Char::isDigit).take(8) },
                        label = { Text(stringResource(R.string.baud_rate)) },
                        singleLine = true,
                        isError = baudRate == null,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        trailingIcon = {
                            IconButton(onClick = { baudMenu = true }) {
                                Icon(Icons.Filled.ArrowDropDown, contentDescription = stringResource(R.string.common_baud_rates))
                            }
                        },
                        modifier = Modifier.fillMaxWidth().testTag("serial.baud"),
                    )
                    DropdownMenu(expanded = baudMenu, onDismissRequest = { baudMenu = false }) {
                        SerialSettings.BAUD_RATES.forEach { rate ->
                            DropdownMenuItem(text = { Text(rate.toString()) }, onClick = { baud = rate.toString(); baudMenu = false })
                        }
                    }
                }
                Text(stringResource(R.string.data_bits), fontSize = 12.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    (5..8).forEach { bits ->
                        FilterChip(selected = dataBits == bits, onClick = { dataBits = bits }, label = { Text("$bits") })
                    }
                }
                Text(stringResource(R.string.parity), fontSize = 12.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SerialParity.entries.forEach { option ->
                        FilterChip(selected = parity == option, onClick = { parity = option }, label = { Text(option.name) })
                    }
                }
                Text(stringResource(R.string.stop_bits), fontSize = 12.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    SerialStopBits.entries.forEach { option ->
                        FilterChip(selected = stopBits == option, onClick = { stopBits = option }, label = { Text(option.label) })
                    }
                }
                errorText?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = adapter != null && baudRate != null && !viewModel.isTerminalConnecting,
                onClick = {
                    val settings = SerialSettings(baudRate ?: return@TextButton, dataBits, parity, stopBits)
                    viewModel.connectSerial(adapter ?: return@TextButton, settings) { errorText = it }
                },
                modifier = Modifier.testTag("serial.connect"),
            ) { Text(stringResource(R.string.connect)) }
        },
        dismissButton = { TextButton(onClick = ::dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
