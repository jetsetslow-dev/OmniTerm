package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Horizontal swipe-to-page gesture for switching tabs/subtabs. Calls [onSwipe] with `forward=true`
 * for a right-to-left drag (next) and `false` for left-to-right (previous), once a comfortable
 * distance threshold is crossed, and only when the drag is predominantly horizontal so it does not
 * fight vertical list scrolling. Fires at most once per drag.
 */
fun Modifier.swipeTabs(onSwipe: (forward: Boolean) -> Unit): Modifier = this.then(
    Modifier.pointerInput(Unit) {
        // ~64dp of horizontal travel before we treat it as a tab swipe.
        val thresholdPx = 64.dp.toPx()
        var totalDx = 0f
        var totalDy = 0f
        var fired = false
        detectHorizontalDragGestures(
            onDragStart = { totalDx = 0f; totalDy = 0f; fired = false },
            onDragEnd = { totalDx = 0f; totalDy = 0f; fired = false },
            onDragCancel = { totalDx = 0f; totalDy = 0f; fired = false },
        ) { change, dragAmount ->
            if (fired) return@detectHorizontalDragGestures
            totalDx += dragAmount
            totalDy += change.positionChange().y
            // Only act on a mostly-horizontal gesture past the threshold.
            if (kotlin.math.abs(totalDx) > thresholdPx && kotlin.math.abs(totalDx) > kotlin.math.abs(totalDy) * 1.5f) {
                fired = true
                onSwipe(totalDx < 0)
            }
        }
    }
)

// ─────────────────────────────────────────────────────────────────────────────
// Primitive components ported from nexuscomplete.jsx, rebranded for OmniTerm.
// ─────────────────────────────────────────────────────────────────────────────

object OmniTextSize {
    val Section = 11.sp
    val Body = 14.sp
    val Dense = 12.sp
    val Meta = 11.sp
    val Tag = 10.sp
}

/** Thin metric bar; turns amber >70% and red >85%, like the prototype. */
@Composable
fun GaugeBar(value: Float, modifier: Modifier = Modifier, color: Color = OmniColors.cyan, height: Dp = 4.dp, contentDescription: String? = null) {
    val barColor = when {
        value > 85 -> OmniColors.red
        value > 70 -> OmniColors.amber
        else -> color
    }
    val cdMod = if (contentDescription != null) Modifier.semantics { this.contentDescription = contentDescription } else Modifier
    Box(
        modifier.then(cdMod)
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(50))
            .background(OmniColors.border),
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth((value / 100f).coerceIn(0f, 1f))
                .clip(RoundedCornerShape(50))
                .background(barColor),
        )
    }
}

@Composable
fun StatusDot(online: Boolean, color: Color = OmniColors.green, size: Dp = 8.dp, contentDescription: String? = null) {
    val c = if (online) color else OmniColors.red
    val desc = contentDescription ?: if (online) "Server online" else "Server offline"
    Box(Modifier.size(size).clip(CircleShape).background(c).semantics { this.contentDescription = desc })
}

