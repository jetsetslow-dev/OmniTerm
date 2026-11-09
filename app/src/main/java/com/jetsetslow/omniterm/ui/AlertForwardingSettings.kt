package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.AlertForwarding
import com.jetsetslow.omniterm.ui.theme.OmniColors
import java.net.URI
import java.text.DateFormat
import java.util.Date

/** The Alerts screen's forwarding line: where alerts go besides this phone, and how the last one went. */
@Composable
internal fun AlertForwardingRow(viewModel: AppViewModel) {
    var editing by remember { mutableStateOf(false) }
    val config = viewModel.alertForwarding
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(stringResource(R.string.alert_forwarding), fontWeight = FontWeight.Bold, fontSize = 13.sp)
            Text(
                if (config.enabled) {
                    stringResource(R.string.alert_forwarding_to, forwardKindName(config.kind), forwardAddress(config))
                } else {
                    stringResource(R.string.alert_forwarding_off)
                },
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            viewModel.alertForwardStatus?.takeIf { config.enabled }?.let { (at, outcome) ->
                val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(at))
                Text(
                    if (outcome.ok) {
                        stringResource(R.string.alert_forwarding_last_ok, time)
                    } else {
                        stringResource(R.string.alert_forwarding_last_failed, time, outcome.detail)
                    },
                    fontSize = 11.sp,
                    color = if (outcome.ok) MaterialTheme.colorScheme.onSurfaceVariant else OmniColors.red,
                )
            }
        }
        TextButton(onClick = { editing = true }, modifier = Modifier.testTag("alertForward.open")) {
            Text(stringResource(if (config.enabled) R.string.alert_forwarding_change else R.string.alert_forwarding_set_up))
        }
    }
    if (editing) {
        AlertForwardingDialog(viewModel, onDismiss = { editing = false })
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AlertForwardingDialog(viewModel: AppViewModel, onDismiss: () -> Unit) {
    val saved = viewModel.alertForwarding
    var kind by remember { mutableStateOf(saved.kind) }
    var url by remember { mutableStateOf(saved.url) }
    var topic by remember { mutableStateOf(saved.topic) }
    var token by remember { mutableStateOf(saved.token) }
    var includeResolved by remember { mutableStateOf(saved.includeResolved) }
    var testResult by remember { mutableStateOf<AlertForwarding.Outcome?>(null) }
    var testing by remember { mutableStateOf(false) }
    val draft = AlertForwarding.Config(kind, url, topic, token, includeResolved)
    val error = AlertForwarding.configError(draft)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.alert_forwarding)) },
        text = {
            Column(
                modifier = Modifier.verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    AlertForwarding.KINDS.forEach { option ->
                        FilterChip(
                            selected = kind == option,
                            onClick = { kind = option; testResult = null },
                            label = { Text(forwardKindName(option)) },
                        )
                    }
                }
                if (kind != AlertForwarding.KIND_OFF) {
                    Text(stringResource(R.string.alert_forwarding_what), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedTextField(
                        value = url,
                        onValueChange = { url = it; testResult = null },
                        label = {
                            Text(
                                stringResource(
                                    when (kind) {
                                        AlertForwarding.KIND_NTFY -> R.string.alert_forwarding_ntfy_server
                                        AlertForwarding.KIND_GOTIFY -> R.string.alert_forwarding_gotify_server
                                        else -> R.string.alert_forwarding_webhook_url
                                    },
                                ),
                            )
                        },
                        placeholder = {
                            Text(
                                when (kind) {
                                    AlertForwarding.KIND_NTFY -> AlertForwarding.DEFAULT_NTFY_SERVER
                                    AlertForwarding.KIND_GOTIFY -> "https://gotify.example.com"
                                    else -> "https://example.com/hooks/omniterm"
                                },
                            )
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth().testTag("alertForward.url"),
                    )
                    if (kind == AlertForwarding.KIND_NTFY) {
                        OutlinedTextField(
                            value = topic,
                            onValueChange = { topic = it; testResult = null },
                            label = { Text(stringResource(R.string.alert_forwarding_topic)) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth().testTag("alertForward.topic"),
                        )
                        Text(stringResource(R.string.alert_forwarding_ntfy_topic_note), fontSize = 11.sp, color = OmniColors.amber)
                    }
                    OmniPasswordField(
                        value = token,
                        onValueChange = { token = it; testResult = null },
                        label = stringResource(
                            when (kind) {
                                AlertForwarding.KIND_NTFY -> R.string.alert_forwarding_ntfy_token
                                AlertForwarding.KIND_GOTIFY -> R.string.alert_forwarding_gotify_token
                                else -> R.string.alert_forwarding_webhook_token
                            },
                        ),
                        modifier = Modifier.fillMaxWidth().testTag("alertForward.token"),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.alert_forwarding_resolved), modifier = Modifier.weight(1f), fontSize = 13.sp)
                        Switch(checked = includeResolved, onCheckedChange = { includeResolved = it })
                    }
                    if (AlertForwarding.isCleartext(draft)) {
                        Text(stringResource(R.string.alert_forwarding_cleartext), fontSize = 11.sp, color = OmniColors.amber)
                    }
                    error?.let { Text(it, fontSize = 11.sp, color = OmniColors.red) }
                    TextButton(
                        enabled = error == null && !testing,
                        onClick = {
                            testing = true
                            viewModel.testAlertForwarding(draft) { outcome ->
                                testResult = outcome
                                testing = false
                            }
                        },
                        modifier = Modifier.testTag("alertForward.test"),
                    ) { Text(stringResource(R.string.alert_forwarding_test)) }
                    testResult?.let { outcome ->
                        Text(
                            if (outcome.ok) {
                                stringResource(R.string.alert_forwarding_test_ok, outcome.detail)
                            } else {
                                stringResource(R.string.alert_forwarding_test_failed, outcome.detail)
                            },
                            fontSize = 11.sp,
                            color = if (outcome.ok) OmniColors.green else OmniColors.red,
                            modifier = Modifier.testTag("alertForward.testResult"),
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = error == null,
                onClick = {
                    viewModel.saveAlertForwarding(draft)
                    onDismiss()
                },
            ) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

private fun forwardKindName(kind: String) = when (kind) {
    AlertForwarding.KIND_NTFY -> "ntfy"
    AlertForwarding.KIND_GOTIFY -> "Gotify"
    AlertForwarding.KIND_WEBHOOK -> "Webhook"
    else -> "Off"
}

/** Where alerts go, short: the server's host, and the topic for ntfy. */
private fun forwardAddress(config: AlertForwarding.Config): String {
    val url = config.url.ifBlank { AlertForwarding.DEFAULT_NTFY_SERVER }
    val host = runCatching { URI(url).host }.getOrNull() ?: url
    return if (config.kind == AlertForwarding.KIND_NTFY) "$host/${config.topic}" else host
}
