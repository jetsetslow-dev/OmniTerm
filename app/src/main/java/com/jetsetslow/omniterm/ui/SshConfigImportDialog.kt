package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.SshConfigFile
import com.jetsetslow.omniterm.data.SshConfigHost
import com.jetsetslow.omniterm.ui.theme.OmniColors

/**
 * The hosts an ssh_config file names, to pick from and save. Hosts that are already saved start
 * unticked. Where the file sets no user, one field supplies it for all of them. After saving, the
 * dialog says what was imported and what was not.
 */
@Composable
fun SshConfigImportDialog(viewModel: AppViewModel, file: SshConfigFile, onDismiss: () -> Unit) {
    val saved by viewModel.servers.collectAsStateWithLifecycle()
    fun alreadySaved(host: SshConfigHost) = saved.any {
        it.host.equals(host.hostName, ignoreCase = true) && it.port == host.port &&
            (host.user.isBlank() || it.username == host.user)
    }
    val chosen = remember(file) { mutableStateListOf<SshConfigHost>().apply { addAll(file.hosts.filterNot(::alreadySaved)) } }
    var defaultUser by remember(file) { mutableStateOf("") }
    var importing by remember(file) { mutableStateOf(false) }
    var result by remember(file) { mutableStateOf<String?>(null) }
    val needsUser = chosen.any { it.user.isBlank() }

    AlertDialog(
        onDismissRequest = { if (!importing) onDismiss() },
        title = { Text(stringResource(R.string.import_from_ssh_config)) },
        text = {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 520.dp).verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when {
                    result != null -> Text(result.orEmpty(), modifier = Modifier.testTag("sshConfigImport.result"))
                    file.hosts.isEmpty() -> Text(stringResource(R.string.no_hosts_found_in_this_file))
                    else -> {
                        file.hosts.forEach { host ->
                            SshConfigHostRow(
                                host = host,
                                checked = host in chosen,
                                alreadySaved = alreadySaved(host),
                                onCheckedChange = { on -> if (on) chosen += host else chosen -= host },
                            )
                        }
                        if (needsUser) {
                            OutlinedTextField(
                                value = defaultUser,
                                onValueChange = { defaultUser = it },
                                label = { Text(stringResource(R.string.user_for_hosts_that_set_none)) },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth().testTag("sshConfigImport.defaultUser"),
                            )
                        }
                        if (viewModel.hasHostLimit) {
                            Text(stringResource(R.string.free_play_store_build_is_limited), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (result == null && file.skipped.isNotEmpty()) {
                    HorizontalDivider()
                    file.skipped.forEach { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        },
        confirmButton = {
            if (result != null || file.hosts.isEmpty()) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.done)) }
            } else {
                TextButton(
                    enabled = !importing && chosen.isNotEmpty() && (!needsUser || defaultUser.isNotBlank()),
                    onClick = {
                        importing = true
                        // In file order, whatever order they were ticked in.
                        viewModel.importSshConfigHosts(file.hosts.filter { it in chosen }, defaultUser) { summary ->
                            importing = false
                            result = summary
                        }
                    },
                ) { Text(stringResource(R.string.import_n_hosts, chosen.size)) }
            }
        },
        dismissButton = {
            if (result == null && file.hosts.isNotEmpty()) {
                TextButton(onClick = onDismiss, enabled = !importing) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}

@Composable
private fun SshConfigHostRow(host: SshConfigHost, checked: Boolean, alreadySaved: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Checkbox, onValueChange = onCheckedChange)
            .testTag("sshConfigImport.host.${host.alias}"),
        verticalAlignment = Alignment.Top,
    ) {
        Checkbox(checked = checked, onCheckedChange = null)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(host.alias, fontWeight = FontWeight.Bold)
            val user = host.user.ifBlank { "?" }
            val port = if (host.port == 22) "" else ":${host.port}"
            val via = host.jump?.let { " via ${it.host}" }.orEmpty()
            Text("$user@${host.hostName}$port$via", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (alreadySaved) Text(stringResource(R.string.already_saved), fontSize = 12.sp, color = OmniColors.amber)
            host.notes.forEach { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
