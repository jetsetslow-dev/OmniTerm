package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/** Colours of a [StreamOutputBox]. */
enum class StreamOutputLook {
    /** White on black, for command output. */
    Terminal,

    /** A raised surface, for output inside a dialog. */
    Surface,

    /** No background of its own, for output inside a card. */
    Plain,
}

/**
 * The one box for streamed command output: the action output pop-up, the tmux install, ping and
 * traceroute (Tools and the Hosts tab), and Fleet broadcasts. Monospace and selectable, with scroll
 * indicators, and it follows the end as output arrives unless the user has scrolled up to read.
 * Callers size it with [modifier]. [placeholder] shows while there is no output yet.
 */
@Composable
fun StreamOutputBox(
    text: AnnotatedString,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    look: StreamOutputLook = StreamOutputLook.Surface,
    fontSize: TextUnit = 11.sp,
) {
    val scroll = rememberTailFollowingScrollState()
    val background = when (look) {
        StreamOutputLook.Terminal -> Color.Black
        StreamOutputLook.Surface -> MaterialTheme.colorScheme.surfaceContainerHighest
        StreamOutputLook.Plain -> Color.Transparent
    }
    val foreground = if (look == StreamOutputLook.Terminal) Color.White else MaterialTheme.colorScheme.onSurface
    val muted = if (look == StreamOutputLook.Terminal) Color.Gray else MaterialTheme.colorScheme.onSurfaceVariant
    Box(
        modifier
            .fillMaxWidth()
            .background(background)
            .verticalScrollWithIndicators(scroll)
            .padding(8.dp),
    ) {
        if (text.isEmpty() && placeholder != null) {
            Text(placeholder, fontFamily = OmniFonts.mono, fontSize = fontSize, color = muted)
        } else {
            SelectionContainer {
                Text(text, fontFamily = OmniFonts.mono, fontSize = fontSize, color = foreground)
            }
        }
    }
}

@Composable
fun StreamOutputBox(
    text: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    look: StreamOutputLook = StreamOutputLook.Surface,
    fontSize: TextUnit = 11.sp,
) = StreamOutputBox(AnnotatedString(text), modifier, placeholder, look, fontSize)

/** [lines] as one text, with the lines [isFailure] picks out in red. */
fun failureHighlighted(lines: List<String>, isFailure: (String) -> Boolean): AnnotatedString =
    buildAnnotatedString {
        lines.forEachIndexed { index, line ->
            if (index > 0) append('\n')
            if (isFailure(line)) withStyle(SpanStyle(color = OmniColors.red)) { append(line) } else append(line)
        }
    }

/** A ping output line that reports a failure. */
internal fun isPingFailureLine(line: String): Boolean =
    line.contains("failed", true) || line.contains("unreachable", true) || line.contains("100% packet loss")

/** A traceroute output line that reports a failure. */
internal fun isTracerouteFailureLine(line: String): Boolean =
    line.contains("not available", true) || line.contains("failed", true)