/** Circular health score gauge with the value in the centre (display font). */
@Composable
fun ScoreRing(score: Int, modifier: Modifier = Modifier, size: Dp = 44.dp, contentDescription: String? = null) {
    val color = when {
        score >= 90 -> OmniColors.green
        score >= 70 -> OmniColors.cyan
        score >= 50 -> OmniColors.amber
        else -> OmniColors.red
    }
    val desc = contentDescription ?: "Health score: $score out of 100"
    Box(modifier.size(size).semantics { this.contentDescription = desc }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = (size.toPx() * 0.09f).coerceAtLeast(3f)
            val inset = stroke / 2 + 1f
            drawArc(
                color = OmniColors.border,
                startAngle = 0f, sweepAngle = 360f, useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(this.size.width - inset * 2, this.size.height - inset * 2),
                style = Stroke(width = stroke),
            )
            drawArc(
                color = color,
                startAngle = -90f, sweepAngle = 360f * (score / 100f).coerceIn(0f, 1f), useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(this.size.width - inset * 2, this.size.height - inset * 2),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Text(
            "$score",
            color = color,
            fontFamily = OmniFonts.display,
            fontWeight = FontWeight.Bold,
            fontSize = (size.value * 0.30f).sp,
        )
    }
}

/**
 * Circular auto-refresh countdown: a depleting ring with the whole seconds remaining until the
 * next refresh in its centre. Driven by the poller's [lastStartMs] + [intervalMs] so it stays in
 * sync with the actual telemetry cadence and resets automatically each cycle.
 */
@Composable
fun RefreshCountdown(
    lastStartMs: Long,
    intervalMs: Long,
    modifier: Modifier = Modifier,
    size: Dp = 30.dp,
    color: Color = OmniColors.cyan,
    contentDescription: String? = null,
) {
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(lastStartMs, intervalMs) {
        while (true) {
            now = System.currentTimeMillis()
            kotlinx.coroutines.delay(250)
        }
    }
    val elapsed = (now - lastStartMs).coerceAtLeast(0)
    val remainingMs = (intervalMs - elapsed).coerceIn(0, intervalMs)
    val frac = if (intervalMs > 0) remainingMs.toFloat() / intervalMs else 0f
    val secs = ((remainingMs + 999) / 1000).toInt()
    val desc = contentDescription ?: "Refreshing in $secs seconds"
    Box(modifier.size(size).semantics { this.contentDescription = desc }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = (size.toPx() * 0.10f).coerceAtLeast(3f)
            val inset = stroke / 2 + 1f
            drawArc(
                color = OmniColors.border,
                startAngle = 0f, sweepAngle = 360f, useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(this.size.width - inset * 2, this.size.height - inset * 2),
                style = Stroke(width = stroke),
            )
            drawArc(
                color = color,
                startAngle = -90f, sweepAngle = 360f * frac, useCenter = false,
                topLeft = Offset(inset, inset),
                size = Size(this.size.width - inset * 2, this.size.height - inset * 2),
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Text(
            "$secs",
            color = color,
            fontFamily = OmniFonts.mono,
            fontWeight = FontWeight.Bold,
            fontSize = (size.value * 0.34f).sp,
        )
    }
}

/** Small uppercase pill, e.g. a group label. */
@Composable
fun OmniTag(label: String, modifier: Modifier = Modifier, color: Color = OmniColors.cyan) {
    Box(
        modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.30f), RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(label, color = color, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, fontSize = 10.sp, letterSpacing = 0.8.sp)
    }
}

/** Translucent accent button. */
@Composable
fun OmniButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = OmniColors.cyan, small: Boolean = false, contentDescription: String? = null) {
    val cdMod = if (contentDescription != null) Modifier.semantics { this.contentDescription = contentDescription } else Modifier
    // Minimum heights keep these tappable (a11y touch targets) without inflating dense rows to
    // a full 48dp; the text stays centered when the min height exceeds the padded text height.
    Box(
        modifier.then(cdMod)
            .clip(RoundedCornerShape(6.dp))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(6.dp))
            .clickable { onClick() }
            .defaultMinSize(minHeight = if (small) 36.dp else 44.dp)
            .padding(horizontal = if (small) 10.dp else 14.dp, vertical = if (small) 5.dp else 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = color, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, fontSize = if (small) 10.sp else 12.sp, letterSpacing = 0.6.sp)
    }
}

@Composable
fun MiniMetric(label: String, value: Float, modifier: Modifier = Modifier, color: Color = OmniColors.cyan) {
    val metricColor = when {
        value > 85f -> OmniColors.red
        value > 70f -> OmniColors.amber
        else -> color
    }
    Column(modifier) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono, fontSize = 10.sp)
            Text("${value.toInt()}%", color = metricColor, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, fontSize = 10.sp)
        }
        Spacer(Modifier.height(3.dp))
        GaugeBar(value = value, color = color, height = 3.dp)
    }
}

@Composable
fun OmniStatBox(value: String, label: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurface, contentDescription: String? = null) {
    val desc = contentDescription ?: "$label: $value"
    Column(modifier.semantics { this.contentDescription = desc }, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = color, fontFamily = OmniFonts.mono, fontWeight = FontWeight.ExtraBold, fontSize = 20.sp)
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold, fontSize = 10.sp, letterSpacing = 1.1.sp)
    }
}

@Composable
fun omniTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = OmniColors.cyan,
    unfocusedBorderColor = MaterialTheme.colorScheme.outline,
    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
    cursorColor = OmniColors.cyan,
    focusedLabelColor = OmniColors.cyan,
)

/** Card surface with an optional coloured left accent (host-colour coding in the prototype). */
@Composable
fun OmniCard(
    modifier: Modifier = Modifier,
    leftAccent: Color? = null,
    onClick: (() -> Unit)? = null,
    contentDescription: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val shape = RoundedCornerShape(if (leftAccent != null) 4.dp else 10.dp)
    var m = modifier
        .clip(shape)
        .background(MaterialTheme.colorScheme.surfaceContainer)
        .border(1.dp, MaterialTheme.colorScheme.outline, shape)
    if (leftAccent != null) m = m.drawBehind {
        drawRect(color = leftAccent, size = Size(3.dp.toPx(), size.height))
    }
    if (onClick != null) m = m.clickable { onClick() }
    if (contentDescription != null) m = m.semantics { this.contentDescription = contentDescription }
    Column(m.padding(12.dp), content = content)
}

