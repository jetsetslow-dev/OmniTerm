package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.RemoteCommands

/**
 * Puts a saved key on hosts, as `ssh-copy-id` does: which key, which hosts, and whether they sign
 * in with it from then on; then each host's result. Install asks for App Lock or the screen lock
 * first, since the key then opens those hosts.
 */
@Composable
internal fun KeyInstallDialog(viewModel: AppViewModel) {
    val request = viewModel.keyInstallRequest ?: return
    val keys by viewModel.keys.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var keyAlias by remember(request) { mutableStateOf(request.keyAlias ?: keys.singleOrNull()?.alias) }
    val picked = remember(request) { mutableStateListOf<Int>().apply { addAll(request.serverIds) } }
    var useForSignIn by remember(request) { mutableStateOf(false) }
    var authenticating by remember(request) { mutableStateOf(false) }
    val running = viewModel.keyInstallRunning
    val started = running || viewModel.keyInstallResults.isNotEmpty()

    AlertDialog(
        onDismissRequest = { if (!running) viewModel.closeKeyInstall() },
        modifier = Modifier.testTag("keyInstall.dialog"),
        title = { Text(stringResource(R.string.key_install_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.key_install_explainer), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.key_install_key), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
                if (keys.isEmpty()) Text(stringResource(R.string.key_install_no_keys), style = MaterialTheme.typography.bodySmall)
                keys.forEach { key ->
                    Row(
                        Modifier.fillMaxWidth()
                            .selectable(selected = key.alias == keyAlias, enabled = !started, role = Role.RadioButton) { keyAlias = key.alias }
                            .testTag("keyInstall.key.${key.id}"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = key.alias == keyAlias, onClick = null, enabled = !started)
                        Text(key.alias, modifier = Modifier.padding(start = 8.dp))
                    }
                }
                Text(stringResource(R.string.key_install_hosts), style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
                servers.forEach { srv ->
                    // A known Windows host is shown, not offered: its keys live elsewhere.
                    val windows = !RemoteCommands.hasUnixShell(viewModel.knownOs(srv))
                    Column(Modifier.fillMaxWidth()) {
                        Row(
                            Modifier.fillMaxWidth()
                                .toggleable(value = srv.id in picked, enabled = !started && !windows, role = Role.Checkbox) { on ->
                                    if (on) picked.add(srv.id) else picked.remove(srv.id)
                                }
                                .testTag("keyInstall.host.${srv.id}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(checked = srv.id in picked, onCheckedChange = null, enabled = !started && !windows)
                            Column(Modifier.padding(start = 8.dp)) {
                                Text(HostDisplay.name(srv))
                                if (windows) Text(stringResource(R.string.key_install_windows), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        viewModel.keyInstallResults[srv.id]?.let { result ->
                            Text(
                                result.text,
                                style = MaterialTheme.typography.bodySmall,
                                color = if (result.ok) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(start = 48.dp).testTag("keyInstall.result.${srv.id}"),
                            )
                        }
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(top = 8.dp)
                        .toggleable(value = useForSignIn, enabled = !started, role = Role.Checkbox) { useForSignIn = it }
                        .testTag("keyInstall.use"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = useForSignIn, onCheckedChange = null, enabled = !started)
                    Text(stringResource(R.string.key_install_use_for_sign_in), modifier = Modifier.padding(start = 8.dp))
                }
            }
        },
        confirmButton = {
            if (!started) {
                TextButton(
                    enabled = keyAlias != null && picked.isNotEmpty(),
                    onClick = { authenticating = true },
                    modifier = Modifier.testTag("keyInstall.run"),
                ) { Text(stringResource(R.string.key_install_run)) }
            } else {
                TextButton(enabled = !running, onClick = viewModel::closeKeyInstall, modifier = Modifier.testTag("keyInstall.done")) {
                    Text(stringResource(if (running) R.string.key_install_running else R.string.done))
                }
            }
        },
        dismissButton = {
            if (!started) TextButton(onClick = viewModel::closeKeyInstall) { Text(stringResource(R.string.cancel)) }
        },
    )

    val alias = keyAlias
    if (authenticating && alias != null) {
        val names = servers.filter { it.id in picked }.joinToString(", ") { HostDisplay.name(it) }
        SensitiveActionDialog(
            viewModel = viewModel,
            key = Triple(alias, picked.toList(), useForSignIn),
            title = R.string.key_install_authenticate,
            question = stringResource(R.string.key_install_question, alias, names),
            biometricSubtitle = R.string.confirm_it_s_you,
            noScreenLockText = R.string.key_install_no_screen_lock,
            onCancel = { authenticating = false },
            onAuthenticated = {
                authenticating = false
                viewModel.installKey(alias, picked.toList(), useForSignIn)
            },
            confirmTag = "keyInstall.confirm",
        )
    }
}
