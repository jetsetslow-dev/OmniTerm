package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.McpCallOutcome
import com.jetsetslow.omniterm.data.mcp.McpHttpServer
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import java.text.DateFormat
import java.util.Date

/**
 * Tools → AI assistants: the opt-in MCP server. Off until the user turns it on, which needs a
 * token and App Lock or the screen lock. The user picks which hosts assistants may see, whether
 * any command may be asked for, and the host a computer reaches the server through; every call
 * is listed here.
 */
@Composable
fun McpToolView(viewModel: AppViewModel) {
    val config by viewModel.mcpConfig.collectAsStateWithLifecycle()
    val state by viewModel.mcpState.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val calls by viewModel.mcpCalls.collectAsStateWithLifecycle()
    var turningOn by remember { mutableStateOf(false) }
    var makingToken by remember { mutableStateOf(false) }
    var newToken by remember { mutableStateOf<String?>(null) }
    var revoking by remember { mutableStateOf(false) }

    ToolScaffold(viewModel, "AI assistants") {
        ToolCardColumn {
            ToolSwitchCard(
                title = stringResource(R.string.mcp_switch),
                help = stringResource(R.string.mcp_switch_help),
                checked = config.enabled,
                onCheckedChange = { on -> if (on) turningOn = true else viewModel.saveMcpEnabled(false) },
                switchTag = "mcp.enabled",
            ) {
                Text(stringResource(R.string.mcp_privacy), fontSize = 12.sp, color = OmniColors.amber, modifier = Modifier.testTag("mcp.privacy"))
                if (config.enabled) {
                    Text(mcpStatusText(state), fontSize = 12.sp, modifier = Modifier.testTag("mcp.status"))
                }
            }

            SettingsCardHeader(stringResource(R.string.mcp_token_header), "", OmniColors.cyan)
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        stringResource(if (config.tokenHash != null) R.string.mcp_token_set else R.string.mcp_token_none),
                        fontSize = 13.sp,
                        modifier = Modifier.testTag("mcp.token.state"),
                    )
                    Row {
                        TextButton(onClick = { makingToken = true }, modifier = Modifier.testTag("mcp.token.make")) {
                            Text(stringResource(if (config.tokenHash != null) R.string.mcp_token_replace else R.string.mcp_token_make))
                        }
                        if (config.tokenHash != null) {
                            TextButton(onClick = { revoking = true }, modifier = Modifier.testTag("mcp.token.revoke")) {
                                Text(stringResource(R.string.automation_revoke), color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }

            SettingsCardHeader(stringResource(R.string.mcp_hosts_header), stringResource(R.string.mcp_hosts_help), OmniColors.cyan)
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(vertical = 8.dp)) {
                    if (servers.isEmpty()) {
                        Text(stringResource(R.string.mcp_no_hosts_saved), fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                    }
                    servers.forEach { srv ->
                        val shared = srv.id in config.hostIds
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                            Checkbox(
                                checked = shared,
                                onCheckedChange = { on -> viewModel.saveMcpHosts(if (on) config.hostIds + srv.id else config.hostIds - srv.id) },
                                modifier = Modifier.testTag("mcp.host.${srv.id}"),
                            )
                            Text(srv.name, fontSize = 13.sp)
                        }
                    }
                }
            }

            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.mcp_any_command), fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        Text(stringResource(R.string.mcp_any_command_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = config.anyCommand, onCheckedChange = viewModel::saveMcpAnyCommand, modifier = Modifier.testTag("mcp.any_command"))
                }
            }

            SettingsCardHeader(stringResource(R.string.mcp_reach_header), stringResource(R.string.mcp_reach_help), OmniColors.cyan)
            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(vertical = 8.dp)) {
                    ReachRow(stringResource(R.string.mcp_reach_phone_only), config.tunnelHostId == null, "mcp.reach.none") {
                        viewModel.saveMcpTunnel(null, config.tunnelPort)
                    }
                    servers.forEach { srv ->
                        ReachRow(srv.name, config.tunnelHostId == srv.id, "mcp.reach.${srv.id}") { viewModel.saveMcpTunnel(srv.id, config.tunnelPort) }
                    }
                    Row(modifier = Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PortField(stringResource(R.string.mcp_phone_port), config.port, "mcp.port", Modifier.weight(1f), viewModel::saveMcpPort)
                        if (config.tunnelHostId != null) {
                            PortField(stringResource(R.string.mcp_host_port), config.tunnelPort, "mcp.tunnel_port", Modifier.weight(1f)) {
                                viewModel.saveMcpTunnel(config.tunnelHostId, it)
                            }
                        }
                    }
                }
            }

            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.mcp_setup_title), fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    val port = if (config.tunnelHostId != null) config.tunnelPort else config.port
                    val url = "http://127.0.0.1:$port${McpHttpServer.PATH}"
                    Text(stringResource(R.string.mcp_setup_where, servers.find { it.id == config.tunnelHostId }?.name ?: stringResource(R.string.mcp_setup_this_phone)), fontSize = 12.sp)
                    SelectionContainer {
                        Text(
                            stringResource(R.string.mcp_setup_commands, url),
                            fontFamily = OmniFonts.mono,
                            fontSize = 11.sp,
                            modifier = Modifier.testTag("mcp.setup"),
                        )
                    }
                }
            }

            SettingsCardHeader(stringResource(R.string.mcp_calls_header), "", OmniColors.cyan)
            if (calls.isEmpty()) {
                Text(stringResource(R.string.mcp_no_calls), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("mcp.calls.empty"))
            } else {
                calls.take(50).forEach { CallRow(it) }
                TextButton(onClick = viewModel::clearMcpCalls, modifier = Modifier.testTag("mcp.calls.clear")) { Text(stringResource(R.string.mcp_calls_clear)) }
            }
        }
    }

    if (turningOn || makingToken) {
        // A token is needed to turn the server on; making one needs the lock as turning on does.
        val needsToken = makingToken || config.tokenHash == null
        SensitiveActionDialog(
            viewModel = viewModel,
            key = if (makingToken) "mcp.token" else "mcp.enable",
            title = R.string.mcp_authenticate,
            question = stringResource(if (makingToken) R.string.mcp_token_question else R.string.mcp_enable_question),
            biometricSubtitle = R.string.confirm_it_s_you,
            noScreenLockText = R.string.mcp_no_screen_lock,
            onCancel = { turningOn = false; makingToken = false },
            onAuthenticated = {
                val enable = turningOn
                turningOn = false
                makingToken = false
                if (needsToken) viewModel.makeMcpToken { token -> newToken = token; if (enable) viewModel.saveMcpEnabled(true) }
                else if (enable) viewModel.saveMcpEnabled(true)
            },
            confirmTag = "mcp.confirm",
        )
    }
    newToken?.let { token ->
        TokenShownOnceDialog(token, onDone = { newToken = null }, onceText = stringResource(R.string.mcp_token_once), tag = "mcp.token")
    }
    if (revoking) {
        AlertDialog(
            onDismissRequest = { revoking = false },
            title = { Text(stringResource(R.string.mcp_revoke_title)) },
            text = { Text(stringResource(R.string.mcp_revoke_text)) },
            confirmButton = {
                TextButton(onClick = { viewModel.revokeMcpToken(); revoking = false }, modifier = Modifier.testTag("mcp.revoke.confirm")) {
                    Text(stringResource(R.string.automation_revoke), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { revoking = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun mcpStatusText(state: com.jetsetslow.omniterm.mcp.McpServerState): String = when {
    state.problem != null -> state.problem
    state.tunnelHost != null && state.tunnelUp -> stringResource(R.string.mcp_notification_via, state.tunnelHost, state.tunnelPort ?: 0)
    state.tunnelHost != null -> stringResource(R.string.mcp_status_tunnel_connecting, state.tunnelHost)
    state.port != null -> stringResource(R.string.mcp_notification_local, state.port)
    else -> stringResource(R.string.mcp_notification_starting)
}

@Composable
private fun ReachRow(label: String, selected: Boolean, tag: String, onPick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
        RadioButton(selected = selected, onClick = onPick, modifier = Modifier.testTag(tag))
        Text(label, fontSize = 13.sp)
    }
}

/** A port typed in full and saved when it is one a phone app may use; anything else is shown as wrong. */
@Composable
private fun PortField(label: String, port: Int, tag: String, modifier: Modifier, onSave: (Int) -> Unit) {
    var text by remember(port) { mutableStateOf(port.toString()) }
    val valid = McpSettings.port(text) != null
    OutlinedTextField(
        value = text,
        onValueChange = { next ->
            text = next.filter(Char::isDigit).take(5)
            McpSettings.port(text)?.takeIf { it != port }?.let(onSave)
        },
        label = { Text(label) },
        isError = !valid,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier.testTag(tag),
    )
}

@Composable
private fun CallRow(call: McpCallEntity) {
    val time = remember(call.at) { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(call.at)) }
    val outcome = when (call.outcome) {
        McpCallOutcome.OK -> stringResource(R.string.mcp_call_ok)
        McpCallOutcome.REFUSED -> stringResource(R.string.mcp_call_refused)
        else -> stringResource(R.string.mcp_call_failed)
    }
    val color = when (call.outcome) {
        McpCallOutcome.OK -> OmniColors.green
        else -> OmniColors.red
    }
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("mcp.call.${call.id}")) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row {
                Text(call.tool.ifEmpty { "—" }, fontFamily = OmniFonts.mono, fontSize = 12.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text(outcome, fontSize = 11.sp, color = color)
            }
            Text(listOf(time, call.client).filter { it.isNotBlank() }.joinToString(" · "), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (call.detail.isNotBlank()) Text(call.detail, fontSize = 11.sp, maxLines = 2)
        }
    }
}

/**
 * An assistant's request to run something, over whatever screen is showing: the command in full,
 * what the danger list makes of it, and the hosts. Approving needs App Lock or the screen lock;
 * denying, closing the dialog, or not answering in time all mean no.
 */
@Composable
fun McpApprovalDialog(viewModel: AppViewModel) {
    val pending by viewModel.mcpApprovals.collectAsStateWithLifecycle()
    val request = pending.firstOrNull() ?: return
    var authenticating by remember(request.id) { mutableStateOf(false) }
    LaunchedEffect(request.id) { authenticating = false }
    val r = request.request
    AlertDialog(
        onDismissRequest = {},
        modifier = Modifier.testTag("mcp.approval"),
        title = { Text(stringResource(R.string.mcp_approval_title, r.clientName)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.mcp_approval_hosts, r.hosts.joinToString(", ")), fontSize = 13.sp)
                Column(modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                    SelectionContainer {
                        Text(r.command, fontFamily = OmniFonts.mono, fontSize = 12.sp, modifier = Modifier.testTag("mcp.approval.command"))
                    }
                }
                if (r.dangerHits.isNotEmpty()) {
                    Text(
                        stringResource(R.string.mcp_approval_danger, r.dangerHits.joinToString(", ")),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("mcp.approval.danger"),
                    )
                }
                if (pending.size > 1) {
                    Text(stringResource(R.string.mcp_approval_more, pending.size - 1), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { authenticating = true }, modifier = Modifier.testTag("mcp.approval.approve")) {
                Text(stringResource(R.string.mcp_approval_approve))
            }
        },
        dismissButton = {
            TextButton(onClick = { viewModel.answerMcpApproval(request.id, false) }, modifier = Modifier.testTag("mcp.approval.deny")) {
                Text(stringResource(R.string.mcp_approval_deny))
            }
        },
    )
    if (authenticating) {
        SensitiveActionDialog(
            viewModel = viewModel,
            key = "mcp.approval.${request.id}",
            title = R.string.mcp_approval_authenticate,
            question = stringResource(R.string.mcp_approval_question, r.action, r.hosts.joinToString(", ")),
            biometricSubtitle = R.string.confirm_it_s_you,
            noScreenLockText = R.string.mcp_no_screen_lock,
            onCancel = { authenticating = false },
            onAuthenticated = {
                authenticating = false
                viewModel.answerMcpApproval(request.id, true)
            },
            confirmTag = "mcp.approval.confirm",
        )
    }
}
