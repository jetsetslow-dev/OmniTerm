package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.R

@Composable
internal fun TerminalTypingBanner(viewModel: AppViewModel, session: ShellSession) {
    val typing = viewModel.terminalTyping
    if (!typing.enabled) return
    val selected = viewModel.activeSessions.filter { it.id in typing.selectedIds }
    val receiving = selected.count { typing.exclusion(it) == null }
    val leftOut = typing.exclusion(session)
    Surface(color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
        modifier = Modifier.fillMaxWidth().testTag("terminal.typing.banner.${session.id}")
            .clickable { viewModel.showTerminalTypingPicker = true }) {
        Text(
            pluralStringResource(R.plurals.typing_to_terminals, receiving, receiving) +
                if (session.id !in typing.selectedIds) " · " + stringResource(R.string.typing_not_selected)
                else if (leftOut != null) " · " + stringResource(R.string.typing_left_out, leftOut) else "",
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelLarge,
        )
    }
}

@Composable
internal fun TerminalTypingPicker(viewModel: AppViewModel) {
    if (!viewModel.showTerminalTypingPicker) return
    val typing = viewModel.terminalTyping
    val sessions = viewModel.activeSessions.toList()
    var picked by remember { mutableStateOf(typing.selectedIds) }
    fun dismiss() { viewModel.showTerminalTypingPicker = false }
    AlertDialog(
        onDismissRequest = { dismiss() },
        title = { Text(stringResource(R.string.type_to_terminals)) },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.typing_warning))
                TextButton(onClick = { picked = sessions.map { it.id }.toSet() },
                    modifier = Modifier.testTag("terminal.typing.all")) {
                    Text(stringResource(R.string.typing_all_open))
                }
                sessions.forEach { session ->
                    val reason = typing.exclusion(session)
                    Row(Modifier.fillMaxWidth().testTag("terminal.typing.pick.${session.id}")
                        .clickable { picked = if (session.id in picked) picked - session.id else picked + session.id }) {
                        Checkbox(checked = session.id in picked, onCheckedChange = null)
                        Column(Modifier.weight(1f).padding(start = 8.dp)) {
                            Text(session.serverName)
                            Text(reason?.let { stringResource(R.string.typing_left_out, it) }
                                ?: if (session.id in typing.selectedIds) stringResource(R.string.typing_receiving)
                                else stringResource(R.string.typing_available), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { viewModel.selectTerminalTyping(picked); dismiss() },
                enabled = picked.isNotEmpty(), modifier = Modifier.testTag("terminal.typing.apply")) {
                Text(stringResource(R.string.typing_use_selection))
            }
        },
        dismissButton = {
            Row {
                if (typing.enabled) TextButton(onClick = { viewModel.stopTerminalTyping(); dismiss() },
                    modifier = Modifier.testTag("terminal.typing.stop")) { Text(stringResource(R.string.turn_off)) }
                TextButton(onClick = { dismiss() }) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}
