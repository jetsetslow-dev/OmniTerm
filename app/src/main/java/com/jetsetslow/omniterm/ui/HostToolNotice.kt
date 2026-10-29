package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.HostTool
import com.jetsetslow.omniterm.data.ServerEntity

/**
 * Says what installing [tool] on [srv] would show, with a button that installs it there (behind the
 * sudo check, output in the shared action panel, which the user closes) and then reads again
 * through [onInstalled]. Every "install this on the host" notice in the app is this one.
 */
@Composable
fun HostToolNotice(
    viewModel: AppViewModel,
    srv: ServerEntity,
    tool: HostTool,
    text: String,
    modifier: Modifier = Modifier,
    onInstalled: () -> Unit,
) {
    Column(modifier) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta)
        OutlinedButton(
            onClick = { viewModel.installHostTool(srv, tool, onInstalled) },
            modifier = Modifier.padding(top = 6.dp).testTag("install.${tool.name}"),
        ) {
            Text(stringResource(R.string.install_tool, tool.displayName))
        }
    }
}
