package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.ScriptParams

/**
 * Asks for the values of a script's `{{placeholders}}` before it runs (see [ScriptParams]). Every
 * value is checked against each shell in [shells], the shells of the hosts it will run on, so a
 * value a Windows host cannot take safely is refused here rather than failing on that host.
 */
@Composable
fun ScriptParamsDialog(
    title: String,
    command: String,
    shells: Set<ScriptParams.Shell>,
    onDismiss: () -> Unit,
    onSubmit: (Map<String, String>) -> Unit,
) {
    val params = remember(command) { ScriptParams.parse(command) }
    val values = remember(command) { mutableStateMapOf<String, String>().apply { params.forEach { put(it.name, it.default) } } }
    fun problemFor(name: String): String? {
        val value = values[name].orEmpty()
        return shells.firstNotNullOfOrNull { ScriptParams.problem(name, value, it) }
    }
    val canRun = params.all { problemFor(it.name) == null }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.script_values_title, title)) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 420.dp).verticalScrollWithIndicators(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    stringResource(R.string.script_values_explained),
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                params.forEach { param ->
                    val problem = problemFor(param.name)
                    OutlinedTextField(
                        value = values[param.name].orEmpty(),
                        onValueChange = { values[param.name] = it },
                        label = { Text(param.name) },
                        singleLine = true,
                        isError = problem != null,
                        supportingText = problem?.let { message -> { Text(message) } },
                        modifier = Modifier.fillMaxWidth().testTag("script.param.${param.name}"),
                    )
                }
            }
        },
        confirmButton = {
            Button(
                enabled = canRun,
                onClick = { onSubmit(params.associate { it.name to values[it.name].orEmpty() }) },
                modifier = Modifier.testTag("script.params.next"),
            ) { Text(stringResource(R.string.next)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}
