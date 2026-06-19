package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniFonts
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.rememberScrollableState
import androidx.compose.foundation.gestures.scrollable
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint as ComposePaint
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import androidx.compose.runtime.rememberUpdatedState
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.term.TermRow
import com.jetsetslow.omniterm.data.term.TerminalEmulator
import com.jetsetslow.omniterm.data.term.TerminalSnapshot
import com.jetsetslow.omniterm.ui.theme.OmniColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlin.math.ceil

@Composable
private fun SessionPicker(viewModel: AppViewModel) {
    val sessions = viewModel.activeSessions
    val restorableSessions = viewModel.restorablePersistentSessions.filter { r ->
        sessions.none { it.tmuxName == r.tmuxName }
    }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Active Sessions", color = OmniColors.textPrimary, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.display, fontSize = 20.sp)
        Spacer(Modifier.height(4.dp))
        Text("Tap a session to resume, or start a new one.", color = OmniColors.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(12.dp))

        if (sessions.isEmpty() && restorableSessions.isEmpty()) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                Text("No active sessions.", color = OmniColors.textMuted)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.weight(1f)) {
                items(sessions) { s ->
                    OmniCard(
                        modifier = Modifier.fillMaxWidth().clickable {
                            // Connected → resume. Reconnecting → still resume (watch it heal in place).
                            // Dropped → resume so the user sees the kept scrollback + Reconnect button.
                            if (s.isConnected || s.reconnecting) viewModel.attachSession(s.id)
                            else viewModel.attachSession(s.id)
                        },
                        leftAccent = when {
                            s.isConnected -> OmniColors.hostColor(s.serverName)
                            s.reconnecting -> OmniColors.amber
                            else -> Color.Gray
                        }
                    ) {
                        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(s.serverName, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                                Text(
                                    when {
                                        s.isConnected -> "Connected"
                                        s.reconnecting -> "Reconnecting…"
                                        else -> "Disconnected${s.disconnectError?.let { " · $it" } ?: ""}"
                                    },
                                    fontSize = 12.sp,
                                    color = when {
                                        s.isConnected -> OmniColors.green
                                        s.reconnecting -> OmniColors.amber
                                        else -> Color.Gray
                                    }
                                )
                            }
                            // Manual reconnect for a dropped session whose auto-retry gave up.
                            if (!s.isConnected && !s.reconnecting) {
                                IconButton(onClick = { viewModel.retrySession(s.id) }) {
                                    Icon(Icons.Filled.Refresh, contentDescription = "Reconnect", tint = OmniColors.cyan)
                                }
                            }
                            IconButton(onClick = { viewModel.requestDisconnectSession(s.id) }) {
                                Icon(Icons.Filled.Close, null, tint = OmniColors.red)
                            }
                        }
                    }
                }
                if (restorableSessions.isNotEmpty()) {
                    item {
                        Text(
                            "Saved persistent sessions",
                            color = OmniColors.textSecondary,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(top = if (sessions.isEmpty()) 0.dp else 8.dp)
                        )
                    }
                    items(restorableSessions, key = { it.tmuxName }) { s ->
                        OmniCard(
                            modifier = Modifier.fillMaxWidth().clickable {
                                viewModel.resumePersistentSession(s.tmuxName)
                            },
                            leftAccent = OmniColors.amber
                        ) {
                            Row(
                                Modifier.padding(12.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(s.serverName, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                                    Text("Tap to reattach tmux session", fontSize = 12.sp, color = OmniColors.amber)
                                }
                                IconButton(onClick = { viewModel.resumePersistentSession(s.tmuxName) }) {
                                    Icon(Icons.Filled.Refresh, contentDescription = "Resume", tint = OmniColors.cyan)
                                }
                            }
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        val targetName = viewModel.selectedServer?.name ?: "server"
        Button(
            onClick = { viewModel.connectTerminal() },
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = OmniColors.cyan)
        ) {
            Text("NEW SESSION → $targetName", fontWeight = FontWeight.Bold)
        }
    }
}

private val TerminalTextStyle = TextStyle(
    fontFamily = OmniFonts.mono,
    fontSize = 14.sp,
    lineHeight = 16.sp,
    letterSpacing = 0.sp,
)

private data class TerminalPalette(
    val background: Color,
    val foreground: Color,
    val cursor: Color,
)

private fun terminalPalette(key: String): TerminalPalette = when (key) {
    "solarized_dark" -> TerminalPalette(Color(0xFF002B36), Color(0xFFEEE8D5), Color(0xFFB58900))
    "matrix" -> TerminalPalette(Color(0xFF050805), Color(0xFF8CFF9A), Color(0xFF00FF41))
    "light" -> TerminalPalette(Color(0xFFF8F8F2), Color(0xFF1F2933), Color(0xFF2563EB))
    else -> TerminalPalette(OmniColors.bg0, OmniColors.textPrimary, OmniColors.cyan)
}

@Composable
fun ShellScreen(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val currentSession = viewModel.currentSession
    val servers by viewModel.servers.collectAsState()
    val srv = currentSession?.let { s -> servers.find { it.id == s.serverId } } ?: viewModel.selectedServer
    if (srv == null) {
        Box(Modifier.fillMaxSize().background(OmniColors.bg0), contentAlignment = Alignment.Center) {
            Text("Add a server first.", color = OmniColors.textSecondary, fontFamily = OmniFonts.mono)
        }
        return
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(OmniColors.bg0)
            // Status bar is handled by the app bar above; only lift the key bar above the keyboard.
            .imePadding(),
    ) {
        Box(Modifier.fillMaxWidth().weight(1f)) {
            Box(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxSize().padding(top = 64.dp)) {
                    when {
                        viewModel.isTerminalConnecting -> ConnectingView(viewModel.terminalConnectionPhase) { viewModel.cancelConnect() }
                        currentSession != null -> ActiveTerminal(viewModel, confirm)
                        else -> {
                            val activeHasAny = viewModel.activeSessions.isNotEmpty()
                            val restorableHasAny = viewModel.restorablePersistentSessions.any { r ->
                                viewModel.activeSessions.none { it.tmuxName == r.tmuxName }
                            }
                            if (activeHasAny || restorableHasAny) {
                                SessionPicker(viewModel)
                            } else {
                                ConnectPrompt(srv, viewModel)
                            }
                        }
                    }
                }
                ServerSelectorBar(
                    viewModel = viewModel,
                    overrideServer = currentSession?.let { s -> servers.find { it.id == s.serverId } } ?: srv,
                    onServerChange = {
                        val newServerId = viewModel.selectedServerId
                        if (currentSession != null && currentSession.serverId != newServerId) {
                            viewModel.sendToBackground()
                            val existingSession = viewModel.activeSessions.find { it.serverId == newServerId && it.isConnected }
                            if (existingSession != null) {
                                viewModel.attachSession(existingSession.id)
                            } else {
                                viewModel.connectTerminal()
                            }
                        }
                    },
                    modifier = Modifier.align(Alignment.TopCenter).zIndex(1f).background(OmniColors.bg3),
                    trailingContent = {
                        val connected = currentSession?.isConnected == true
                        TerminalHeaderAction("NEW", OmniColors.green, enabled = !viewModel.isTerminalConnecting) {
                            viewModel.connectTerminal()
                        }
                        TerminalHeaderAction("BG", OmniColors.cyan, enabled = connected) {
                            viewModel.sendToBackground()
                        }
                        TerminalHeaderAction("DISC", OmniColors.red, OmniColors.redDim, enabled = connected) {
                            currentSession?.let { viewModel.requestDisconnectSession(it.id) }
                        }
                    }
                )
            }
        }

        // The JuiceSSH-style special-key accessory bar sits directly above the keyboard.
        if (currentSession?.isConnected == true) {
            TerminalKeyBar(viewModel)
        }
    }

    viewModel.hostKeyChangedServer?.let { changedSrv ->
        AlertDialog(
            onDismissRequest = { viewModel.dismissHostKeyChangedDialog() },
            title = { Text("Host Key Changed", color = MaterialTheme.colorScheme.error) },
            text = {
                Text(
                    "The SSH host key for ${changedSrv.host} has changed since you last connected.\n\n" +
                    "This may indicate a man-in-the-middle attack. Only proceed if you know the server's key was legitimately regenerated.",
                )
            },
            confirmButton = {
                TextButton(onClick = { viewModel.removeTrustedKeyAndRetry(changedSrv) }) {
                    Text("Remove & Reconnect", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.dismissHostKeyChangedDialog() }) {
                    Text("Cancel")
                }
            },
        )
    }

    // The first-connect "Trust This Server?" dialog is rendered globally by MainAppScreen (see
    // HostKeyApprovalDialog below) so approvals triggered from Test Connection, telemetry probes,
    // or any other tab are visible no matter which screen is on top.
}

