package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FindReplace
import androidx.compose.material.icons.automirrored.filled.WrapText
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Reusable monospace code editor with a line-number gutter and a collapsible find / find-and-replace
 * bar (next/prev with match count, replace, replace all, case-sensitive + regex toggles, and go to
 * line). Used by the SFTP remote file editor and the Compose Builder's Raw YAML editor so both share
 * one implementation.
 *
 * Works on a plain [String] [value] so call sites don't have to manage [TextFieldValue]; the cursor
 * position is tracked internally only as far as find/go-to-line need it.
 */
@Composable
fun CodeEditor(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    fontSize: androidx.compose.ui.unit.TextUnit = 13.sp,
    language: CodeLanguage = CodeLanguage.NONE,
    /** Max chars to highlight before falling back to plain text (user-configurable; 0 disables). */
    highlightMaxChars: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
) {
    // Internal TextFieldValue keeps the selection/cursor in sync so find and go-to-line can move it.
    // Kept aligned to the external [value] string whenever the parent changes it out from under us.
    var field by remember { mutableStateOf(TextFieldValue(value)) }
    if (field.text != value) {
        val newSelection = if (value.length < field.selection.start) TextRange(value.length) else field.selection
        field = field.copy(text = value, selection = newSelection)
    }

    var showFind by remember { mutableStateOf(false) }
    var wrap by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var replacement by remember { mutableStateOf("") }
    var caseSensitive by remember { mutableStateOf(false) }
    var useRegex by remember { mutableStateOf(false) }
    var regexError by remember { mutableStateOf<String?>(null) }
    var scrollToCursorTrigger by remember { mutableStateOf(0) }

    val matches = remember(value, query, caseSensitive, useRegex) {
        regexError = null
        if (query.isEmpty()) emptyList()
        else runCatching { findMatches(value, query, caseSensitive, useRegex) }
            .getOrElse { regexError = "Invalid pattern"; emptyList() }
    }
    // Which match the cursor is on (or the next one after it).
    val currentMatchIndex = remember(field.selection, matches) {
        if (matches.isEmpty()) -1
        else matches.indexOfFirst { it.first >= field.selection.min }.let { if (it < 0) 0 else it }
    }

    fun selectMatch(index: Int) {
        if (matches.isEmpty()) return
        val m = matches[(index % matches.size + matches.size) % matches.size]
        field = field.copy(selection = TextRange(m.first, m.second))
        scrollToCursorTrigger++
    }

    fun replaceCurrent() {
        if (matches.isEmpty() || currentMatchIndex !in matches.indices) return
        val (start, end) = matches[currentMatchIndex]
        val next = value.substring(0, start) + replacement + value.substring(end)
        onValueChange(next)
        field = field.copy(selection = TextRange(start + replacement.length))
        scrollToCursorTrigger++
    }

    fun replaceAll() {
        if (query.isEmpty()) return
        val next = runCatching {
            if (useRegex) {
                val opts = if (caseSensitive) emptySet() else setOf(RegexOption.IGNORE_CASE)
                query.toRegex(opts).replace(value, Regex.escapeReplacement(replacement))
            } else {
                value.replace(query, replacement, ignoreCase = !caseSensitive)
            }
        }.getOrElse { regexError = "Invalid pattern"; return }
        onValueChange(next)
    }

    Column(modifier = modifier) {
        EditorToolbar(
            showFind = showFind,
            onToggleFind = { showFind = !showFind },
            wrap = wrap,
            onToggleWrap = { wrap = !wrap },
            onGoToLine = { line ->
                field = goToLine(field, value, line)
                scrollToCursorTrigger++
            },
            enabled = enabled,
        )
        if (showFind) {
            FindReplaceBar(
                query = query, onQuery = { query = it },
                replacement = replacement, onReplacement = { replacement = it },
                caseSensitive = caseSensitive, onCase = { caseSensitive = it },
                useRegex = useRegex, onRegex = { useRegex = it },
                matchCount = matches.size,
                currentIndex = currentMatchIndex,
                error = regexError,
                onNext = { selectMatch(currentMatchIndex + 1) },
                onPrev = { selectMatch(currentMatchIndex - 1) },
                onReplace = { replaceCurrent() },
                onReplaceAll = { replaceAll() },
                onClose = { showFind = false },
            )
        }
        EditorBody(
            modifier = Modifier.weight(1f),
            scrollToCursorTrigger = scrollToCursorTrigger,
            field = field,
            onChange = { field = it; onValueChange(it.text) },
            enabled = enabled,
            fontSize = fontSize,
            language = language,
            highlightMaxChars = highlightMaxChars,
            wrap = wrap,
        )
    }
}

