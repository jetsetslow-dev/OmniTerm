package com.jetsetslow.omniterm.ui.markdown

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.ui.HIGHLIGHT_MAX_CHARS_DEFAULT
import com.jetsetslow.omniterm.ui.HighlightPalette
import com.jetsetslow.omniterm.ui.highlightedText
import com.jetsetslow.omniterm.ui.rememberHighlightPalette
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import kotlinx.coroutines.launch

/*
 * The file editor's Markdown preview, drawn by the app itself rather than a web view, so that it
 * does only what the app allows: no image or other remote content is ever loaded (an image is its
 * alt text and a marker), raw HTML is shown as text, and a link opens only after the user has seen
 * its whole address and chosen Open. Only http, https and mailto addresses are offered at all.
 *
 * Blocks come from [loadMarkdownPreview], which parses off the main thread, and are laid out lazily,
 * so a long or deeply nested file never holds up the screen.
 *
 * Compose and Material 3 only, as Compose Multiplatform has them. The Android-only part is the
 * string resources (`stringResource(R.string...)`), which Compose Multiplatform has its own form of.
 */

internal const val MARKDOWN_PREVIEW_TAG = "markdown-preview"
internal const val MARKDOWN_LIST_TAG = "markdown-preview-list"
internal const val LINK_QUESTION_TAG = "markdown-link-question"
internal const val LINK_ADDRESS_TAG = "markdown-link-address"
internal const val LINK_OPEN_TAG = "markdown-link-open"

/** Indent steps beyond this are not drawn: a file nested hundreds of levels deep stays readable. */
private const val MAX_SHOWN_LEVELS = 8
private val QUOTE_STEP = 12.dp
private val LIST_STEP = 24.dp

/**
 * A read-only preview of Markdown [text], the text as it is now, saved or not. [onOpenLink] is called
 * with an http, https or mailto address only after the user has confirmed it; nothing else opens
 * anything. [listState] keeps the reading position for as long as the caller holds it.
 */
@Composable
fun MarkdownPreview(
    text: String,
    onOpenLink: (String) -> Unit,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    highlightMaxChars: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
) {
    val imageMarker = stringResource(R.string.markdown_image_not_loaded)
    val result by produceState<MarkdownPreviewResult?>(null, text, imageMarker, highlightMaxChars) {
        value = null
        value = loadMarkdownPreview(text, imageMarker, highlightMaxChars)
    }
    var question by rememberSaveable { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Surface(modifier = modifier.fillMaxSize().testTag(MARKDOWN_PREVIEW_TAG), color = MaterialTheme.colorScheme.surface) {
        when (val shown = result) {
            null -> Notice(stringResource(R.string.markdown_preparing_preview), busy = true)
            is MarkdownPreviewResult.TooLarge ->
                Notice(stringResource(R.string.markdown_too_large_to_preview, groupedDigits(shown.limit)))
            MarkdownPreviewResult.TooSlow -> Notice(stringResource(R.string.markdown_too_slow_to_preview))
            MarkdownPreviewResult.Unreadable -> Notice(stringResource(R.string.markdown_cannot_preview))
            is MarkdownPreviewResult.Ready -> Blocks(shown.document, listState) { link ->
                when (link) {
                    // Never opened from the tap itself: the user sees the whole address first.
                    is MdLink.External -> question = link.url
                    is MdLink.Anchor -> shown.document.anchors[link.slug]?.let { scope.launch { listState.animateScrollToItem(it) } }
                }
            }
        }
    }
    question?.let { url ->
        LinkQuestion(
            url = url,
            onOpen = {
                question = null
                onOpenLink(url)
            },
            onDismiss = { question = null },
        )
    }
}

/** 200000 as 200,000, the same in every locale. */
private fun groupedDigits(n: Int): String = n.toString().reversed().chunked(3).joinToString(",").reversed()

@Composable
private fun Notice(message: String, busy: Boolean = false) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (busy) {
            CircularProgressIndicator()
            Spacer(Modifier.height(12.dp))
        }
        Text(message, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
    }
}

/** Colours of one theme, resolved once. */
private class PreviewLook(
    val palette: HighlightPalette,
    val text: Color,
    val muted: Color,
    val link: Color,
    val codeBackground: Color,
    val quoteBar: Color,
    val border: Color,
    val headerBackground: Color,
)

