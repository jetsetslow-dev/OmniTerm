package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.ui.theme.OmniColors

/** Named, wrapping choices preserve usable touch targets at larger font sizes and narrow widths. */
@Composable
internal fun HostColorPicker(selectedColor: String, onColorSelected: (String) -> Unit) {
    val selected = OmniColors.hostColorName(selectedColor)
    val colors = OmniColors.namedHostColors(MaterialTheme.colorScheme.surface)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.accent_color), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            (listOf("Default" to null) + colors).forEach { (name, color) ->
                val chosen = selected == name
                FilterChip(
                    selected = chosen,
                    onClick = { onColorSelected(name) },
                    label = { Text(if (name == "Default") stringResource(R.string.host_color_automatic) else name) },
                    leadingIcon = {
                        if (color != null) {
                            Box(Modifier.size(16.dp).clip(CircleShape).background(color))
                        } else if (chosen) {
                            Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                        }
                    },
                    trailingIcon = if (chosen && color != null) {
                        { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp)) }
                    } else null,
                    modifier = Modifier.testTag("host.color.$name"),
                )
            }
        }
        Text(
            stringResource(R.string.host_color_identity_hint),
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
