package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Picks one of [scripts], searchable by name and command, each row showing its command and the
 * target it is limited to. Fleet's preset picker and the alert rule's script and runbook pickers
 * all use it. [noneLabel], when given, adds a first row that picks no script ([onPick] with null).
 * [emptyText] is shown when there are no scripts at all.
 */
@Composable
fun ScriptPickerDialog(
    title: String,
    scripts: List<QuickScriptEntity>,
    emptyText: String,
    onPick: (QuickScriptEntity?) -> Unit,
    onDismiss: () -> Unit,
    noneLabel: String? = null,
) {
    var search by remember { mutableStateOf("") }
    val query = search.trim()
    val shown = scripts.filter {
        query.isBlank() || it.name.contains(query, ignoreCase = true) || it.command.contains(query, ignoreCase = true)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    label = { Text(stringResource(R.string.search_presets)) },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("scriptPicker.search"),
                )
                if (noneLabel != null && query.isBlank()) {
                    ListItem(
                        headlineContent = { Text(noneLabel, fontWeight = FontWeight.Bold) },
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onPick(null) }.testTag("scriptPicker.none"),
                    )
                }
                if (shown.isEmpty()) {
                    Text(
                        if (scripts.isEmpty()) emptyText else stringResource(R.string.no_presets_match_your_search),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    OverflowLazyColumn(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        items(shown, key = { it.id }) { script ->
                            ListItem(
                                headlineContent = { Text("${script.emoji} ${script.name}", fontWeight = FontWeight.Bold) },
                                trailingContent = if (scriptTargetsAnyHost(script)) null else {
                                    { OmniTag(scriptTargetLabel(script), color = OmniColors.amber) }
                                },
                                supportingContent = {
                                    Text(
                                        script.command,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                        fontFamily = OmniFonts.mono,
                                        fontSize = 11.sp,
                                    )
                                },
                                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onPick(script) },
                            )
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
    )
}