/**
 * Full-screen editor chrome around [CodeEditor]: a top bar (close + title/subtitle + dirty dot +
 * optional trailing action), an optional error strip, and a Discard / Save bottom bar — pinned above
 * the IME via the Scaffold's safeDrawing insets. Shared by the SFTP remote-file editor and the
 * Compose Builder Raw YAML editor so both have an identical look, feel, and operations.
 *
 * Rendered as a full-screen [Surface] overlay (NOT a Compose Dialog, whose IME insets are unreliable
 * across OEMs). The host must place this above any inset-consuming app Scaffold.
 *
 * The buffer is owned by the caller via [value]/[onValueChange] so the host controls dirty-tracking
 * and what "save" means. [onClose] should itself prompt-on-dirty if desired; both the close button
 * and hardware back invoke it.
 */
@Composable
fun FullScreenCodeEditor(
    title: String,
    value: String,
    onValueChange: (String) -> Unit,
    onClose: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    subtitleColor: androidx.compose.ui.graphics.Color? = null,
    dirty: Boolean = false,
    saving: Boolean = false,
    canSave: Boolean = dirty,
    error: String? = null,
    saveLabel: String = "Save",
    fontSize: androidx.compose.ui.unit.TextUnit = 14.sp,
    language: CodeLanguage = CodeLanguage.NONE,
    highlightMaxChars: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
    topBarAction: @Composable (() -> Unit)? = null,
) {
    androidx.activity.compose.BackHandler(enabled = true) { onClose() }

    androidx.compose.material3.Surface(
        modifier = modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.surface,
    ) {
        androidx.compose.material3.Scaffold(
            topBar = {
                Column {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .background(MaterialTheme.colorScheme.surfaceContainer)
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(onClick = onClose) {
                            Icon(Icons.Filled.Close, contentDescription = "Close editor")
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                title + if (dirty) " •" else "",
                                fontFamily = OmniFonts.mono,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                            if (subtitle != null) {
                                Text(
                                    subtitle,
                                    fontSize = 10.sp,
                                    color = subtitleColor ?: MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        topBarAction?.invoke()
                    }
                    androidx.compose.material3.HorizontalDivider()
                }
            },
            bottomBar = {
                Column {
                    androidx.compose.material3.HorizontalDivider()
                    if (error != null && !saving) {
                        Text(
                            error,
                            color = OmniColors.red,
                            fontSize = 11.sp,
                            fontFamily = OmniFonts.mono,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(MaterialTheme.colorScheme.surfaceContainer)
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surfaceContainer)
                            // The Scaffold consumes safeDrawing insets for the bottomBar, so no manual
                            // nav/ime padding here — that would double-pad and push buttons off-screen.
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.End,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TextButton(onClick = onClose, enabled = !saving) { Text("Discard") }
                        Spacer(modifier = Modifier.width(8.dp))
                        androidx.compose.material3.Button(onClick = onSave, enabled = !saving && canSave) {
                            if (saving) {
                                androidx.compose.material3.CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = MaterialTheme.colorScheme.onPrimary,
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Saving…")
                            } else {
                                Icon(Icons.Filled.Save, null)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(saveLabel)
                            }
                        }
                    }
                }
            },
            contentWindowInsets = androidx.compose.foundation.layout.WindowInsets.safeDrawing,
        ) { innerPadding ->
            CodeEditor(
                value = value,
                onValueChange = onValueChange,
                enabled = !saving,
                fontSize = fontSize,
                language = language,
                highlightMaxChars = highlightMaxChars,
                modifier = Modifier.fillMaxSize().padding(innerPadding),
            )
        }
    }
}

@Composable
private fun EditorToolbar(
    showFind: Boolean,
    onToggleFind: () -> Unit,
    wrap: Boolean,
    onToggleWrap: () -> Unit,
    onGoToLine: (Int) -> Unit,
    enabled: Boolean,
) {
    var gotoText by remember { mutableStateOf("") }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onToggleFind, enabled = enabled) {
            Icon(
                if (showFind) Icons.Filled.Close else Icons.Filled.Search,
                contentDescription = if (showFind) "Hide find" else "Find / replace",
                tint = if (showFind) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onToggleWrap, enabled = enabled) {
            Icon(
                Icons.AutoMirrored.Filled.WrapText,
                contentDescription = if (wrap) "Word wrap: on" else "Word wrap: off",
                tint = if (wrap) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(4.dp))
        Text("Line", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(4.dp))
        BasicTextField(
            value = gotoText,
            onValueChange = { s -> gotoText = s.filter { it.isDigit() }.take(7) },
            enabled = enabled,
            singleLine = true,
            textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = SolidColor(OmniColors.amber),
            keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
            modifier = Modifier
                .width(56.dp)
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 6.dp, vertical = 4.dp),
        )
        TextButton(onClick = { gotoText.toIntOrNull()?.let(onGoToLine) }, enabled = enabled && gotoText.isNotEmpty()) {
            Text("Go", fontSize = 12.sp)
        }
    }
}

@Composable
private fun FindReplaceBar(
    query: String, onQuery: (String) -> Unit,
    replacement: String, onReplacement: (String) -> Unit,
    caseSensitive: Boolean, onCase: (Boolean) -> Unit,
    useRegex: Boolean, onRegex: (Boolean) -> Unit,
    matchCount: Int,
    currentIndex: Int,
    error: String?,
    onNext: () -> Unit,
    onPrev: () -> Unit,
    onReplace: () -> Unit,
    onReplaceAll: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            EditorInput(query, onQuery, "Find", Modifier.weight(1f))
            Spacer(Modifier.width(6.dp))
            val countLabel = if (query.isEmpty()) "" else if (matchCount == 0) "0/0" else "${currentIndex + 1}/$matchCount"
            Text(countLabel, fontSize = 11.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
            IconButton(onClick = onPrev, enabled = matchCount > 0) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = "Previous match", modifier = Modifier.width(18.dp))
            }
            IconButton(onClick = onNext, enabled = matchCount > 0) {
                Icon(Icons.Filled.ArrowDownward, contentDescription = "Next match", modifier = Modifier.width(18.dp))
            }
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "Close find")
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            EditorInput(replacement, onReplacement, "Replace with", Modifier.weight(1f))
            Spacer(Modifier.width(6.dp))
            TextButton(onClick = onReplace, enabled = matchCount > 0) { Text("Replace", fontSize = 12.sp) }
            TextButton(onClick = onReplaceAll, enabled = matchCount > 0) { Text("All", fontSize = 12.sp) }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FilterChip(selected = caseSensitive, onClick = { onCase(!caseSensitive) }, label = { Text("Aa", fontSize = 11.sp) })
            FilterChip(selected = useRegex, onClick = { onRegex(!useRegex) }, label = { Text(".*", fontSize = 11.sp) })
            if (error != null) Text(error, color = OmniColors.red, fontSize = 11.sp)
        }
    }
}

