package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors

/** A tool screen's scrolling column of cards, as Automation and AI assistants lay them out. */
@Composable
internal fun ToolCardColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp).verticalScrollWithIndicators(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

/**
 * The card that heads a tool which is off until the user turns it on: its name, what it does,
 * the switch (tagged [switchTag]), and whatever the tool says under it ([below]).
 */
@Composable
internal fun ToolSwitchCard(
    title: String,
    help: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    switchTag: String,
    below: @Composable ColumnScope.() -> Unit = {},
) {
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Text(help, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = checked, onCheckedChange = onCheckedChange, modifier = Modifier.testTag(switchTag))
            }
            below()
        }
    }
}
