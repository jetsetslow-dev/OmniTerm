package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A scroll state for streamed output: it stays at the end as output arrives, stops following while
 * the user has scrolled up to read, and follows again once they scroll back to the end. Keyed on
 * the laid-out extent rather than the text, which a LaunchedEffect sees before the new text is
 * measured, so a scroll-to-end there landed one chunk short.
 */
@Composable
fun rememberTailFollowingScrollState(): ScrollState {
    val scroll = rememberScrollState()
    var following by remember { mutableStateOf(true) }
    // Where this last scrolled to by itself. Arriving there is not the user scrolling away, even when
    // the extent has moved on: unknown before the first layout, or grown again by newer output. Read
    // as the user's, either stopped following at the top, where nothing moved the box again.
    var followedTo by remember { mutableIntStateOf(0) }
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.value }.collect { position ->
            following = position >= scroll.maxValue || (following && position == followedTo)
        }
    }
    LaunchedEffect(scroll.maxValue) {
        val end = scroll.maxValue
        if (end == Int.MAX_VALUE) return@LaunchedEffect // Not laid out yet.
        // Output that fits (a host's card cleared for a new run) has nothing to scroll back from.
        if (following || scroll.value >= end) {
            following = true
            followedTo = end
            scroll.scrollTo(end)
        }
    }
    return scroll
}

/**
 * The list form of [rememberTailFollowingScrollState], for output that arrives as [items]: each new
 * list shows its end if the user was at the end of the previous one, so a refreshed log window
 * stays on the newest entries while someone reading further up is left where they are.
 */
@Composable
fun rememberTailFollowingLazyListState(items: List<*>): LazyListState {
    val state = rememberLazyListState()
    var previousCount by remember { mutableIntStateOf(0) }
    LaunchedEffect(items) {
        // The layout still describes the previous list here, which is the one the user was reading.
        val lastVisible = state.layoutInfo.visibleItemsInfo.lastOrNull()?.index
        val wasAtEnd = previousCount == 0 || lastVisible == null || lastVisible >= previousCount - 1
        if (wasAtEnd && items.isNotEmpty()) state.scrollToItem(items.size - 1)
        previousCount = items.size
    }
    return state
}

/**
 * List state for items shown in a chosen order, such as the Hosts list. A keyed LazyColumn keeps
 * its first visible item in view when the items move, so after a re-sort, or after a refresh moved
 * hosts online, the list sat wherever the old top item had gone. A new [order] (the sort, search or
 * filter) always shows the top; a reorder from new data keeps the list at the top if it was there.
 */
@Composable
fun rememberTopAnchoredLazyListState(order: Any?, keys: List<Any>): LazyListState {
    val state = rememberLazyListState()
    val shown = remember { arrayOf(order, keys) }
    // Asked here, in the composition that hands the list its new items, so it applies to the very
    // layout that would otherwise re-anchor on the moved item.
    val orderChanged = shown[0] != order
    if (orderChanged || shown[1] != keys) {
        // The layout still describes the previous list, which is the one the user was reading.
        // Not observed: following every scroll would recompose the whole screen.
        val atTop = Snapshot.withoutReadObservation { state.firstVisibleItemIndex == 0 }
        if (orderChanged || atTop) state.requestScrollToItem(0)
        shown[0] = order
        shown[1] = keys
    }
    return state
}

/** Persistent viewport-edge cues, including before the first drag and after content changes. */
fun Modifier.verticalScrollWithIndicators(state: ScrollState): Modifier =
    scrollOverflowIndicators({ state.canScrollBackward }, { state.canScrollForward }).verticalScroll(state)

fun Modifier.horizontalScrollWithIndicators(state: ScrollState): Modifier =
    scrollOverflowIndicators({ state.canScrollBackward }, { state.canScrollForward }, horizontal = true).horizontalScroll(state)

internal fun Modifier.scrollOverflowIndicators(
    aboveVisible: () -> Boolean,
    belowVisible: () -> Boolean,
    horizontal: Boolean = false,
): Modifier = composed {
    val measurer = rememberTextMeasurer()
    val colors = MaterialTheme.colorScheme
    val style = TextStyle(color = colors.onSecondaryContainer, fontSize = 12.sp)
    val beforeLabel = if (horizontal) "← More left" else "↑ More above"
    val afterLabel = if (horizontal) "→ More right" else "↓ More below"
    val above = measurer.measure(beforeLabel, style)
    val below = measurer.measure(afterLabel, style)
    this.semantics {
        stateDescription = listOfNotNull(
            beforeLabel.drop(2).takeIf { aboveVisible() },
            afterLabel.drop(2).takeIf { belowVisible() },
        ).joinToString(", ")
    }.drawWithContent {
        drawContent()
        val pad = 4.dp.toPx()
        fun hint(top: Boolean) {
            val text = if (top) above else below
            val width = text.size.width + pad * 2
            val height = text.size.height + pad * 2
            val x = if (horizontal && top) 0f else (size.width - width).coerceAtLeast(0f)
            val y = if (!horizontal && top) 0f else (size.height - height).coerceAtLeast(0f)
            drawRect(colors.secondaryContainer, Offset(x, y), Size(width, height))
            drawText(text, topLeft = Offset(x + pad, y + pad))
        }
        if (aboveVisible()) hint(true)
        if (belowVisible()) hint(false)
    }
}

@Composable
fun OverflowLazyColumn(
    modifier: Modifier = Modifier,
    state: LazyListState = rememberLazyListState(),
    contentPadding: PaddingValues = PaddingValues(0.dp),
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    content: LazyListScope.() -> Unit,
) {
    LazyColumn(
        modifier = modifier.scrollOverflowIndicators({ state.canScrollBackward }, { state.canScrollForward }),
        state = state,
        contentPadding = contentPadding,
        verticalArrangement = verticalArrangement,
        horizontalAlignment = horizontalAlignment,
        content = content,
    )
}

@Composable
fun OverflowDropdownMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scroll = rememberScrollState()
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier.scrollOverflowIndicators({ scroll.canScrollBackward }, { scroll.canScrollForward }),
        scrollState = scroll,
        content = content,
    )
}
