package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.R

/**
 * An `ssh://` link another app opened: what it names, the saved hosts it matches, and adding it as
 * a new host. Nothing connects or is saved until the user picks one.
 */
@Composable
internal fun SshLinkDialog(viewModel: AppViewModel) {
    val link = viewModel.pendingSshLink ?: return
    val matches = viewModel.sshLinkMatches
    AlertDialog(
        onDismissRequest = viewModel::dismissSshLink,
        modifier = Modifier.testTag("sshLink.dialog"),
        title = { Text(stringResource(R.string.ssh_link_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(link.label, fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("sshLink.address"))
                Text(
                    stringResource(if (matches.isEmpty()) R.string.ssh_link_no_match else R.string.ssh_link_matches),
                    style = MaterialTheme.typography.bodySmall,
                )
                matches.forEach { srv ->
                    OutlinedButton(
                        onClick = { viewModel.connectSshLinkHost(srv.id) },
                        modifier = Modifier.fillMaxWidth().testTag("sshLink.connect.${srv.id}"),
                    ) {
                        Text(stringResource(R.string.ssh_link_connect, srv.name), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = viewModel::addSshLinkHost, modifier = Modifier.testTag("sshLink.add")) {
                Text(stringResource(R.string.ssh_link_add))
            }
        },
        dismissButton = { TextButton(onClick = viewModel::dismissSshLink) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Files another app shared, waiting to be uploaded. With [onUpload] (SFTP → Files, in the folder
 * the user opened) it offers Upload here; without, it says where to go.
 */
@Composable
internal fun SharedFilesBar(viewModel: AppViewModel, onUpload: (() -> Unit)?) {
    val count = viewModel.sharedUploads.size
    if (count == 0) return
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = MaterialTheme.shapes.small,
        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp).testTag("sftp.shared.bar"),
    ) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (onUpload != null) pluralStringResource(R.plurals.sftp_shared_files_here, count, count)
                else pluralStringResource(R.plurals.sftp_shared_files_waiting, count, count),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f),
            )
            if (onUpload != null) {
                TextButton(onClick = onUpload, modifier = Modifier.testTag("sftp.shared.upload")) { Text(stringResource(R.string.sftp_shared_upload)) }
            }
            TextButton(onClick = { viewModel.takeSharedUploads() }, modifier = Modifier.testTag("sftp.shared.cancel")) { Text(stringResource(R.string.cancel)) }
        }
    }
}