/**
 * First-connect SSH host key approval. Hosted by MainAppScreen so it appears over every screen
 * and dialog — a connection blocked on approval would otherwise spin forever whenever the user
 * isn't on the terminal tab (e.g. Test Connection inside the Add Server sheet).
 */
@Composable
fun HostKeyApprovalDialog(viewModel: AppViewModel) {
    val req = viewModel.pendingHostKeyApproval ?: return
    AlertDialog(
        onDismissRequest = { viewModel.approveHostKey(false) },
        title = { Text("Trust This Server?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("A new SSH host key was presented for:")
                Text(req.host, fontWeight = androidx.compose.ui.text.font.FontWeight.Bold)
                Spacer(Modifier.height(4.dp))
                Text("Key type: ${req.keyType}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    req.fingerprint,
                    fontSize = 11.sp,
                    fontFamily = OmniFonts.mono,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Verify this fingerprint matches the server before trusting. Once trusted, it will be stored and checked on future connections.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                // Concrete verification path for users who don't already know how: print the
                // same SHA256 fingerprint on the server's own console and compare.
                val keyFile = when {
                    req.keyType.contains("ed25519", ignoreCase = true) -> "ssh_host_ed25519_key.pub"
                    req.keyType.contains("ecdsa", ignoreCase = true) -> "ssh_host_ecdsa_key.pub"
                    req.keyType.contains("rsa", ignoreCase = true) -> "ssh_host_rsa_key.pub"
                    else -> "ssh_host_*_key.pub"
                }
                Text(
                    "How to verify: on the server's own screen (not over SSH), run:\n" +
                        "ssh-keygen -lf /etc/ssh/$keyFile\n" +
                        "and check it prints the same SHA256 fingerprint.",
                    fontSize = 11.sp,
                    fontFamily = OmniFonts.mono,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { viewModel.approveHostKey(true) }) {
                Text("Trust & Connect")
            }
        },
        dismissButton = {
            TextButton(onClick = { viewModel.approveHostKey(false) }) {
                Text("Reject")
            }
        },
    )
}


@Composable
private fun TerminalHeaderAction(
    label: String,
    color: Color,
    background: Color = OmniColors.bg1,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Spacer(Modifier.width(6.dp))
    Text(
        label,
        color = if (enabled) color else OmniColors.textMuted,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .background(background, RoundedCornerShape(6.dp))
            .padding(horizontal = 7.dp, vertical = 5.dp),
    )
}

@Composable
private fun ConnectPrompt(srv: ServerEntity, viewModel: AppViewModel) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .padding(24.dp)
                .background(OmniColors.bg2, RoundedCornerShape(12.dp))
                .border(1.dp, OmniColors.border, RoundedCornerShape(12.dp))
                .padding(28.dp),
        ) {
            Text(">_", color = OmniColors.cyan, fontSize = 34.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(14.dp))
            Text(srv.name, color = OmniColors.textPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp, fontFamily = OmniFonts.mono)
            Text(
                "${srv.username}@${srv.host}:${srv.port}",
                color = OmniColors.textSecondary,
                fontSize = 14.sp,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            viewModel.terminalDisconnectError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = OmniColors.red, fontSize = 12.sp, fontFamily = OmniFonts.mono)
            }
            Spacer(Modifier.height(18.dp))
            Box(
                Modifier
                    .clickable { viewModel.connectTerminal() }
                    .background(OmniColors.cyanDim, RoundedCornerShape(8.dp))
                    .border(1.dp, OmniColors.cyan, RoundedCornerShape(8.dp))
                    .padding(horizontal = 22.dp, vertical = 12.dp),
            ) {
                Text("Connect", color = OmniColors.cyan, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
            }
        }
    }
}