@Composable
private fun Blocks(document: MdDocument, listState: LazyListState, onLink: (MdLink) -> Unit) {
    val palette = rememberHighlightPalette()
    val scheme = MaterialTheme.colorScheme
    val look = remember(scheme, palette) {
        PreviewLook(
            palette = palette,
            text = scheme.onSurface,
            muted = scheme.onSurfaceVariant,
            link = scheme.primary,
            codeBackground = scheme.surfaceContainerHighest,
            quoteBar = scheme.outlineVariant,
            border = scheme.outlineVariant,
            headerBackground = scheme.surfaceContainerHigh,
        )
    }
    // One horizontal position per table, so its rows, each laid out on its own, scroll together.
    val tableScrolls = remember(document) { HashMap<MdTable, ScrollState>() }
    val currentOnLink by rememberUpdatedState(onLink)
    val linkTo: (MdLink) -> Unit = remember { { link -> currentOnLink(link) } }
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().testTag(MARKDOWN_LIST_TAG),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
    ) {
        items(count = document.blocks.size, contentType = { kindOf(document.blocks[it]) }) { index ->
            Block(document.blocks[index], look, tableScrolls, linkTo)
        }
    }
}

private fun kindOf(block: MdBlock): Int = when (block) {
    is MdHeading -> 0
    is MdParagraph -> 1
    is MdCode -> 2
    is MdTableRow -> 3
    is MdRule -> 4
}

@Composable
private fun Block(block: MdBlock, look: PreviewLook, tableScrolls: MutableMap<MdTable, ScrollState>, onLink: (MdLink) -> Unit) {
    val nesting = block.nesting
    val quotes = minOf(nesting.quotes, MAX_SHOWN_LEVELS)
    val lists = minOf(nesting.lists, MAX_SHOWN_LEVELS)
    val top = when {
        block is MdParagraph && block.continued -> 0.dp
        block is MdCode && !block.first -> 0.dp
        block is MdTableRow && !block.first -> 0.dp
        block is MdHeading -> if (block.level <= 2) 16.dp else 12.dp
        else -> 8.dp
    }
    Row(
        Modifier
            .fillMaxWidth()
            .drawBehind {
                for (i in 0 until quotes) {
                    drawRect(look.quoteBar, Offset(i * QUOTE_STEP.toPx(), 0f), Size(3.dp.toPx(), size.height))
                }
            }
            .padding(start = QUOTE_STEP * quotes, top = top),
    ) {
        if (lists > 0) {
            Spacer(Modifier.width(LIST_STEP * (lists - 1)))
            Box(Modifier.width(LIST_STEP).padding(end = 6.dp), contentAlignment = Alignment.TopEnd) {
                nesting.marker?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = look.muted) }
            }
        }
        Box(Modifier.weight(1f)) {
            when (block) {
                is MdHeading -> Heading(block, look, onLink)
                is MdParagraph -> Text(
                    remember(block, look) { block.text.annotated(look, onLink) },
                    style = MaterialTheme.typography.bodyMedium,
                    color = look.text,
                )
                is MdCode -> CodeBlock(block, look)
                is MdTableRow -> TableRow(block, look, tableScrolls.getOrPut(block.table) { ScrollState(0) }, onLink)
                is MdRule -> HorizontalDivider(Modifier.padding(vertical = 8.dp), thickness = 2.dp, color = look.border)
            }
        }
    }
}

@Composable
private fun Heading(block: MdHeading, look: PreviewLook, onLink: (MdLink) -> Unit) {
    val typography = MaterialTheme.typography
    val style: TextStyle = when (block.level) {
        1 -> typography.headlineSmall
        2 -> typography.titleLarge
        3 -> typography.titleMedium
        4 -> typography.titleSmall
        else -> typography.bodyMedium
    }
    Column {
        Text(
            remember(block, look) { block.text.annotated(look, onLink) },
            style = style,
            fontWeight = FontWeight.Bold,
            color = if (block.level == 6) look.muted else look.text,
            modifier = Modifier.semantics { heading() },
        )
        if (block.level <= 2) HorizontalDivider(Modifier.padding(top = 4.dp), color = look.border)
    }
}

