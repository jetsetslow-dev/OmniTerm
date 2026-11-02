package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue

/** How many lines a long path wraps onto before the field scrolls. */
private const val PATH_FIELD_MAX_LINES = 4

/**
 * A field for a file path. A long path wraps onto more lines instead of running off the edge,
 * where a one-line field left its end out of reach, and the cursor starts at the end, where edits
 * to a path usually go. Line breaks never get in; the keyboard's action key does [onImeAction].
 * With [autofocus] it takes the keyboard as soon as it shows, for a field opened to be typed in.
 */
@Composable
fun PathTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    textStyle: TextStyle = LocalTextStyle.current,
    leadingIcon: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    imeAction: ImeAction = ImeAction.Done,
    onImeAction: () -> Unit = {},
    colors: TextFieldColors = OutlinedTextFieldDefaults.colors(),
    autofocus: Boolean = false,
) {
    val focus = remember { FocusRequester() }
    if (autofocus) LaunchedEffect(Unit) { focus.requestFocus() }
    var field by remember { mutableStateOf(TextFieldValue(value, TextRange(value.length))) }
    // A change from outside (a picker, a reset) shows with the cursor at its end.
    val shown = if (field.text == value) field else TextFieldValue(value, TextRange(value.length))
    OutlinedTextField(
        value = shown,
        onValueChange = { next ->
            val text = next.text.filterNot { it == '\n' || it == '\r' }
            field = if (text == next.text) next else TextFieldValue(text, TextRange(text.length))
            if (text != value) onValueChange(text)
        },
        modifier = modifier.focusRequester(focus),
        label = label,
        placeholder = placeholder,
        textStyle = textStyle,
        leadingIcon = leadingIcon,
        trailingIcon = trailingIcon,
        singleLine = false,
        maxLines = PATH_FIELD_MAX_LINES,
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = imeAction),
        keyboardActions = KeyboardActions(onAny = { onImeAction() }),
        colors = colors,
    )
}