@Composable
private fun ConnectingView(phase: String, onCancel: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(color = OmniColors.cyan, strokeWidth = 2.dp)
            Spacer(Modifier.height(12.dp))
            Text(phase, color = OmniColors.textSecondary, fontFamily = OmniFonts.mono, fontSize = 14.sp)
            Spacer(Modifier.height(16.dp))
            TextButton(onClick = onCancel) {
                Text("Cancel", color = OmniColors.red)
            }
        }
    }
}

@Composable
private fun ActiveTerminal(viewModel: AppViewModel, confirm: ConfirmController) {
    val snapshot = viewModel.terminalScreen
    val palette = terminalPalette(viewModel.terminalTheme)
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val measurer = rememberTextMeasurer()
    var showCopyOptions by remember { mutableStateOf(false) }
    var copyDialogTitle by remember { mutableStateOf<String?>(null) }
    var copyDialogText by remember { mutableStateOf("") }
    var pendingLargePaste by remember { mutableStateOf<String?>(null) }
    var followTail by remember { mutableStateOf(true) }
    var firstVisibleRow by remember { mutableStateOf(0) }
    var visibleRowCount by remember { mutableStateOf(1) }
    var scrollRemainderPx by remember { mutableStateOf(0f) }

    // Cursor blink - disabled for performance
    val cursorOn = true

    // Follow the tail only while the user is already near it; scrolling up pauses auto-follow.
    // Trigger on ANY snapshot update (even if row count is same) to catch screen-shifts at scrollback limit.
    LaunchedEffect(snapshot.totalRows, visibleRowCount) {
        val maxFirst = (snapshot.totalRows - visibleRowCount).coerceAtLeast(0)
        firstVisibleRow = if (followTail) {
            maxFirst
        } else {
            firstVisibleRow.coerceIn(0, maxFirst)
        }
    }

    LaunchedEffect(firstVisibleRow, visibleRowCount, followTail) {
        viewModel.updateTerminalViewport(firstVisibleRow, visibleRowCount, followTail)
    }

    // Focus the hidden input immediately so the keyboard is available
    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
        keyboard?.show()
    }

    // Font size is user-adjustable (UI buttons + volume keys); re-measure when it changes.
    val density = LocalDensity.current
    val fontSizePx = with(density) { viewModel.terminalFontSize.sp.toPx() }
    val cellMetrics = remember(fontSizePx) {
        val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            typeface = android.graphics.Typeface.MONOSPACE
            textSize = fontSizePx
        }
        val fm = p.fontMetrics
        Pair(p.measureText("M"), fm.descent - fm.ascent)
    }

    Box(Modifier.fillMaxSize().background(palette.background)) {
        BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 6.dp, vertical = 4.dp)) {
            val cellWidth = cellMetrics.first.coerceAtLeast(1f)
            val cellHeight = cellMetrics.second.coerceAtLeast(1f)
            val cols = ((constraints.maxWidth * 0.96f) / cellWidth).toInt().coerceIn(1, 500)
            val rows = (constraints.maxHeight / cellHeight).toInt().coerceIn(1, 300)
            LaunchedEffect(cols, rows) { viewModel.resizeTerminal(cols, rows) }
            LaunchedEffect(rows) { visibleRowCount = rows.coerceAtLeast(1) }
            val scrollableState = rememberScrollableState { delta ->
                val maxFirst = (snapshot.totalRows - visibleRowCount).coerceAtLeast(0)
                val rawRows = (scrollRemainderPx - delta) / cellHeight
                val rowDelta = rawRows.toInt()
                scrollRemainderPx = (rawRows - rowDelta) * cellHeight
                if (rowDelta != 0) {
                    firstVisibleRow = (firstVisibleRow + rowDelta).coerceIn(0, maxFirst)
                    followTail = firstVisibleRow >= maxFirst - 2
                }
                delta
            }

            TerminalCanvas(
                snapshot = snapshot,
                palette = palette,
                cursorOn = cursorOn,
                cellWidthPx = cellWidth,
                cellHeightPx = cellHeight,
                fontSizePx = fontSizePx,
                modifier = Modifier
                    .fillMaxSize()
                    .scrollable(scrollableState, orientation = Orientation.Vertical)
                    .pointerInput(Unit) {
                        detectTapGestures(
                            onTap = {
                                focusRequester.requestFocus()
                                keyboard?.show()
                            },
                            onLongPress = {
                                showCopyOptions = true
                            }
                        )
                    },
            )

            if (!followTail) {
                TextButton(
                    onClick = {
                        followTail = true
                        val bottom = (snapshot.totalRows - visibleRowCount).coerceAtLeast(0)
                        firstVisibleRow = bottom
                        viewModel.updateTerminalViewport(bottom, visibleRowCount, followTail = true)
                    },
                    modifier = Modifier.align(Alignment.BottomEnd),
                    colors = ButtonDefaults.textButtonColors(contentColor = palette.cursor),
                ) {
                    Text("BOTTOM", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
        }

        // Invisible input sink: captures soft-keyboard text + hardware special keys.
        var inputField by remember { mutableStateOf(TextFieldValue(" ", selection = TextRange(1))) }
        BasicTextField(
            value = inputField,
            onValueChange = { tfv ->
                val newText = tfv.text
                if (newText.isEmpty()) {
                    // Backspace deleted the dummy space
                    viewModel.sendKey(TermKey.BACKSPACE)
                } else if (newText.length > 1) {
                    val added = newText.substring(1)
                    if (added.length > 100) {
                        pendingLargePaste = added
                    } else if (added.length > 1) {
                        viewModel.pasteText(added)
                    } else {
                        for (ch in added) {
                            if (ch == '\n' || ch == '\r') viewModel.sendKey(TermKey.ENTER)
                            else viewModel.typeText(ch.toString())
                        }
                    }
                } else if (newText != " ") {
                    // Replaced the dummy space (e.g. selection overwritten)
                    viewModel.sendKey(TermKey.BACKSPACE)
                    if (newText == "\n" || newText == "\r") viewModel.sendKey(TermKey.ENTER)
                    else viewModel.typeText(newText)
                }

                // Always reset to a single space with cursor at the end.
                // This prevents the field from growing, forces keyboard to stay active,
                // and prevents local editing (like cursor movement) from sending massive backspace storms.
                inputField = TextFieldValue(" ", selection = TextRange(1))
            },
            cursorBrush = SolidColor(Color.Transparent),
            textStyle = TerminalTextStyle.copy(color = Color.Transparent),
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                capitalization = KeyboardCapitalization.None,
                keyboardType = KeyboardType.Text,
                imeAction = ImeAction.None,
            ),
            modifier = Modifier
                .align(Alignment.TopStart)
                .size(2.dp)
                .alpha(0.01f)
                .focusRequester(focusRequester)
                .onPreviewKeyEvent { e ->
                    if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (e.key) {
                        Key.Backspace -> { viewModel.sendKey(TermKey.BACKSPACE); true }
                        Key.Enter, Key.NumPadEnter -> { viewModel.sendKey(TermKey.ENTER); true }
                        Key.Tab -> { viewModel.sendKey(TermKey.TAB); true }
                        Key.Escape -> { viewModel.sendKey(TermKey.ESC); true }
                        Key.DirectionUp -> { viewModel.sendKey(TermKey.UP); true }
                        Key.DirectionDown -> { viewModel.sendKey(TermKey.DOWN); true }
                        Key.DirectionLeft -> { viewModel.sendKey(TermKey.LEFT); true }
                        Key.DirectionRight -> { viewModel.sendKey(TermKey.RIGHT); true }
                        else -> false
                    }
                },
        )

        if (showCopyOptions) {
            fun openSelectableText(title: String, text: String) {
                copyDialogTitle = title
                copyDialogText = text
                showCopyOptions = false
            }

            Dialog(
                onDismissRequest = { showCopyOptions = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Box(Modifier.fillMaxSize().padding(18.dp), contentAlignment = Alignment.Center) {
                    Surface(
                        modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                        shape = RoundedCornerShape(8.dp),
                        tonalElevation = 6.dp,
                    ) {
                        Column(
                            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Text("Copy terminal text", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            Text("Choose the terminal text range to copy.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Button(
                                onClick = {
                                    val start = firstVisibleRow.coerceIn(0, snapshot.totalRows)
                                    openSelectableText("Visible screen", viewModel.terminalBufferText(full = false, firstRow = start, rowCount = visibleRowCount))
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("Visible screen")
                            }
                            OutlinedButton(
                                onClick = {
                                    openSelectableText("Full buffer", viewModel.terminalBufferText(full = true))
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("Full buffer")
                            }
                            OutlinedButton(
                                onClick = {
                                    showCopyOptions = false
                                    confirm.ask(
                                        "Clear scrollback?",
                                        "Clear the current terminal scrollback buffer? This removes buffered terminal output from this session.",
                                        confirmLabel = "Clear",
                                    ) {
                                        viewModel.clearTerminalScrollback()
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("Clear scrollback")
                            }
                            TextButton(
                                onClick = { showCopyOptions = false },
                                modifier = Modifier.align(Alignment.End),
                            ) {
                                Text("Cancel")
                            }
                        }
                    }
                }
            }
        }

        pendingLargePaste?.let { paste ->
            AlertDialog(
                onDismissRequest = { pendingLargePaste = null },
                title = { Text("Paste ${paste.length} characters?") },
                text = { Text("You're about to paste a large block of text into the terminal. Confirm to send it.") },
                confirmButton = {
                    TextButton(onClick = {
                        pendingLargePaste = null
                        viewModel.pasteText(paste)
                    }) { Text("Paste") }
                },
                dismissButton = {
                    TextButton(onClick = { pendingLargePaste = null }) { Text("Cancel") }
                },
            )
        }

        copyDialogTitle?.let { title ->
            Dialog(
                onDismissRequest = {
                    copyDialogTitle = null
                    copyDialogText = ""
                    focusRequester.requestFocus()
                    keyboard?.show()
                },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize().padding(16.dp),
                    shape = RoundedCornerShape(8.dp),
                    tonalElevation = 6.dp,
                ) {
                    Column(Modifier.fillMaxSize().padding(12.dp)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Text(title, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            TextButton(
                                onClick = {
                                    copyDialogTitle = null
                                    copyDialogText = ""
                                    focusRequester.requestFocus()
                                    keyboard?.show()
                                },
                            ) {
                                Text("Close")
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        val textColor = MaterialTheme.colorScheme.onSurface.toArgb()
                        val backgroundColor = MaterialTheme.colorScheme.surface.toArgb()
                        AndroidView(
                            factory = { ctx ->
                                android.widget.HorizontalScrollView(ctx).apply {
                                    isHorizontalScrollBarEnabled = true
                                    isFillViewport = true
                                    val scroll = android.widget.ScrollView(ctx).apply {
                                        isVerticalScrollBarEnabled = true
                                    }
                                    val textView = android.widget.TextView(ctx).apply {
                                        tag = "terminal_copy_text"
                                        typeface = android.graphics.Typeface.MONOSPACE
                                        textSize = 12f
                                        setTextColor(textColor)
                                        setBackgroundColor(backgroundColor)
                                        setPadding(16, 16, 16, 16)
                                        setTextIsSelectable(true)
                                        isFocusable = true
                                        isFocusableInTouchMode = true
                                        setHorizontallyScrolling(true)
                                    }
                                    scroll.addView(
                                        textView,
                                        android.view.ViewGroup.LayoutParams(
                                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                                        ),
                                    )
                                    addView(
                                        scroll,
                                        android.view.ViewGroup.LayoutParams(
                                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                                            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                        ),
                                    )
                                }
                            },
                            update = { hsv ->
                                val scroll = hsv.getChildAt(0) as android.widget.ScrollView
                                val tv = scroll.getChildAt(0) as android.widget.TextView
                                tv.setTextColor(textColor)
                                tv.setBackgroundColor(backgroundColor)
                                val nextText = copyDialogText.ifBlank { "No terminal text in this range." }
                                if (tv.text.toString() != nextText) tv.text = nextText
                            },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TerminalCanvas(
    snapshot: TerminalSnapshot,
    palette: TerminalPalette,
    cursorOn: Boolean,
    cellWidthPx: Float,
    cellHeightPx: Float,
    fontSizePx: Float,
    modifier: Modifier = Modifier,
) {
    val backgroundArgb = palette.background.toArgb()
    val foregroundArgb = palette.foreground.toArgb()
    val cursorArgb = palette.cursor.toArgb()
    Canvas(modifier.background(palette.background)) {
        val rowsToDraw = ceil(size.height / cellHeightPx).toInt().coerceAtLeast(1)
        val end = rowsToDraw.coerceAtMost(snapshot.rows.size)
        drawIntoCanvas { canvas ->
            val native = canvas.nativeCanvas
            // CENTER alignment so each glyph can be pinned to the centre of its grid cell (see the
            // per-character draw loop below) — this is what keeps text monospaced on the cell grid.
            val regularPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                typeface = Typeface.MONOSPACE
                textSize = fontSizePx
                color = foregroundArgb
                textAlign = Paint.Align.CENTER
            }
            val boldPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
                textSize = fontSizePx
                color = foregroundArgb
                textAlign = Paint.Align.CENTER
            }
            val bgPaint = Paint().apply { style = Paint.Style.FILL }
            val cursorPaint = Paint().apply {
                style = Paint.Style.FILL
                color = cursorArgb
            }
            val fm = regularPaint.fontMetrics
            val baselineOffset = (cellHeightPx - fm.ascent - fm.descent) / 2f
            native.drawColor(backgroundArgb)

            for (rowIndex in 0 until end) {
                val absoluteRow = snapshot.firstRow + rowIndex
                val row = snapshot.rows[rowIndex]
                val yTop = rowIndex * cellHeightPx
                bgPaint.color = backgroundArgb
                native.drawRect(0f, yTop, size.width, yTop + cellHeightPx, bgPaint)
                var col = 0
                for (span in row.spans) {
                    val fgInt = if (span.inverse) span.bg else span.fg
                    val bgInt = if (span.inverse) span.fg else span.bg
                    val paint = if (span.bold) boldPaint else regularPaint
                    paint.color = if (fgInt == TerminalEmulator.DEFAULT_FG) foregroundArgb else fgInt
                    // SGR text attributes: italic via glyph skew (no italic monospace variant is
                    // guaranteed on-device), underline natively, dim as reduced alpha.
                    paint.textSkewX = if (span.italic) -0.25f else 0f
                    paint.isUnderlineText = span.underline
                    // Reset alpha every span: dim is per-span, and the paint is shared/reused.
                    paint.alpha = if (span.dim) 150 else 255
                    val x = col * cellWidthPx
                    val width = span.text.length * cellWidthPx
                    if (bgInt != TerminalEmulator.DEFAULT_BG || span.inverse) {
                        bgPaint.color = if (bgInt == TerminalEmulator.DEFAULT_BG) backgroundArgb else bgInt
                        native.drawRect(x, yTop, x + width, yTop + cellHeightPx, bgPaint)
                    }
                    // Draw each glyph pinned to its own grid cell. Drawing a whole span in one
                    // drawText() call lets the font advance glyphs by their intrinsic (subpixel)
                    // widths, which drifts away from the fixed cellWidthPx grid and makes characters
                    // look bunched up or spread out. Centering each char in its cell keeps the
                    // terminal perfectly monospaced regardless of the font's actual advances.
                    val baselineY = yTop + baselineOffset
                    for (i in span.text.indices) {
                        val cellCenterX = (col + i) * cellWidthPx + cellWidthPx / 2f
                        native.drawText(span.text, i, i + 1, cellCenterX, baselineY, paint)
                    }
                    col += span.text.length
                }
                if (cursorOn && snapshot.cursorVisible && absoluteRow == snapshot.cursorRow) {
                    val cursorX = snapshot.cursorCol * cellWidthPx
                    native.drawRect(cursorX, yTop, cursorX + cellWidthPx, yTop + cellHeightPx, cursorPaint)
                    val ch = rowCharAt(row, snapshot.cursorCol)
                    if (ch != null) {
                        // Reset attributes the span loop may have left on the shared paint.
                        regularPaint.textSkewX = 0f
                        regularPaint.isUnderlineText = false
                        regularPaint.color = backgroundArgb
                        // regularPaint is CENTER-aligned, so draw at the cell centre (matches the grid).
                        native.drawText(ch.toString(), cursorX + cellWidthPx / 2f, yTop + baselineOffset, regularPaint)
                    }
                }
            }
        }
    }
}

private fun rowCharAt(row: TermRow, targetCol: Int): Char? {
    if (targetCol < 0) return null
    var col = 0
    for (span in row.spans) {
        val next = col + span.text.length
        if (targetCol in col until next) return span.text[targetCol - col]
        col = next
    }
    return ' '
}

@Composable
private fun TerminalKeyBar(viewModel: AppViewModel) {
    var showSymbols by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .background(OmniColors.bg1)
            .padding(vertical = 4.dp),
    ) {
        if (showSymbols) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                listOf("~", "_", ".", ":", ";", "'", "\"", "`").forEach { symbol ->
                    KeyCap(symbol, Modifier.weight(1f)) { viewModel.typeText(symbol) }
                }
            }
            Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                listOf("\$", "&", "*", "(", ")", "[", "]").forEach { symbol ->
                    KeyCap(symbol, Modifier.weight(1f)) { viewModel.typeText(symbol) }
                }
                KeyCap("SYM", Modifier.weight(1f), active = true, activeColor = OmniColors.purple) {
                    showSymbols = false
                    viewModel.isFunctionSetVisible = false
                }
            }
        } else if (!viewModel.isFunctionSetVisible) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                KeyCap("TAB", Modifier.weight(1f)) { viewModel.sendKey(TermKey.TAB) }
                KeyCap("ESC", Modifier.weight(1f)) { viewModel.sendKey(TermKey.ESC) }
                KeyCap("CTRL", Modifier.weight(1f), active = viewModel.isCtrlPressed) { viewModel.isCtrlPressed = !viewModel.isCtrlPressed }
                KeyCap("↑", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.UP) }
                KeyCap("ALT", Modifier.weight(1f), active = viewModel.isAltPressed) { viewModel.isAltPressed = !viewModel.isAltPressed }
                KeyCap("/", Modifier.weight(1f)) { viewModel.typeText("/") }
                KeyCap("SYM", Modifier.weight(1f), active = true, activeColor = OmniColors.purple) { showSymbols = true }
                KeyCap("FN", Modifier.weight(1f), active = true, activeColor = OmniColors.amber) { viewModel.isFunctionSetVisible = true }
            }
            Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                KeyCap("SHFT", Modifier.weight(1f), active = viewModel.isShiftPressed) { viewModel.isShiftPressed = !viewModel.isShiftPressed }
                KeyCap("HOME", Modifier.weight(1f)) { viewModel.sendKey(TermKey.HOME) }
                KeyCap("←", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.LEFT) }
                KeyCap("↓", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.DOWN) }
                KeyCap("→", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.RIGHT) }
                KeyCap("END", Modifier.weight(1f)) { viewModel.sendKey(TermKey.END) }
                KeyCap("-", Modifier.weight(1f)) { viewModel.typeText("-") }
                KeyCap("↵", Modifier.weight(1f)) { viewModel.sendKey(TermKey.ENTER) }
            }
        } else {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                KeyCap("F1", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F1) }
                KeyCap("F2", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F2) }
                KeyCap("F3", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F3) }
                KeyCap("F4", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F4) }
                KeyCap("F5", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F5) }
                KeyCap("F6", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F6) }
                KeyCap("ESC", Modifier.weight(1f)) { viewModel.sendKey(TermKey.ESC) }
                KeyCap("NAV", Modifier.weight(1f), active = true, activeColor = OmniColors.amber) { viewModel.isFunctionSetVisible = false }
            }
            Spacer(Modifier.height(4.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                KeyCap("F7", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F7) }
                KeyCap("F8", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F8) }
                KeyCap("F9", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F9) }
                KeyCap("F10", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F10) }
                KeyCap("F11", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F11) }
                KeyCap("F12", Modifier.weight(1f)) { viewModel.sendKey(TermKey.F12) }
                KeyCap("PGUP", Modifier.weight(1f)) { viewModel.sendKey(TermKey.PAGE_UP) }
                KeyCap("PGDN", Modifier.weight(1f)) { viewModel.sendKey(TermKey.PAGE_DOWN) }
            }
        }
    }
}