@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
            fontSize = 11.sp,
            letterSpacing = 1.5.sp,
        )
        if (trailing != null) {
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

// ─── Top app bar (OMNITERM wordmark) ─────────────────────────────────────────

@Composable
fun OmniAppBar(
    activeColor: Color,
    alertCount: Int,
    keepScreenOn: Boolean,
    onHome: () -> Unit,
    onAlerts: () -> Unit,
    onToggleKeepScreenOn: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            // Edge-to-edge: surface fills behind the status bar, content sits below it.
            .background(MaterialTheme.colorScheme.surface)
            .statusBarsPadding()
            .height(52.dp)
            .drawBehind { drawRect(OmniColors.border, topLeft = Offset(0f, size.height - 1f), size = Size(size.width, 1f)) }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { onHome() }.padding(4.dp),
        ) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(activeColor))
            Spacer(Modifier.width(8.dp))
            Text(
                "OMNITERM",
                color = MaterialTheme.colorScheme.onSurface,
                fontFamily = OmniFonts.display,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                letterSpacing = 2.sp,
            )
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onToggleKeepScreenOn) {
            Icon(
                Icons.Filled.Lightbulb,
                contentDescription = if (keepScreenOn) "Disable keep screen on" else "Enable keep screen on",
                tint = if (keepScreenOn) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (alertCount > 0) {
            Box(
                Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(OmniColors.red.copy(alpha = 0.12f))
                    .border(1.dp, OmniColors.red.copy(alpha = 0.35f), RoundedCornerShape(6.dp))
                    .clickable { onAlerts() }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text("ALERTS $alertCount", color = OmniColors.red, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, fontSize = 12.sp)
            }
        }
    }
}

// ─── Bottom navigation ───────────────────────────────────────────────────────

data class OmniNavItem(val key: Any, val label: String, val icon: ImageVector, val color: Color)

@Composable
fun OmniBottomNav(items: List<OmniNavItem>, isActive: (Any) -> Boolean, onNavigate: (Any) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .drawBehind { drawRect(OmniColors.border, size = Size(size.width, 1f)) }
            .navigationBarsPadding(),
    ) {
        items.forEach { item ->
            val active = isActive(item.key)
            Column(
                Modifier
                    .weight(1f)
                    .defaultMinSize(minHeight = 48.dp) // a11y touch-target floor
                    .clickable { onNavigate(item.key) }
                    .drawBehind {
                        if (active) drawRect(item.color, size = Size(size.width, 2f))
                    }
                    .padding(top = 8.dp, bottom = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    item.icon,
                    contentDescription = item.label,
                    tint = if (active) item.color else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    item.label,
                    color = if (active) item.color else MaterialTheme.colorScheme.onSurfaceVariant,
                    fontFamily = OmniFonts.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    letterSpacing = 0.6.sp,
                    maxLines = 1,
                )
            }
        }
    }
}

// ─── Format Utilities ─────────────────────────────────────────────────────────

fun formatBytes(bytes: Long): String {
    if (bytes < 1024L) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unitIndex = -1
    do {
        value /= 1024.0
        unitIndex++
    } while (value >= 1024.0 && unitIndex < units.lastIndex)
    return String.format(java.util.Locale.US, "%.1f %s", value, units[unitIndex])
}

fun formatUptime(seconds: Long): String {
    if (seconds <= 0) return "—"
    val d = seconds / 86400
    val h = (seconds % 86400) / 3600
    val mnt = (seconds % 3600) / 60
    return buildString {
        if (d > 0) append("${d}d ")
        if (h > 0 || d > 0) append("${h}h ")
        append("${mnt}m")
    }
}

fun formatDateTime(timeMs: Long): String =
    java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(timeMs))

fun formatShortDateTime(timeMs: Long): String =
    java.text.SimpleDateFormat("MMM d, HH:mm", java.util.Locale.getDefault()).format(java.util.Date(timeMs))

/**
 * Outlined password field with a show/hide eye toggle. Use for real passwords/passphrases;
 * short numeric PINs keep the plain masked field.
 */
@Composable
fun OmniPasswordField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
) {
    var visible by remember { mutableStateOf(false) }
    androidx.compose.material3.OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        modifier = modifier,
        singleLine = true,
        visualTransformation = if (visible) {
            androidx.compose.ui.text.input.VisualTransformation.None
        } else {
            androidx.compose.ui.text.input.PasswordVisualTransformation()
        },
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
            keyboardType = androidx.compose.ui.text.input.KeyboardType.Password
        ),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(
                    if (visible) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                    contentDescription = if (visible) "Hide password" else "Show password",
                )
            }
        },
    )
}
