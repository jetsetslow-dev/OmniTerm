package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * A find field with its match count, previous, next and close. The code editor's find bar and the
 * terminal's share it. [currentIndex] is zero-based; the count reads "3/12", or "0/0" when the
 * query finds nothing. [onSearch], when given, runs on the keyboard's search key.
 */
@Composable
internal fun FindFieldRow(
    query: String,
    onQuery: (String) -> Unit,
    matchCount: Int,
    currentIndex: Int,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    fieldModifier: Modifier = Modifier,
    onSearch: (() -> Unit)? = null,
) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        FindBarInput(query, onQuery, "Find", Modifier.weight(1f), fieldModifier, onSearch)
        Spacer(Modifier.width(6.dp))
        val countLabel = if (query.isEmpty()) "" else if (matchCount == 0) "0/0" else "${currentIndex + 1}/$matchCount"
        Text(countLabel, fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
        IconButton(onClick = onPrev, enabled = matchCount > 0) {
            Icon(Icons.Filled.ArrowUpward, contentDescription = stringResource(R.string.previous_match), modifier = Modifier.width(18.dp))
        }
        IconButton(onClick = onNext, enabled = matchCount > 0) {
            Icon(Icons.Filled.ArrowDownward, contentDescription = stringResource(R.string.next_match), modifier = Modifier.width(18.dp))
        }
        IconButton(onClick = onClose) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.close_find))
        }
    }
}

/** The single-line field of a find bar, with [hint] shown while it is empty. */
@Composable
internal fun FindBarInput(
    value: String,
    onChange: (String) -> Unit,
    hint: String,
    modifier: Modifier,
    fieldModifier: Modifier = Modifier,
    onSearch: (() -> Unit)? = null,
) {
    Box(
        modifier = modifier
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        if (value.isEmpty()) {
            Text(hint, fontSize = 12.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = SolidColor(OmniColors.amber),
            keyboardOptions = if (onSearch != null) KeyboardOptions(imeAction = ImeAction.Search) else KeyboardOptions.Default,
            keyboardActions = KeyboardActions(onSearch = { onSearch?.invoke() }),
            modifier = Modifier.fillMaxWidth().then(fieldModifier),
        )
    }
}