@Composable
private fun KeyCap(
    label: String,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    activeColor: Color = OmniColors.amber,
    repeatable: Boolean = false,
    onClick: () -> Unit
) {
    val haptics = LocalHapticFeedback.current
    val currentOnClick by rememberUpdatedState(onClick)
    val scope = rememberCoroutineScope()
    Box(
        modifier = modifier
            .padding(horizontal = 2.dp)
            .height(34.dp)
            .background(if (active) activeColor else OmniColors.bg3, RoundedCornerShape(5.dp))
            .border(1.dp, if (active) activeColor else OmniColors.border, RoundedCornerShape(5.dp))
            .then(
                if (repeatable) {
                    Modifier.pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown()
                            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            currentOnClick()
                            val job = scope.launch {
                                delay(400) // Initial delay before repeating
                                while (isActive) {
                                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                    currentOnClick()
                                    delay(60) // Repeat interval
                                }
                            }
                            waitForUpOrCancellation()
                            job.cancel()
                        }
                    }
                } else {
                    Modifier.clickable {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        currentOnClick()
                    }
                }
            ),
        contentAlignment = Alignment.Center,
    ) {
        val fs = when (label) {
            "↵", "-" -> 18.sp
            else -> 12.sp
        }
        Text(
            label,
            color = if (active) OmniColors.bg0 else OmniColors.textPrimary,
            fontSize = fs,
            fontWeight = FontWeight.Bold,
            fontFamily = OmniFonts.mono,
            maxLines = 1,
        )
    }
}
