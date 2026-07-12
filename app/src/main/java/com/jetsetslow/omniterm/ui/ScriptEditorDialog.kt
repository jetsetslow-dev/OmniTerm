package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.data.QuickScriptEntity

data class ScriptEditorDraft(
    val emoji: String,
    val name: String,
    val command: String,
    val category: String,
    val availableForQuick: Boolean,
    val availableForFleet: Boolean,
    val targetOs: String,
    val targetSystem: String,
    val notes: String,
)

@Composable
fun SharedScriptEditorDialog(
    existing: QuickScriptEntity?,
    title: String,
    initialCommand: String = "",
    initialCategory: String = "General",
    defaultAvailableForQuick: Boolean = true,
    defaultAvailableForFleet: Boolean = false,
    defaultTargetOs: String = "Any",
    knownCategories: List<String> = emptyList(),
    onDismiss: () -> Unit,
    onSave: (ScriptEditorDraft) -> Unit,
) {
    var nameInput by remember { mutableStateOf(existing?.name ?: "") }
    var emojiInput by remember { mutableStateOf(existing?.emoji ?: "CMD") }
    var cmdInput by remember { mutableStateOf(existing?.command ?: initialCommand) }
    var categoryInput by remember {
        mutableStateOf(existing?.category?.ifBlank { "General" } ?: initialCategory.ifBlank { "General" })
    }
    var availableForQuick by remember { mutableStateOf(existing?.availableForQuick ?: defaultAvailableForQuick) }
    var availableForFleet by remember { mutableStateOf(existing?.availableForFleet ?: defaultAvailableForFleet) }
    var targetOs by remember { mutableStateOf(existing?.targetOs?.ifBlank { "Any" } ?: defaultTargetOs.ifBlank { "Any" }) }
    var targetSystem by remember { mutableStateOf(existing?.targetSystem?.ifBlank { "Any" } ?: "Any") }
    var notesInput by remember { mutableStateOf(existing?.notes ?: "") }
    var categoryMenuExpanded by remember { mutableStateOf(false) }
    var osMenuExpanded by remember { mutableStateOf(false) }
    var systemMenuExpanded by remember { mutableStateOf(false) }

    val isDirty = remember(nameInput, emojiInput, cmdInput, categoryInput, availableForQuick, availableForFleet, targetOs, targetSystem, notesInput) {
        val ogName = existing?.name ?: ""
        val ogEmoji = existing?.emoji ?: "CMD"
        val ogCmd = existing?.command ?: initialCommand
        val ogCat = existing?.category?.ifBlank { "General" } ?: initialCategory.ifBlank { "General" }
        val ogQuick = existing?.availableForQuick ?: defaultAvailableForQuick
        val ogFleet = existing?.availableForFleet ?: defaultAvailableForFleet
        val ogOs = existing?.targetOs?.ifBlank { "Any" } ?: defaultTargetOs.ifBlank { "Any" }
        val ogSys = existing?.targetSystem?.ifBlank { "Any" } ?: "Any"
        val ogNotes = existing?.notes ?: ""

        nameInput != ogName || emojiInput != ogEmoji || cmdInput != ogCmd || categoryInput != ogCat ||
        availableForQuick != ogQuick || availableForFleet != ogFleet || targetOs != ogOs ||
        targetSystem != ogSys || notesInput != ogNotes
    }

    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    fun attemptDismiss() {
        if (isDirty) {
            confirm.ask("Discard changes?", "You have unsaved edits to this script. Discard them?", confirmLabel = "Discard") {
                onDismiss()
            }
        } else {
            onDismiss()
        }
    }

    AlertDialog(
        onDismissRequest = { attemptDismiss() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = emojiInput,
                    onValueChange = { emojiInput = it.take(6).uppercase() },
                    label = { Text("Shortcut label") },
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = nameInput,
                    onValueChange = { nameInput = it },
                    label = { Text("Script name") },
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = cmdInput,
                    onValueChange = { cmdInput = it },
                    label = { Text("Command") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                )
                Box(modifier = Modifier.fillMaxWidth()) {
                    OutlinedTextField(
                        value = categoryInput,
                        onValueChange = { categoryInput = it },
                        label = { Text("Category / group") },
                        modifier = Modifier.fillMaxWidth(),
                        trailingIcon = {
                            IconButton(onClick = { categoryMenuExpanded = true }) {
                                Icon(Icons.Filled.ArrowDropDown, "Pick existing category")
                            }
                        },
                    )
                    DropdownMenu(expanded = categoryMenuExpanded, onDismissRequest = { categoryMenuExpanded = false }) {
                        knownCategories.forEach { cat ->
                            DropdownMenuItem(text = { Text(cat) }, onClick = { categoryInput = cat; categoryMenuExpanded = false })
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = availableForQuick, onCheckedChange = { availableForQuick = it })
                        Text("Quick")
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = availableForFleet, onCheckedChange = { availableForFleet = it })
                        Text("Fleet")
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(modifier = Modifier.weight(1f)) {
                        OutlinedTextField(
                            value = targetOs,
                            onValueChange = { targetOs = it },
                            label = { Text("Quick OS") },
                            enabled = availableForQuick,
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                IconButton(onClick = { osMenuExpanded = true }, enabled = availableForQuick) {
                                    Icon(Icons.Filled.ArrowDropDown, "Pick OS")
                                }
                            },
                        )
                        DropdownMenu(expanded = osMenuExpanded, onDismissRequest = { osMenuExpanded = false }) {
                            quickScriptOsOptions.forEach { os ->
                                DropdownMenuItem(text = { Text(os) }, onClick = { targetOs = os; osMenuExpanded = false })
                            }
                        }
                    }
                    Box(modifier = Modifier.weight(1f)) {
                        OutlinedTextField(
                            value = targetSystem,
                            onValueChange = { targetSystem = it },
                            label = { Text("Quick system") },
                            enabled = availableForQuick,
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                IconButton(onClick = { systemMenuExpanded = true }, enabled = availableForQuick) {
                                    Icon(Icons.Filled.ArrowDropDown, "Pick system")
                                }
                            },
                        )
                        DropdownMenu(expanded = systemMenuExpanded, onDismissRequest = { systemMenuExpanded = false }) {
                            quickScriptSystemOptions.forEach { system ->
                                DropdownMenuItem(text = { Text(system) }, onClick = { targetSystem = system; systemMenuExpanded = false })
                            }
                        }
                    }
                }
                OutlinedTextField(
                    value = notesInput,
                    onValueChange = { notesInput = it },
                    label = { Text("Notes (optional)") },
                    placeholder = { Text("What this script does, caveats, etc.") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                )
            }
        },
        confirmButton = {
            Button(
                enabled = nameInput.isNotBlank() && cmdInput.isNotBlank() && (availableForQuick || availableForFleet),
                onClick = {
                    onSave(
                        ScriptEditorDraft(
                            emoji = emojiInput.ifBlank { "CMD" },
                            name = nameInput.trim(),
                            command = cmdInput.trim(),
                            category = categoryInput.ifBlank { "General" }.trim(),
                            availableForQuick = availableForQuick,
                            availableForFleet = availableForFleet,
                            targetOs = targetOs.ifBlank { "Any" },
                            targetSystem = targetSystem.ifBlank { "Any" },
                            notes = notesInput.trim(),
                        )
                    )
                },
            ) {
                Text(if (existing != null) "Save changes" else "Save")
            }
        },
        dismissButton = {
            TextButton(onClick = { attemptDismiss() }) { Text("Cancel") }
        },
    )
}
