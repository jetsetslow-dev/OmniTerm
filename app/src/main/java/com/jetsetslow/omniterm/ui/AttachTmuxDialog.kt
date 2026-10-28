package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteTmuxSession
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/** Hosts ⋮ › Attach existing tmux…: the tmux sessions running on a host, to attach one here. */
@Composable
fun AttachTmuxDialog(viewModel: AppViewModel) {
    val srv = viewModel.tmuxAttachServer ?: return
    val listing = viewModel.tmuxAttachListing
    Dialog(onDismissRequest = viewModel::dismissAttachTmux, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            modifier = Modifier.padding(horizontal = 16.dp).widthIn(max = 560.dp).fillMaxWidth().testTag("tmux.attach.dialog"),
            shape = RoundedCornerShape(14.dp),
            tonalElevation = 8.dp,
        ) {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.tmux_sessions_on, srv.name), style = MaterialTheme.typography.titleLarge)
                val sessions = listing.sessions
                when {
                    listing.loading -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.listing_tmux_sessions), fontSize = OmniTextSize.Dense)
                    }
                    listing.error != null -> Text(
                        listing.error,
                        color = OmniColors.red,
                        fontSize = OmniTextSize.Dense,
                        modifier = Modifier.testTag("tmux.attach.error"),
                    )
                    sessions == null -> Text(stringResource(R.string.tmux_is_not_installed_on, srv.name), fontSize = OmniTextSize.Dense)
                    sessions.isEmpty() -> Text(
                        stringResource(R.string.no_tmux_sessions_are_running_on, srv.name),
                        fontSize = OmniTextSize.Dense,
                        modifier = Modifier.testTag("tmux.attach.none"),
                    )
                    else -> {
                        Text(stringResource(R.string.attaching_joins_the_session_itself), fontSize = OmniTextSize.Meta)
                        LazyColumn(Modifier.heightIn(max = 420.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            items(sessions, key = { it.name }) { session -> TmuxSessionRow(viewModel, srv, session) }
                        }
                    }
                }
                Row(Modifier.align(Alignment.End)) {
                    TextButton(
                        onClick = viewModel::refreshAttachTmux,
                        enabled = !listing.loading,
                        modifier = Modifier.testTag("tmux.attach.refresh"),
                    ) { Text(stringResource(R.string.retry)) }
                    TextButton(onClick = viewModel::dismissAttachTmux, modifier = Modifier.testTag("tmux.attach.close")) {
                        Text(stringResource(R.string.close))
                    }
                }
            }
        }
    }
}

@Composable
private fun TmuxSessionRow(viewModel: AppViewModel, srv: ServerEntity, session: RemoteTmuxSession) {
    val attachable = RemoteCommands.isAttachableTmuxName(session.name)
    val windows = if (session.windows == 1) {
        stringResource(R.string.tmux_one_window)
    } else {
        stringResource(R.string.tmux_windows, session.windows)
    }
    val state = when {
        viewModel.isTmuxSessionOpen(srv.id, session.name) -> stringResource(R.string.tmux_open_here)
        session.attachedClients > 0 -> stringResource(R.string.tmux_attached_elsewhere)
        else -> stringResource(R.string.tmux_detached)
    }
    OmniCard(
        modifier = Modifier.fillMaxWidth().testTag("tmux.attach.session.${session.name}"),
        leftAccent = if (attachable) OmniColors.cyan else null,
        onClick = if (attachable) {
            {
                viewModel.attachHostTmuxSession(session)
                viewModel.navigateTo(Screen.Shell)
            }
        } else {
            null
        },
    ) {
        Column(Modifier.padding(10.dp)) {
            Text(session.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = OmniTextSize.Body)
            Text(
                listOf(windows, state, stringResource(R.string.started_ago, formatSessionAge(session.createdAtMs))).joinToString(" · "),
                fontSize = OmniTextSize.Meta,
                fontFamily = OmniFonts.mono,
            )
            if (!attachable) {
                Text(stringResource(R.string.rename_this_tmux_session_to_attach), fontSize = OmniTextSize.Meta, color = OmniColors.amber)
            }
        }
    }
}