/** A piece of a code block, coloured by the editor's own highlighter, scrolled sideways rather than wrapped. */
@Composable
private fun CodeBlock(block: MdCode, look: PreviewLook) {
    val round = 6.dp
    val shape = RoundedCornerShape(
        topStart = if (block.first) round else 0.dp,
        topEnd = if (block.first) round else 0.dp,
        bottomStart = if (block.last) round else 0.dp,
        bottomEnd = if (block.last) round else 0.dp,
    )
    val text = remember(block, look) { highlightedText(block.text, block.tokens, look.palette) }
    Box(
        Modifier
            .fillMaxWidth()
            .background(look.codeBackground, shape)
            .horizontalScroll(rememberScrollState())
            .padding(start = 10.dp, end = 10.dp, top = if (block.first) 8.dp else 0.dp, bottom = if (block.last) 8.dp else 0.dp),
    ) {
        Text(text, fontFamily = OmniFonts.mono, fontSize = 13.sp, softWrap = false, color = if (block.html) look.muted else look.text)
    }
}

@Composable
private fun TableRow(row: MdTableRow, look: PreviewLook, scroll: ScrollState, onLink: (MdLink) -> Unit) {
    val cells = remember(row, look) { row.cells.map { it.annotated(look, onLink) } }
    Column {
        if (row.first && row.table.hiddenColumns > 0) {
            Text(
                pluralStringResource(R.plurals.markdown_more_columns, row.table.hiddenColumns, row.table.hiddenColumns),
                style = MaterialTheme.typography.labelSmall,
                color = look.muted,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        Row(Modifier.horizontalScroll(scroll).height(IntrinsicSize.Min)) {
            cells.forEachIndexed { i, cell ->
                Box(
                    Modifier
                        .width((row.table.widths[i] * 8 + 16).dp)
                        .fillMaxHeight()
                        .then(if (row.header) Modifier.background(look.headerBackground) else Modifier)
                        .border(0.5.dp, look.border)
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                ) {
                    Text(
                        cell,
                        style = MaterialTheme.typography.bodyMedium,
                        color = look.text,
                        fontWeight = if (row.header) FontWeight.Bold else null,
                        textAlign = when (row.table.alignments[i]) {
                            MdAlign.START -> TextAlign.Start
                            MdAlign.CENTER -> TextAlign.Center
                            MdAlign.END -> TextAlign.End
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

/**
 * [MdText] as styled text. A link is a [LinkAnnotation.Clickable] that only reports the tap to
 * [onLink]; nothing in the text can open an address by itself.
 */
private fun MdText.annotated(look: PreviewLook, onLink: (MdLink) -> Unit): AnnotatedString = buildAnnotatedString {
    append(text)
    for (span in spans) {
        when (span.style) {
            MdStyle.BOLD -> addStyle(SpanStyle(fontWeight = FontWeight.Bold), span.start, span.end)
            MdStyle.ITALIC -> addStyle(SpanStyle(fontStyle = FontStyle.Italic), span.start, span.end)
            MdStyle.STRIKE -> addStyle(SpanStyle(textDecoration = TextDecoration.LineThrough), span.start, span.end)
            MdStyle.CODE -> addStyle(SpanStyle(fontFamily = OmniFonts.mono, background = look.codeBackground), span.start, span.end)
            MdStyle.HTML -> addStyle(SpanStyle(fontFamily = OmniFonts.mono, color = look.muted), span.start, span.end)
            MdStyle.IMAGE -> addStyle(
                SpanStyle(color = look.muted, background = look.codeBackground, fontStyle = FontStyle.Italic),
                span.start,
                span.end,
            )
            MdStyle.LINK -> span.link?.let { link ->
                addLink(
                    LinkAnnotation.Clickable(
                        tag = "markdown-link",
                        styles = TextLinkStyles(SpanStyle(color = look.link, textDecoration = TextDecoration.Underline)),
                        linkInteractionListener = { onLink(link) },
                    ),
                    span.start,
                    span.end,
                )
            }
        }
    }
}

/** The question before a link opens: its whole address, which can be selected and copied, and Open or Cancel. */
@Composable
private fun LinkQuestion(url: String, onOpen: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag(LINK_QUESTION_TAG),
        title = { Text(stringResource(R.string.markdown_open_link_title)) },
        text = {
            Column(Modifier.heightIn(max = 280.dp).verticalScroll(rememberScrollState())) {
                Text(stringResource(R.string.markdown_open_link_body), style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(8.dp))
                SelectionContainer {
                    Text(url, fontFamily = OmniFonts.mono, fontSize = 13.sp, modifier = Modifier.testTag(LINK_ADDRESS_TAG))
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onOpen, modifier = Modifier.testTag(LINK_OPEN_TAG)) { Text(stringResource(R.string.markdown_open_link)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
