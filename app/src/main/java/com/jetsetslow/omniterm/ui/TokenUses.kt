package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.RunNotify
import com.jetsetslow.omniterm.data.UseOutcome
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Whether runs started with a token show a notification ([RunNotify]): one choice per automation
 * token, and one for the AI assistant. Chips tagged `[tag].off`, `[tag].failures` and `[tag].always`.
 */
@Composable
internal fun RunNotifyPicker(current: String, onPick: (String) -> Unit, tag: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.run_notify_title), fontWeight = FontWeight.Bold, fontSize = 13.sp)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (choice in RunNotify.ALL) {
                FilterChip(
                    selected = RunNotify.of(current) == choice,
                    onClick = { onPick(choice) },
                    label = { Text(runNotifyLabel(choice), fontSize = 12.sp) },
                    modifier = Modifier.testTag("$tag.$choice"),
                )
            }
        }
        Text(stringResource(R.string.run_notify_help), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun runNotifyLabel(choice: String): String = stringResource(
    when (choice) {
        RunNotify.OFF -> R.string.run_notify_off
        RunNotify.ALWAYS -> R.string.run_notify_always
        else -> R.string.run_notify_failures
    },
)

/**
 * One use of a token, in its history: [title] (an AI assistant's tool; none for an automation
 * token, which always runs its one script), when, [by] whom, and what came of it ([UseOutcome]).
 * A use that started a run opens it in Fleet's history.
 */
@Composable
internal fun TokenUseRow(
    at: Long,
    outcome: String,
    detail: String,
    runKey: String?,
    onOpenRun: (String) -> Unit,
    tag: String,
    title: String? = null,
    by: String = "",
) {
    val (label, color) = when (outcome) {
        UseOutcome.OK -> stringResource(R.string.token_use_ok) to OmniColors.green
        UseOutcome.REFUSED -> stringResource(R.string.token_use_refused) to OmniColors.amber
        else -> stringResource(R.string.token_use_failed) to OmniColors.red
    }
    val time = formatShortDateTime(at)
    OmniCard(
        modifier = Modifier.fillMaxWidth().testTag(tag),
        leftAccent = color,
        onClick = runKey?.let { key -> { onOpenRun(key) } },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row {
                Text(
                    title?.ifEmpty { "—" } ?: time,
                    fontFamily = if (title != null) OmniFonts.mono else null,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                Text(label, fontSize = 11.sp, color = color, modifier = Modifier.testTag("$tag.outcome"))
            }
            val meta = listOfNotNull(time.takeIf { title != null }, by.takeIf { it.isNotBlank() })
            if (meta.isNotEmpty()) {
                Text(meta.joinToString(" · "), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (detail.isNotBlank()) Text(detail, fontSize = 11.sp, maxLines = 2)
            if (runKey != null) {
                Text(
                    stringResource(R.string.token_use_open_run),
                    fontSize = 11.sp,
                    color = OmniColors.cyan,
                    modifier = Modifier.testTag("$tag.run"),
                )
            }
        }
    }
}