@Composable
private fun EditorInput(value: String, onChange: (String) -> Unit, hint: String, modifier: Modifier) {
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
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun EditorBody(
    modifier: Modifier = Modifier,
    scrollToCursorTrigger: Int,
    field: TextFieldValue,
    onChange: (TextFieldValue) -> Unit,
    enabled: Boolean,
    fontSize: androidx.compose.ui.unit.TextUnit,
    language: CodeLanguage,
    highlightMaxChars: Int,
    wrap: Boolean,
) {
    val palette = rememberHighlightPalette()
    val limit = remember(highlightMaxChars) { clampHighlightLimit(highlightMaxChars) }
    val highlight = remember(language, palette, limit) { CodeHighlightTransformation(language, palette, limit) }
    val verticalScroll = rememberScrollState()
    val horizontalScroll = rememberScrollState()
    val lineCount = remember(field.text) { field.text.count { it == '\n' } + 1 }
    var textLayoutResult by remember { mutableStateOf<androidx.compose.ui.text.TextLayoutResult?>(null) }

    androidx.compose.runtime.LaunchedEffect(scrollToCursorTrigger) {
        if (scrollToCursorTrigger > 0) {
            textLayoutResult?.let { layout ->
                val startRect = layout.getCursorRect(field.selection.min)
                val endRect = layout.getCursorRect(field.selection.max)
                val y = minOf(startRect.top, endRect.top).toInt()
                val x = minOf(startRect.left, endRect.left).toInt()
                verticalScroll.animateScrollTo((y - 200).coerceAtLeast(0))
                // No horizontal scroll state is in use when wrapping, so only move it otherwise.
                if (!wrap) horizontalScroll.animateScrollTo((x - 120).coerceAtLeast(0))
            }
        }
    }

    Row(modifier = modifier.fillMaxSize().verticalScroll(verticalScroll)) {
        // Line-number gutter, scrolling in lockstep with the text (shared verticalScroll on the Row).
        // Hidden while wrapping: the gutter emits one row per LOGICAL line, but soft-wrap adds extra
        // VISUAL lines, so the numbers would drift out of alignment with the text. Keeping it simple
        // (and correct) by dropping the gutter in wrap mode; Go-to-line still works.
        if (!wrap) {
            Column(
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.surfaceContainer)
                    .padding(horizontal = 6.dp, vertical = 12.dp),
                horizontalAlignment = Alignment.End,
            ) {
                for (n in 1..lineCount) {
                    Text(
                        n.toString(),
                        fontFamily = OmniFonts.mono,
                        fontSize = fontSize,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                        textAlign = TextAlign.End,
                    )
                }
            }
        }
        BasicTextField(
            value = field,
            onValueChange = onChange,
            enabled = enabled,
            visualTransformation = highlight,
            onTextLayout = { textLayoutResult = it },
            textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = fontSize, color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = SolidColor(OmniColors.amber),
            modifier = Modifier
                .fillMaxSize()
                // Wrap mode: soft-wrap and no horizontal scroll. Otherwise: scroll horizontally so
                // long lines extend off-screen instead of wrapping.
                .then(if (wrap) Modifier else Modifier.horizontalScroll(horizontalScroll))
                .padding(start = 8.dp, top = 12.dp, end = 12.dp, bottom = 12.dp),
        )
    }
}

/** All [start, end) match ranges of [query] in [text]. Pure for unit-testing. */
internal fun findMatches(text: String, query: String, caseSensitive: Boolean, useRegex: Boolean): List<Pair<Int, Int>> {
    if (query.isEmpty()) return emptyList()
    return if (useRegex) {
        val opts = if (caseSensitive) emptySet() else setOf(RegexOption.IGNORE_CASE)
        query.toRegex(opts).findAll(text)
            .filter { it.range.first <= it.range.last } // skip zero-width matches
            .map { it.range.first to it.range.last + 1 }
            .toList()
    } else {
        buildList {
            var i = text.indexOf(query, 0, ignoreCase = !caseSensitive)
            while (i >= 0) {
                add(i to i + query.length)
                i = text.indexOf(query, i + query.length, ignoreCase = !caseSensitive)
            }
        }
    }
}

/**
 * Move the cursor to the start of 1-based [line]. A line beyond the end clamps to the START of the
 * last line (more useful than jumping to end-of-buffer). Pure for unit-testing.
 */
internal fun goToLine(field: TextFieldValue, text: String, line: Int): TextFieldValue {
    val target = line.coerceAtLeast(1)
    var offset = 0
    var current = 1
    while (current < target) {
        val nl = text.indexOf('\n', offset)
        if (nl < 0) break // no more lines: leave offset at the start of the last line
        offset = nl + 1
        current++
    }
    return field.copy(selection = TextRange(offset.coerceIn(0, text.length)))
}
