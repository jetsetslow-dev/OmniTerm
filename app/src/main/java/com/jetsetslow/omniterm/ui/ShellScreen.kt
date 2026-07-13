package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniFonts
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.rememberScrollableState
import androidx.compose.foundation.gestures.scrollable
import androidx.compose.foundation.gestures.stopScroll
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.KeyboardDoubleArrowDown
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint as ComposePaint
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
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
    val chrome = shellChromePalette()
    val sessions = viewModel.activeSessions
    val restorableSessions = viewModel.restorablePersistentSessions.filter { r ->
        sessions.none { it.tmuxName == r.tmuxName }
    }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Active Sessions", color = chrome.text, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.display, fontSize = 20.sp)
        Spacer(Modifier.height(4.dp))
        Text("Tap a session to resume, or start a new one.", color = chrome.mutedText, fontSize = 12.sp)
        Spacer(Modifier.height(12.dp))

        if (sessions.isEmpty() && restorableSessions.isEmpty()) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                Text("No active sessions.", color = chrome.disabledText)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.weight(1f)) {
                items(sessions) { s ->
                    OmniCard(
                        modifier = Modifier.fillMaxWidth().clickable {
                            viewModel.attachSession(s.id)
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
                                if (s.persistent) {
                                    Text(
                                        displayTmuxSessionName(s.tmuxName),
                                        fontSize = 12.sp,
                                        color = chrome.mutedText,
                                        fontFamily = OmniFonts.mono,
                                    )
                                }
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
                            color = chrome.mutedText,
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
                                    Text(
                                        displayTmuxSessionName(s.tmuxName),
                                        fontSize = 12.sp,
                                        color = chrome.mutedText,
                                        fontFamily = OmniFonts.mono,
                                    )
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
    /**
     * Optional replacement for the 16 base ANSI colours when used as *text*. The emulator's palette
     * is tuned for dark backgrounds; on a light background those bright tones (yellow, white, cyan…)
     * wash out to near-invisible. Only the foreground role is remapped — coloured background blocks
     * stay saturated and visible on either background.
     */
    val ansiFgOverride: IntArray? = null,
)

private data class ShellChromePalette(
    val background: Color,
    val bar: Color,
    val paneBackground: Color,
    val paneHeader: Color,
    val paneHeaderFocused: Color,
    val keyBackground: Color,
    val keyCap: Color,
    val keyText: Color,
    val text: Color,
    val mutedText: Color,
    val disabledText: Color,
    val border: Color,
    val actionBackground: Color,
    val dangerBackground: Color,
)

@Composable
private fun shellChromePalette(): ShellChromePalette {
    val scheme = MaterialTheme.colorScheme
    val isLight = relativeLuminance(scheme.background.toArgb()) > 0.5f
    return ShellChromePalette(
        background = scheme.background,
        bar = if (isLight) scheme.surface else scheme.surfaceContainerHigh,
        paneBackground = scheme.background,
        paneHeader = scheme.surfaceContainer,
        paneHeaderFocused = scheme.surfaceContainerHigh,
        keyBackground = scheme.surface,
        keyCap = scheme.surfaceContainerHigh,
        keyText = scheme.onSurface,
        text = scheme.onSurface,
        mutedText = scheme.onSurfaceVariant,
        disabledText = scheme.onSurfaceVariant.copy(alpha = 0.58f),
        border = scheme.outline,
        actionBackground = scheme.surfaceContainerHighest,
        dangerBackground = scheme.errorContainer.copy(alpha = if (isLight) 0.75f else 0.35f),
    )
}

// ANSI-16 text colours for the light terminal theme: same hue identity as the dark palette but deep
// enough to clear contrast on the near-white background (bright yellow/white/cyan were unreadable).
private val LIGHT_ANSI_FG = intArrayOf(
    0xFF000000.toInt(), // 0 black
    0xFFC42B1C.toInt(), // 1 red
    0xFF0E7A0B.toInt(), // 2 green
    0xFF8A6A00.toInt(), // 3 yellow → dark amber
    0xFF0451A5.toInt(), // 4 blue
    0xFFA1259E.toInt(), // 5 magenta
    0xFF067A8C.toInt(), // 6 cyan
    0xFF555F6E.toInt(), // 7 white → readable grey
    0xFF66707F.toInt(), // 8 bright black
    0xFFD13438.toInt(), // 9 bright red
    0xFF10893E.toInt(), // 10 bright green
    0xFF9A7100.toInt(), // 11 bright yellow
    0xFF2563EB.toInt(), // 12 bright blue
    0xFFB4009E.toInt(), // 13 bright magenta
    0xFF038387.toInt(), // 14 bright cyan
    0xFF24292F.toInt(), // 15 bright white → near-black
)

/**
 * Recover the ANSI-16 index from a cell's resolved ARGB, or -1 if the colour didn't come from the
 * base palette (cube/truecolour). Cells store resolved ints, so this value scan is how the renderer
 * re-themes the base colours. 16-entry linear scan: allocation-free for the per-span hot path.
 */
private fun ansi16Index(argb: Int): Int {
    for (i in 0..15) if (TerminalEmulator.PALETTE_256[i] == argb) return i
    return -1
}

@Composable
private fun terminalPalette(key: String): TerminalPalette {
    val scheme = MaterialTheme.colorScheme
    val appIsLight = relativeLuminance(scheme.background.toArgb()) > 0.5f
    return when (key) {
    "solarized_dark" -> TerminalPalette(Color(0xFF002B36), Color(0xFFEEE8D5), Color(0xFFB58900))
    "matrix" -> TerminalPalette(Color(0xFF050805), Color(0xFF8CFF9A), Color(0xFF00FF41))
    "omni_dark" -> TerminalPalette(OmniColors.bg0, OmniColors.textPrimary, OmniColors.cyan)
    "light" -> TerminalPalette(Color(0xFFFFFFFF), Color(0xFF111827), Color(0xFF005FCC), LIGHT_ANSI_FG)
    else -> if (appIsLight) {
        TerminalPalette(Color(0xFFFFFFFF), Color(0xFF111827), scheme.primary, LIGHT_ANSI_FG)
    } else {
        TerminalPalette(scheme.background, scheme.onBackground, scheme.primary)
    }
    }
}

@Composable
fun ShellScreen(viewModel: AppViewModel) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val chrome = shellChromePalette()
    val currentSession = viewModel.currentSession
    // The header identifies exactly the focused terminal. Do not fall back to the other split pane
    // when the focused pane is empty; that made the top host name actively misleading.
    val headerSession = if (viewModel.isMultiSsh) {
        viewModel.multiSshPaneSession(viewModel.multiSshFocusedPane)
    } else {
        currentSession
    }
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val onlineServers = servers.filter { it.status == "online" }
    // Offline hosts are hidden here like on the other live tabs — new connects only ever offer
    // online hosts. Forcing SSH to an offline host is done from the Hosts tab's connect button,
    // which warns first. A host with an active/connecting session stays visible even if its
    // probe drops to offline (reconnect UX), and existing sessions keep the screen alive so the
    // session picker stays reachable when every host is offline at once.
    val srv = headerSession?.let { s -> servers.find { it.id == s.serverId } }
        ?: onlineServers.find { it.id == viewModel.selectedServerId }
        ?: onlineServers.firstOrNull()
        ?: viewModel.selectedServer.takeIf {
            viewModel.activeSessions.isNotEmpty() ||
                viewModel.restorablePersistentSessions.isNotEmpty() ||
                viewModel.isTerminalConnecting
        }
    if (srv == null) {
        Box(Modifier.fillMaxSize().background(chrome.background), contentAlignment = Alignment.Center) {
            Text(
                if (servers.isEmpty()) {
                    "Add a server first."
                } else {
                    "No online hosts. To SSH into an offline host anyway, use its connect button on the Hosts tab."
                },
                color = chrome.mutedText,
                fontFamily = OmniFonts.mono,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(24.dp),
            )
        }
        return
    }
    // Keep the VM selection on the host shown here so Connect / NEW / split-pane actions target
    // exactly what's displayed (the displayed host can differ when the selected one went offline).
    LaunchedEffect(srv.id, headerSession?.id) {
        if (headerSession == null && !viewModel.isTerminalConnecting && viewModel.selectedServerId != srv.id) {
            viewModel.selectedServerId = srv.id
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(chrome.background)
            // Status bar is handled by the app bar above; only lift the key bar above the keyboard.
            .imePadding(),
    ) {
        Box(Modifier.fillMaxWidth().weight(1f)) {
            Box(Modifier.fillMaxSize()) {
                // The overlaid header is now two rows (host info + action chips), so its height is
                // measured rather than hardcoded — the terminal starts exactly below it.
                val density = LocalDensity.current
                var headerHeight by remember { mutableStateOf(64.dp) }
                Box(Modifier.fillMaxSize().padding(top = headerHeight)) {
                    when {
                        // Split view takes priority: it manages its own connecting/empty panes, so
                        // it stays mounted even while one pane is mid-connect.
                        viewModel.isMultiSsh -> MultiSshTerminalView(viewModel, confirm)
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
                    // Offline hosts are hidden from the picker — force-connect lives on the Hosts tab.
                    onlineOnly = true,
                    overrideServer = headerSession?.let { s -> servers.find { it.id == s.serverId } } ?: srv,
                    onServerChange = {
                        val newServerId = viewModel.selectedServerId
                        if (headerSession != null && headerSession.serverId != newServerId) {
                            confirm.ask(
                                title = "Send Session to Background?",
                                message = "OmniTerm will keep the SSH session active while you switch hosts. This may increase battery consumption.",
                                confirmLabel = "Send to background",
                                destructive = false,
                            ) {
                                viewModel.sendSessionToBackground(headerSession.id)
                                val existingSession = viewModel.activeSessions.find { it.serverId == newServerId && it.isConnected }
                                if (existingSession != null) {
                                    if (viewModel.isMultiSsh) {
                                        viewModel.assignMultiSshPane(viewModel.multiSshFocusedPane, existingSession.id)
                                    } else {
                                        viewModel.attachSession(existingSession.id)
                                    }
                                } else {
                                    viewModel.connectTerminal()
                                }
                            }
                        }
                    },
                    allowSplitSelection = viewModel.isMultiSsh,
                    onOpenSplit = viewModel::openMultiSshForServers,
                    leadingContent = {
                        Text(
                            if (viewModel.isMultiSsh) "P${viewModel.multiSshFocusedPane}" else "TERM",
                            color = OmniColors.cyan,
                            fontSize = 9.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = OmniFonts.mono,
                        )
                    },
                    trailingContent = {
                        Text(
                            if (viewModel.isMultiSsh) "FOCUSED" else "CURRENT",
                            fontSize = 9.sp,
                            fontWeight = FontWeight.Bold,
                            color = OmniColors.cyan,
                        )
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = "Switch host", tint = OmniColors.cyan)
                    },
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .zIndex(1f)
                        .background(chrome.bar)
                        .onGloballyPositioned { headerHeight = with(density) { it.size.height.toDp() } },
                    // Second row: the action chips previously sat inline and squeezed the
                    // name/user@host/latency text into ellipsis on narrow screens.
                    secondRowContent = {
                        // In split view every session action must target the *focused pane's*
                        // session — currentSession can be the other pane (or a background session),
                        // and DISC/BG/RECON acting on it silently hit the wrong terminal.
                        val actionSession =
                            if (viewModel.isMultiSsh) viewModel.multiSshPaneSession(viewModel.multiSshFocusedPane)
                            else currentSession
                        val connected = actionSession?.isConnected == true
                        val reconnecting = actionSession?.reconnecting == true
                        if (viewModel.isMultiSsh) {
                            // Flip side-by-side ↔ stacked, and a way back to single-session view.
                            val layoutLabel = if (viewModel.multiSshLayout == MultiSshLayout.SideBySide) "⬍ STACK" else "⬌ COLS"
                            TerminalHeaderAction(layoutLabel, OmniColors.purple, modifier = Modifier.weight(1f)) {
                                viewModel.multiSshLayout =
                                    if (viewModel.multiSshLayout == MultiSshLayout.SideBySide) MultiSshLayout.Stacked
                                    else MultiSshLayout.SideBySide
                            }
                            TerminalHeaderAction("SINGLE", OmniColors.amber, modifier = Modifier.weight(1f)) { viewModel.exitMultiSsh() }
                        } else {
                            TerminalHeaderAction("SPLIT", OmniColors.purple, enabled = !viewModel.isTerminalConnecting, modifier = Modifier.weight(1f)) {
                                viewModel.enterMultiSsh()
                            }
                        }
                        TerminalOpenPicker(viewModel, actionSession, modifier = Modifier.weight(1f))
                        TerminalHeaderAction("BG", OmniColors.cyan, enabled = connected, modifier = Modifier.weight(1f)) {
                            confirm.ask(
                                title = "Send Session to Background?",
                                message = "OmniTerm will keep the SSH session active in the background. This may increase battery consumption.",
                                confirmLabel = "Send to background",
                                destructive = false,
                            ) {
                                actionSession?.let { viewModel.sendSessionToBackground(it.id) }
                            }
                        }
                        // A dropped session that isn't already retrying gets a manual reconnect here,
                        // so a stuck/exhausted auto-reconnect can be re-kicked without leaving the
                        // terminal view (previously only the session-list picker offered this).
                        if (actionSession != null && !connected && !reconnecting) {
                            TerminalHeaderAction("RECON", OmniColors.cyan, modifier = Modifier.weight(1f)) {
                                viewModel.retrySession(actionSession.id)
                            }
                        }
                        // DISC is ALWAYS available whenever a session exists — including mid-reconnect.
                        // A user disconnect cancels any in-flight reconnect and tears the session down,
                        // which is the escape hatch out of a "stuck reconnecting" limbo state.
                        TerminalHeaderAction("DISC", OmniColors.red, chrome.dangerBackground, enabled = actionSession != null, modifier = Modifier.weight(1f)) {
                            actionSession?.let { viewModel.requestDisconnectSession(it.id) }
                        }
                    }
                )
            }
        }

        // The JuiceSSH-style special-key accessory bar sits directly above the keyboard. In split
        // view it targets the focused pane (input routing already follows the focused session).
        val keyBarSession = if (viewModel.isMultiSsh) viewModel.multiSshPaneSession(viewModel.multiSshFocusedPane) else currentSession
        if (keyBarSession?.isConnected == true) {
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
    background: Color? = null,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val chrome = shellChromePalette()
    val container = background ?: chrome.actionBackground
    val accessibilityLabel = when {
        label == "SPLIT" -> "Open split terminal"
        label == "SINGLE" -> "Return to single terminal"
        label == "BG" -> "Send current session to background"
        label == "DISC" -> "Disconnect current session"
        label == "RECON" -> "Reconnect current session"
        label.contains("STACK") -> "Stack split panes"
        label.contains("COLS") -> "Show split panes side by side"
        else -> label
    }
    Text(
        label,
        color = if (enabled) color else chrome.disabledText,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        maxLines = 1,
        textAlign = TextAlign.Center,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .background(container, RoundedCornerShape(6.dp))
            .heightIn(min = 34.dp)
            .wrapContentHeight(Alignment.CenterVertically)
            .padding(horizontal = 7.dp, vertical = 6.dp)
            .semantics { contentDescription = accessibilityLabel },
    )
}

/**
 * Top-level session switcher. It replaces the ambiguous NEW-only action with one place to attach a
 * background session, resume a saved tmux session, or deliberately create a fresh terminal.
 */
@Composable
private fun TerminalOpenPicker(
    viewModel: AppViewModel,
    currentSession: ShellSession?,
    modifier: Modifier = Modifier,
) {
    val chrome = shellChromePalette()
    val focusedPane = viewModel.multiSshFocusedPane
    val otherPaneSessionId = if (!viewModel.isMultiSsh) null else {
        if (focusedPane == 1) viewModel.multiSshSessionId2 else viewModel.multiSshSessionId1
    }
    val backgroundSessions = viewModel.activeSessions.filter {
        it.id != currentSession?.id && it.id != otherPaneSessionId
    }
    val resumableSessions = viewModel.restorablePersistentSessions.filter { saved ->
        viewModel.activeSessions.none { it.tmuxName == saved.tmuxName }
    }
    var expanded by remember { mutableStateOf(false) }

    Box(modifier) {
        Text(
            "OPEN ▾",
            color = if (viewModel.isTerminalConnecting) chrome.disabledText else OmniColors.green,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .clickable(enabled = !viewModel.isTerminalConnecting) { expanded = true }
                .background(chrome.actionBackground, RoundedCornerShape(6.dp))
                .heightIn(min = 34.dp)
                .wrapContentHeight(Alignment.CenterVertically)
                .padding(horizontal = 7.dp, vertical = 6.dp)
                .semantics { contentDescription = "Open or switch terminal session" },
        )
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.widthIn(min = 260.dp, max = 340.dp).heightIn(max = 440.dp),
        ) {
            currentSession?.let { session ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(
                                if (viewModel.isMultiSsh) "PANE $focusedPane · ${session.serverName}" else "CURRENT · ${session.serverName}",
                                fontFamily = OmniFonts.mono,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                            )
                            if (session.persistent) {
                                Text(displayTmuxSessionName(session.tmuxName), fontSize = 10.sp, color = OmniColors.amber)
                            }
                        }
                    },
                    leadingIcon = { Icon(Icons.Filled.Check, contentDescription = null) },
                    enabled = false,
                    onClick = {},
                )
                HorizontalDivider()
            }
            if (backgroundSessions.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("BACKGROUND SESSIONS", fontSize = 10.sp, fontWeight = FontWeight.Bold) },
                    enabled = false,
                    onClick = {},
                )
                backgroundSessions.forEach { session ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(session.serverName, fontFamily = OmniFonts.mono, fontSize = 12.sp)
                                Text(
                                    if (session.persistent) displayTmuxSessionName(session.tmuxName) else "Live SSH session",
                                    fontSize = 10.sp,
                                    color = if (session.persistent) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        },
                        onClick = {
                            if (viewModel.isMultiSsh) viewModel.assignMultiSshPane(focusedPane, session.id)
                            else viewModel.attachSession(session.id)
                            expanded = false
                        },
                    )
                }
            }
            if (resumableSessions.isNotEmpty()) {
                if (backgroundSessions.isNotEmpty()) HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("RESUMABLE TMUX", fontSize = 10.sp, fontWeight = FontWeight.Bold) },
                    enabled = false,
                    onClick = {},
                )
                resumableSessions.forEach { saved ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(saved.serverName, fontFamily = OmniFonts.mono, fontSize = 12.sp)
                                Text(displayTmuxSessionName(saved.tmuxName), fontSize = 10.sp, color = OmniColors.amber)
                            }
                        },
                        onClick = {
                            if (viewModel.isMultiSsh) viewModel.setMultiSshFocus(focusedPane)
                            viewModel.resumePersistentSession(saved.tmuxName)
                            expanded = false
                        },
                    )
                }
            }
            if (backgroundSessions.isNotEmpty() || resumableSessions.isNotEmpty() || currentSession != null) HorizontalDivider()
            DropdownMenuItem(
                text = {
                    Text(
                        "New session · ${viewModel.selectedServer?.name ?: "selected host"}",
                        fontFamily = OmniFonts.mono,
                    )
                },
                leadingIcon = { Text("+", fontSize = 20.sp, color = OmniColors.green) },
                enabled = !viewModel.isTerminalConnecting,
                onClick = {
                    viewModel.connectTerminal()
                    expanded = false
                },
            )
        }
    }
}

@Composable
private fun ConnectPrompt(srv: ServerEntity, viewModel: AppViewModel) {
    val chrome = shellChromePalette()
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .padding(24.dp)
                .background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(12.dp))
                .border(1.dp, chrome.border, RoundedCornerShape(12.dp))
                .padding(28.dp),
        ) {
            Text(">_", color = OmniColors.cyan, fontSize = 34.sp, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(14.dp))
            Text(srv.name, color = chrome.text, fontWeight = FontWeight.Bold, fontSize = 18.sp, fontFamily = OmniFonts.mono)
            Text(
                "${srv.username}@${srv.host}:${srv.port}",
                color = chrome.mutedText,
                fontSize = 14.sp,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            viewModel.terminalDisconnectError?.let {
                Spacer(Modifier.height(12.dp))
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .background(OmniColors.red.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
                        .border(1.dp, OmniColors.red.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Text(
                        "CONNECTION FAILED",
                        color = OmniColors.red,
                        fontSize = 11.sp,
                        fontFamily = OmniFonts.mono,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        it,
                        color = chrome.mutedText,
                        fontSize = 12.sp,
                        fontFamily = OmniFonts.mono,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            Spacer(Modifier.height(18.dp))
            Box(
                Modifier
                    .clickable { viewModel.connectTerminal() }
                    .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(8.dp))
                    .border(1.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(8.dp))
                    .padding(horizontal = 22.dp, vertical = 12.dp),
            ) {
                Text("Connect", color = MaterialTheme.colorScheme.onPrimaryContainer, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
            }
        }
    }
}

@Composable
private fun ConnectingView(phase: String, onCancel: () -> Unit) {
    val chrome = shellChromePalette()
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(color = OmniColors.cyan, strokeWidth = 2.dp)
            Spacer(Modifier.height(12.dp))
            Text(phase, color = chrome.mutedText, fontFamily = OmniFonts.mono, fontSize = 14.sp)
            Spacer(Modifier.height(16.dp))
            TextButton(onClick = onCancel) {
                Text("Cancel", color = OmniColors.red)
            }
        }
    }
}

@Composable
private fun ActiveTerminal(viewModel: AppViewModel, confirm: ConfirmController) {
    val currentSession = viewModel.currentSession ?: return
    PaneTerminal(
        viewModel = viewModel,
        session = currentSession,
        confirm = confirm,
        isFocused = true,
        onRequestFocus = {},
    )
}

/**
 * MultiSSH split view: two terminal panes, arranged side-by-side or stacked. Each pane renders its
 * own session (or a connect/pick prompt when empty), resizes its own PTY, and scrolls independently.
 * Exactly one pane is focused at a time; the focused pane owns the keyboard and the special-key bar.
 * Tapping the unfocused pane moves focus to it. A thin accent border marks the focused pane.
 */
@Composable
private fun MultiSshTerminalView(viewModel: AppViewModel, confirm: ConfirmController) {
    val chrome = shellChromePalette()
    val stacked = viewModel.multiSshLayout == MultiSshLayout.Stacked
    val pane1 = viewModel.multiSshSession1
    val pane2 = viewModel.multiSshSession2
    val focused = viewModel.multiSshFocusedPane

    @Composable
    fun paneContent(paneIndex: Int, session: ShellSession?, modifier: Modifier) {
        val isFocused = focused == paneIndex
        Box(
            modifier
                .clip(RoundedCornerShape(6.dp))
                .border(
                    width = if (isFocused) 2.dp else 1.dp,
                    color = if (isFocused) OmniColors.cyan else chrome.border,
                    shape = RoundedCornerShape(6.dp),
                )
                .background(chrome.paneBackground),
        ) {
            Column(Modifier.fillMaxSize()) {
                MultiSshPaneHeader(viewModel, paneIndex, session, isFocused)
                Box(Modifier.fillMaxWidth().weight(1f)) {
                    if (session != null) {
                        PaneTerminal(
                            viewModel = viewModel,
                            session = session,
                            confirm = confirm,
                            isFocused = isFocused,
                            onRequestFocus = { viewModel.setMultiSshFocus(paneIndex) },
                        )
                    } else {
                        MultiSshEmptyPane(viewModel, paneIndex)
                    }
                }
            }
        }
    }

    // In-session split ratio (pane 1's share). Defaults to 50/50 and is NOT persisted — a fresh
    // launch always starts balanced. Reset when the orientation flips so a lopsided horizontal
    // split doesn't carry into a vertical one. Clamp is generous so a pane can be made small but
    // never collapse to nothing.
    var fraction by remember(stacked) { mutableStateOf(0.5f) }
    // Track the container's main-axis size so a pixel drag maps to a fraction delta.
    var axisPx by remember { mutableStateOf(0f) }

    if (stacked) {
        Column(
            Modifier.fillMaxSize().padding(4.dp)
                .onSizeChanged { axisPx = it.height.toFloat() },
        ) {
            paneContent(1, pane1, Modifier.fillMaxWidth().weight(fraction))
            SplitHandle(stacked = true, onReset = { fraction = 0.5f }) { deltaPx ->
                if (axisPx > 0f) fraction = (fraction + deltaPx / axisPx).coerceIn(0.15f, 0.85f)
            }
            paneContent(2, pane2, Modifier.fillMaxWidth().weight(1f - fraction))
        }
    } else {
        Row(
            Modifier.fillMaxSize().padding(4.dp)
                .onSizeChanged { axisPx = it.width.toFloat() },
        ) {
            paneContent(1, pane1, Modifier.fillMaxHeight().weight(fraction))
            SplitHandle(stacked = false, onReset = { fraction = 0.5f }) { deltaPx ->
                if (axisPx > 0f) fraction = (fraction + deltaPx / axisPx).coerceIn(0.15f, 0.85f)
            }
            paneContent(2, pane2, Modifier.fillMaxHeight().weight(1f - fraction))
        }
    }
}

/**
 * A draggable divider between two split panes. Dragging along the split axis reports the raw pixel
 * delta to [onDrag], which the caller converts to a fraction change — free movement, no snapping.
 * Double-tap resets to a balanced 50/50. A grip bar makes the hit target obvious and easy to grab.
 */
@Composable
private fun SplitHandle(stacked: Boolean, onReset: (() -> Unit)? = null, onDrag: (Float) -> Unit) {
    val haptics = LocalHapticFeedback.current
    val chrome = shellChromePalette()
    // A comfortably large touch target (whole strip) wrapping a thin visible grip.
    val strip = if (stacked) {
        Modifier.fillMaxWidth().height(22.dp)
    } else {
        Modifier.fillMaxHeight().width(22.dp)
    }
    Box(
        strip
            .pointerInput(stacked) {
                if (stacked) {
                    detectVerticalDragGestures(
                        onDragStart = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) },
                    ) { _, dy -> onDrag(dy) }
                } else {
                    detectHorizontalDragGestures(
                        onDragStart = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) },
                    ) { _, dx -> onDrag(dx) }
                }
            }
            .pointerInput(Unit) {
                if (onReset != null) detectTapGestures(onDoubleTap = { onReset() })
            },
        contentAlignment = Alignment.Center,
    ) {
        // Visible grip: a short bar oriented across the drag axis.
        Box(
            Modifier
                .then(if (stacked) Modifier.width(40.dp).height(4.dp) else Modifier.height(40.dp).width(4.dp))
                .clip(RoundedCornerShape(2.dp))
                .background(chrome.border),
        )
    }
}

/** Compact per-pane header: focus/server label, focus tap target, and a disconnect action. */
@Composable
private fun MultiSshPaneHeader(viewModel: AppViewModel, paneIndex: Int, session: ShellSession?, isFocused: Boolean) {
    val chrome = shellChromePalette()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val hostLabel = session?.let { s -> servers.find { it.id == s.serverId }?.name ?: s.serverName }
    val label = when {
        session == null -> "Empty pane"
        session.persistent -> "${hostLabel.orEmpty()} · ${displayTmuxSessionName(session.tmuxName)}"
        else -> hostLabel.orEmpty()
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 28.dp)
            .background(if (isFocused) chrome.paneHeaderFocused else chrome.paneHeader)
            .clickable { viewModel.setMultiSshFocus(paneIndex) }
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(
                when {
                    session?.isConnected == true -> OmniColors.green
                    session?.reconnecting == true -> OmniColors.amber
                    session != null -> OmniColors.red
                    else -> Color.Gray
                }
            )
        )
        Spacer(Modifier.width(6.dp))
        Text(
            label,
            color = if (isFocused) chrome.text else chrome.mutedText,
            fontSize = 11.sp,
            fontFamily = OmniFonts.mono,
            fontWeight = if (isFocused) FontWeight.Bold else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        MultiSshPanePicker(viewModel, paneIndex, session, compact = true)
        if (session != null) {
            Spacer(Modifier.width(2.dp))
            Text(
                "BG",
                color = chrome.mutedText,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .clickable {
                        viewModel.sendSessionToBackground(session.id)
                    }
                    .heightIn(min = 28.dp)
                    .wrapContentHeight(Alignment.CenterVertically)
                    .padding(horizontal = 7.dp, vertical = 3.dp)
                    .semantics { contentDescription = "Send $label to background" },
            )
            // Solid chip, not a bare glyph: the close affordance must read on every terminal
            // palette and stay a comfortable tap target.
            Text(
                "✕",
                color = OmniColors.red,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(chrome.dangerBackground)
                    .border(1.dp, OmniColors.red.copy(alpha = 0.5f), RoundedCornerShape(4.dp))
                    .clickable { viewModel.requestDisconnectSession(session.id) }
                    .heightIn(min = 28.dp)
                    .wrapContentHeight(Alignment.CenterVertically)
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .semantics { contentDescription = "Disconnect $label" },
            )
        }
    }
}

/** One compact menu for either assigning a background session or opening a new host in a pane. */
@Composable
private fun MultiSshPanePicker(
    viewModel: AppViewModel,
    paneIndex: Int,
    currentSession: ShellSession?,
    compact: Boolean,
) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val onlineServers = servers.filter { it.status == "online" }
    val otherSessionId = if (paneIndex == 1) viewModel.multiSshSessionId2 else viewModel.multiSshSessionId1
    val selectableSessions = viewModel.activeSessions.filter {
        it.id != otherSessionId && it.id != currentSession?.id
    }
    val resumableSessions = viewModel.restorablePersistentSessions.filter { saved ->
        viewModel.activeSessions.none { it.tmuxName == saved.tmuxName }
    }
    var expanded by remember { mutableStateOf(false) }

    Box {
        if (compact) {
            Text(
                "PICK ▾",
                color = OmniColors.cyan,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .clickable { expanded = true }
                    .heightIn(min = 28.dp)
                    .wrapContentHeight(Alignment.CenterVertically)
                    .padding(horizontal = 6.dp, vertical = 3.dp)
                    .semantics { contentDescription = "Choose a session or host for pane $paneIndex" },
            )
        } else {
            OutlinedButton(onClick = { expanded = true }) {
                Text("Choose session or host", fontSize = 12.sp)
                Spacer(Modifier.width(4.dp))
                Icon(Icons.Filled.ArrowDropDown, contentDescription = null, modifier = Modifier.size(18.dp))
            }
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.widthIn(min = 240.dp, max = 340.dp).heightIn(max = 420.dp),
        ) {
            if (selectableSessions.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("BACKGROUND SESSIONS", fontSize = 10.sp, fontWeight = FontWeight.Bold) },
                    enabled = false,
                    onClick = {},
                )
                selectableSessions.forEach { candidate ->
                    val candidateLabel = servers.find { it.id == candidate.serverId }?.name ?: candidate.serverName
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(candidateLabel, fontFamily = OmniFonts.mono, fontSize = 12.sp)
                                Text(
                                    if (candidate.isConnected) "Connected" else "Disconnected",
                                    fontSize = 10.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        },
                        onClick = {
                            viewModel.assignMultiSshPane(paneIndex, candidate.id)
                            expanded = false
                        },
                    )
                }
            }
            if (resumableSessions.isNotEmpty()) {
                if (selectableSessions.isNotEmpty()) HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("RESUMABLE TMUX", fontSize = 10.sp, fontWeight = FontWeight.Bold) },
                    enabled = false,
                    onClick = {},
                )
                resumableSessions.forEach { saved ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(saved.serverName, fontFamily = OmniFonts.mono, fontSize = 12.sp)
                                Text(displayTmuxSessionName(saved.tmuxName), fontSize = 10.sp, color = OmniColors.amber)
                            }
                        },
                        enabled = !viewModel.isTerminalConnecting,
                        onClick = {
                            currentSession?.let { viewModel.sendSessionToBackground(it.id) }
                            viewModel.setMultiSshFocus(paneIndex)
                            viewModel.resumePersistentSession(saved.tmuxName)
                            expanded = false
                        },
                    )
                }
            }
            if ((selectableSessions.isNotEmpty() || resumableSessions.isNotEmpty()) && onlineServers.isNotEmpty()) HorizontalDivider()
            if (onlineServers.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("NEW SESSION", fontSize = 10.sp, fontWeight = FontWeight.Bold) },
                    enabled = false,
                    onClick = {},
                )
                onlineServers.forEach { server ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(server.name, fontFamily = OmniFonts.mono, fontSize = 12.sp)
                                Text(
                                    "${server.username}@${server.host}",
                                    fontSize = 10.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        },
                        leadingIcon = { StatusDot(true, getServerColor(server), 8.dp) },
                        enabled = !viewModel.isTerminalConnecting,
                        onClick = {
                            currentSession?.let { viewModel.sendSessionToBackground(it.id) }
                            viewModel.setMultiSshFocus(paneIndex)
                            viewModel.selectedServerId = server.id
                            viewModel.connectTerminal()
                            expanded = false
                        },
                    )
                }
            }
            if (selectableSessions.isEmpty() && resumableSessions.isEmpty() && onlineServers.isEmpty()) {
                DropdownMenuItem(text = { Text("No sessions or online hosts") }, enabled = false, onClick = {})
            }
        }
    }
}

/**
 * Empty-pane placeholder. Everything needed to fill the pane lives right here: assign an existing
 * background session, or tap any online host to open a new connection into this pane — no
 * round-trip through the top server dropdown to pick the second host of a split. While a connect
 * targeting this pane is in flight, the pane shows its own progress (the split view stays mounted
 * during connects, so without this the pane would sit silently "empty").
 */
@Composable
private fun MultiSshEmptyPane(viewModel: AppViewModel, paneIndex: Int) {
    val chrome = shellChromePalette()
    if (viewModel.isTerminalConnecting && viewModel.multiSshFocusedPane == paneIndex) {
        Column(
            Modifier.fillMaxSize().padding(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            CircularProgressIndicator(color = OmniColors.cyan, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
            Spacer(Modifier.height(10.dp))
            Text(viewModel.terminalConnectionPhase, color = chrome.mutedText, fontFamily = OmniFonts.mono, fontSize = 12.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = { viewModel.cancelConnect() }) {
                Text("Cancel", color = OmniColors.red, fontSize = 12.sp)
            }
        }
        return
    }
    Column(
        Modifier
            .fillMaxSize()
            .clickable { viewModel.setMultiSshFocus(paneIndex) }
            .padding(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Empty pane", color = chrome.mutedText, fontFamily = OmniFonts.mono, fontSize = 13.sp, fontWeight = FontWeight.Bold)
        // A failed connect into this pane must not vanish with the connecting state — the single
        // view surfaces it on ConnectPrompt; this is the split-view equivalent.
        if (viewModel.multiSshFocusedPane == paneIndex) {
            viewModel.terminalConnectError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = OmniColors.red, fontSize = 11.sp, fontFamily = OmniFonts.mono, textAlign = TextAlign.Center)
            }
        }
        Spacer(Modifier.height(10.dp))
        MultiSshPanePicker(viewModel, paneIndex, currentSession = null, compact = false)
        Spacer(Modifier.height(8.dp))
        Text("The other pane stays connected.", color = chrome.disabledText, fontSize = 10.sp)
    }
}

/**
 * Renders one SSH session as an interactive terminal pane. Used both for the full-screen single
 * session (via [ActiveTerminal]) and for each pane of the MultiSSH split view. All viewport/scroll/
 * resize state is read from and written to [session] specifically (not the global currentSession),
 * so two panes drive their two remotes independently. Keyboard + special-key input still flow
 * through the ViewModel's focused-session routing, so the hidden input field is only mounted when
 * [isFocused] is true — the unfocused pane is display + gesture only, and tapping it calls
 * [onRequestFocus] to hand it the keyboard.
 */
@Composable
private fun PaneTerminal(
    viewModel: AppViewModel,
    session: ShellSession,
    confirm: ConfirmController,
    isFocused: Boolean,
    onRequestFocus: () -> Unit,
) {
    val currentSession = session
    val sessionId = currentSession.id
    val snapshot = currentSession.terminalScreen
    val palette = terminalPalette(viewModel.terminalTheme)
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val linkContext = LocalContext.current
    val linkToolbarColor = MaterialTheme.colorScheme.surface.toArgb()
    val measurer = rememberTextMeasurer()
    var showCopyOptions by remember { mutableStateOf(false) }
    var copyDialogTitle by remember { mutableStateOf<String?>(null) }
    var copyDialogText by remember { mutableStateOf("") }
    var pendingLargePaste by remember { mutableStateOf<String?>(null) }
    val viewport = remember(sessionId) { TerminalViewportState() }
    var visibleRowCount by remember(sessionId) { mutableStateOf(1) }

    // Cursor blink - disabled for performance
    val cursorOn = true

    // Follow the tail only while the user is already near it; scrolling up pauses auto-follow.
    LaunchedEffect(snapshot.totalRows, visibleRowCount) {
        viewport.onContentChanged(snapshot.totalRows, visibleRowCount)
    }

    LaunchedEffect(viewport.firstVisibleRow, visibleRowCount, viewport.followTail) {
        viewModel.updateTerminalViewportFor(currentSession, viewport.firstVisibleRow, visibleRowCount, viewport.followTail)
    }

    // Focus the hidden input immediately so the keyboard is available — but only for the focused
    // pane. In split view the unfocused pane must not grab the keyboard.
    LaunchedEffect(sessionId, isFocused) {
        if (isFocused) {
            focusRequester.requestFocus()
            keyboard?.show()
        }
        // A fresh session starts at its live tail; clear any stale tmux copy-mode scroll flag.
        currentSession.tmuxScrolledBack = false
    }

    // Release the hidden input's focus when the app is backgrounded (e.g. tapping a notification),
    // and re-acquire it on return. Backgrounding tears down the IME text-input session; if the
    // field is still focused when the app resumes and re-positions, Compose's legacy cursor-anchor
    // path (LegacyCursorAnchorInfoController via onGloballyPositioned) dereferences the now-null
    // session and crashes at draw time. Dropping focus on STOP removes that stale session.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, sessionId, isFocused) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> {
                    runCatching { focusRequester.freeFocus() }
                    keyboard?.hide()
                }
                Lifecycle.Event.ON_RESUME -> {
                    if (isFocused) {
                        runCatching { focusRequester.requestFocus() }
                        keyboard?.show()
                    }
                }
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
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
            // Debounced: dragging the split handle (or an IME/layout bounce) re-measures every
            // frame, and each resize is a full scrollback reflow + a remote resize. The effect
            // restarts on every size change, so only the settled size actually lands.
            LaunchedEffect(cols, rows) {
                if (currentSession.termCols != cols || currentSession.termRows != rows) delay(120)
                viewModel.resizeTerminalFor(currentSession, cols, rows)
            }
            LaunchedEffect(rows) { visibleRowCount = rows.coerceAtLeast(1) }
            // The scroll closure outlives any single recomposition, so reading snapshot.totalRows
            // captured at creation time would clamp against a stale row count while output streams in
            // (the screen shifts under the user). rememberUpdatedState keeps these pointing at the
            // latest values without re-creating the scrollable state.
            val latestTotalRows by rememberUpdatedState(snapshot.totalRows)
            val latestVisibleRows by rememberUpdatedState(visibleRowCount)
            val scrolledUp = viewport.scrolledUp
            val historySyncScope = rememberCoroutineScope()
            // Leaving the tail on a tmux session re-syncs local scrollback from the pane's real
            // history: tmux collapses output nobody viewed into a repaint, so rows that were never
            // on this screen are otherwise missing/blank in back-scroll. The returned row delta
            // re-anchors the viewport so the content in view doesn't jump when the swap lands.
            LaunchedEffect(scrolledUp, snapshot.cols, visibleRowCount) {
                if (scrolledUp && currentSession.persistent) {
                    viewport.applyRowDelta(viewModel.resyncTmuxScrollbackFor(currentSession))
                }
            }
            // Scrollable (rather than a raw drag detector) so swipes get standard fling momentum —
            // row-stepping without it made deep scrollback a slog of repeated full-screen drags.
            // The drag/boundary/tail-follow rules live in TerminalViewportState (unit-tested).
            val terminalScrollState = rememberScrollableState { deltaPx ->
                viewport.consumeScroll(deltaPx, cellHeight, latestTotalRows, latestVisibleRows) {
                    viewModel.updateTerminalViewportFor(currentSession, viewport.firstVisibleRow, visibleRowCount, viewport.followTail)
                    // Dirty history can re-arm while we remain scrolled up (new output or a resize),
                    // so every actual user row movement is another safe retry opportunity. The
                    // per-session Mutex coalesces overlapping captures.
                    if (viewport.scrolledUp && currentSession.persistent) {
                        historySyncScope.launch {
                            viewport.applyRowDelta(viewModel.resyncTmuxScrollbackFor(currentSession))
                        }
                    }
                }
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
                    .semantics {
                        contentDescription = "Terminal output: " + snapshot.rows
                            .joinToString("\n") { row -> row.spans.joinToString("") { it.text } }
                            .takeLast(2_000)
                    }
                    .scrollable(state = terminalScrollState, orientation = Orientation.Vertical)
                    .pointerInput(isFocused, cellWidth, cellHeight) {
                        detectTapGestures(
                            onTap = { offset ->
                                // A tap on a URL opens it; anywhere else keeps the old behavior
                                // (summon keyboard / focus the pane). Read the session's snapshot
                                // fresh — this closure outlives the composition it captured.
                                // The logical line is rebuilt across soft-wrapped rows so a URL
                                // that wrapped at the right edge still matches end to end.
                                val snap = currentSession.terminalScreen
                                val rowIdx = (offset.y / cellHeight).toInt()
                                val col = (offset.x / cellWidth).toInt()
                                val url = if (viewModel.terminalLinkDetection) {
                                    logicalLineAt(snap.rows, rowIdx)?.let { (line, colOffset) ->
                                        terminalLinkAt(
                                            line,
                                            colOffset + terminalColumnToTextIndex(snap.rows[rowIdx], col),
                                        )
                                    }
                                } else null
                                if (url != null) {
                                    if (!openLink(linkContext, url, viewModel.linkOpenInApp, linkToolbarColor)) {
                                        android.widget.Toast.makeText(
                                            linkContext, "No app on this device can open links", android.widget.Toast.LENGTH_SHORT
                                        ).show()
                                    }
                                } else if (isFocused) {
                                    focusRequester.requestFocus()
                                    keyboard?.show()
                                } else {
                                    // Tapping an unfocused split pane hands it the keyboard.
                                    onRequestFocus()
                                }
                            },
                            onLongPress = {
                                if (!isFocused) onRequestFocus()
                                showCopyOptions = true
                            }
                        )
                    },
            )

            // Jump-to-bottom control. For local-scroll shells it shows once the user scrolls up off
            // the tail; for tmux (persistent) sessions the scroll drives copy-mode instead of the
            // local viewport, so we track that separately and exit copy-mode on tap.
            if (scrolledUp) {
                val jumpScope = rememberCoroutineScope()
                IconButton(
                    onClick = {
                        // Kill any in-flight fling first — its remaining deltas would otherwise
                        // land after the jump and drag the viewport straight back off the tail.
                        jumpScope.launch {
                            terminalScrollState.stopScroll()
                            val bottom = viewport.jumpToTail(currentSession.terminalScreen.totalRows, visibleRowCount)
                            viewModel.updateTerminalViewportFor(currentSession, bottom, visibleRowCount, followTail = true)
                        }
                    },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(8.dp)
                        .size(44.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.30f))
                        .border(
                            1.dp,
                            MaterialTheme.colorScheme.outline.copy(alpha = 0.45f),
                            RoundedCornerShape(22.dp),
                        ),
                ) {
                    Icon(
                        Icons.Filled.KeyboardDoubleArrowDown,
                        contentDescription = "Jump to bottom",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(22.dp),
                    )
                }
            }

            if (currentSession?.reconnecting == true || currentSession?.disconnectError != null) {
                val reconnecting = currentSession.reconnecting
                val message = if (reconnecting) {
                    if (currentSession.persistent) {
                        "Connection lost. Reconnecting to tmux session…"
                    } else {
                        "Connection lost. Reconnecting…"
                    }
                } else {
                    currentSession.disconnectError ?: "Server disconnected."
                }
                val statusContainer =
                    if (reconnecting) MaterialTheme.colorScheme.tertiaryContainer
                    else MaterialTheme.colorScheme.errorContainer
                val statusContent =
                    if (reconnecting) MaterialTheme.colorScheme.onTertiaryContainer
                    else MaterialTheme.colorScheme.onErrorContainer
                val statusBorder =
                    if (reconnecting) MaterialTheme.colorScheme.tertiary
                    else MaterialTheme.colorScheme.error
                Row(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 10.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(statusContainer)
                        .border(1.dp, statusBorder, RoundedCornerShape(8.dp))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (reconnecting) {
                        CircularProgressIndicator(
                            color = statusBorder,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                    Text(
                        message,
                        color = statusContent,
                        fontSize = 12.sp,
                        fontFamily = OmniFonts.mono,
                    )
                    if (!reconnecting && !currentSession.isConnected) {
                        TextButton(onClick = { viewModel.retrySession(currentSession.id) }) {
                            Text("Retry", color = OmniColors.cyan, fontSize = 11.sp)
                        }
                    }
                }
            }
        }

        // Invisible input sink: captures soft-keyboard text + hardware special keys. Only the
        // focused pane mounts it — in split view the unfocused pane is display + gesture only, so
        // there's a single keyboard target and no ambiguity about which remote receives typing.
        if (isFocused) {
        var inputField by remember(sessionId) { mutableStateOf(TextFieldValue("")) }
        val smartSwipe = viewModel.smartSwipeInput

        // Swipe-typing mode keeps the keyboard's text in the field and mirrors edits to the remote by
        // diffing, exactly like a plain text editor: when the field changes we drop the part that no
        // longer matches (remote BACKSPACEs) and type the new tail. Autocorrect and swipe-revision are
        // just field edits, so they reach the shell correctly. Once a shell-owned key (Enter/Tab/arrows/
        // Ctrl) acts on the line, the shell owns it and our local copy is stale, so we resync to empty.
        val resyncSwipeField = { inputField = TextFieldValue("") }
        DisposableEffect(sessionId, smartSwipe) {
            val ownedCallback = if (smartSwipe) resyncSwipeField else null
            viewModel.pendingSwipeFlush = ownedCallback
            onDispose {
                if (viewModel.pendingSwipeFlush === ownedCallback) viewModel.pendingSwipeFlush = null
            }
        }

        BasicTextField(
            value = inputField,
            onValueChange = { tfv ->
                val newText = tfv.text
                // Detect a genuine clipboard paste, not a long-but-incremental swipe line. A paste
                // drops a big chunk in one change; fast swipe-typing instead grows the field a word
                // (or a re-revised composing region) at a time. Gate on the size of the *inserted
                // delta* over the previous field, not the field's absolute length — otherwise a long
                // command typed by swipe (or a momentary multi-word composing region the IME hands us
                // mid-gesture) was being misread as a paste and popped the confirm dialog.
                val prevText = inputField.text
                // A sticky Ctrl/Alt/Shift modifier (armed from the key bar) transforms the next
                // typed character (control/meta byte, or uppercase). That can't be expressed as an
                // editor-style line diff, so when one is armed we route the freshly-inserted text
                // straight through typeText() — which applies and then clears the modifier — and
                // keep the hidden field empty. This is the only path that honors CTRL/ALT/SHFT for
                // soft-keyboard and swipe input; without it the modifier was silently dropped
                // (issue: Ctrl/Shift had no effect in the mini keyboard).
                if (viewModel.isCtrlPressed || viewModel.isAltPressed || viewModel.isShiftPressed) {
                    if (newText.length > prevText.length) {
                        val p = commonCodePointPrefixIndex(prevText, newText)
                        var end = (p + (newText.length - prevText.length)).coerceAtMost(newText.length)
                        if (end in 1 until newText.length &&
                            Character.isHighSurrogate(newText[end - 1]) && Character.isLowSurrogate(newText[end])
                        ) end++
                        val inserted = newText.substring(p, end)
                        if (inserted.isNotEmpty()) viewModel.typeText(inserted)
                    }
                    inputField = TextFieldValue("")
                    return@BasicTextField
                }
                val insertedDelta = insertedCodePointDelta(prevText, newText)
                if (insertedDelta > 100) {
                    // Large paste: defer to the paste dialog and clear the field.
                    pendingLargePaste = newText
                    inputField = TextFieldValue("")
                    return@BasicTextField
                }
                // Enter committed as text (rare for soft keyboards): submit the line up to it.
                val newline = newText.indexOfFirst { it == '\n' || it == '\r' }
                if (newline >= 0) {
                    val before = newText.substring(0, newline)
                    if (smartSwipe) {
                        diffToRemote(inputField.text, before, viewModel)
                        viewModel.sendKey(TermKey.ENTER)
                        val newlineLength = if (newText[newline] == '\r' &&
                            newline + 1 < newText.length && newText[newline + 1] == '\n'
                        ) 2 else 1
                        val remainder = newText.substring(newline + newlineLength)
                        if (remainder.isNotEmpty()) viewModel.pasteText(remainder)
                    } else {
                        // Preserve the entire clipboard/IME block, including every newline. The old
                        // path submitted only the first line and silently discarded the remainder.
                        viewModel.pasteText(newText)
                    }
                    inputField = TextFieldValue("")
                    return@BasicTextField
                }

                if (smartSwipe) {
                    // Editor-style: send the delta between the old field and the new field.
                    diffToRemote(inputField.text, newText, viewModel)
                    inputField = TextFieldValue(
                        text = newText,
                        selection = androidx.compose.ui.text.TextRange(newText.length),
                    )
                } else {
                    // Stream mode: field stays empty, each commit goes straight through (max fidelity).
                    if (newText.isNotEmpty()) {
                        if (newText.length > 1) {
                            // Stream-mode IME commits are typing, not necessarily clipboard pastes;
                            // never invent a trailing space or wrap them in bracketed-paste markers.
                            viewModel.typeText(newText)
                        } else {
                            viewModel.typeText(newText)
                        }
                    }
                    inputField = TextFieldValue("")
                }
            },
            cursorBrush = SolidColor(Color.Transparent),
            textStyle = TerminalTextStyle.copy(color = Color.Transparent),
            keyboardOptions = KeyboardOptions(
                // A terminal needs literal keystrokes: no autocorrect, no auto-capitalization.
                // Sentence-casing would uppercase the first letter of every command (and after each
                // period), which is wrong for shell input.
                autoCorrectEnabled = false,
                capitalization = KeyboardCapitalization.None,
                // Swipe mode: Ascii keyboard so gesture keyboards offer swipe-typing and suggestions.
                // Stream mode: Password type, which makes IMEs disable swipe/suggestions/autocorrect so
                // every key arrives verbatim (max terminal fidelity).
                keyboardType = if (smartSwipe) KeyboardType.Ascii else KeyboardType.Password,
                imeAction = ImeAction.None,
            ),
            modifier = Modifier
                .align(Alignment.TopStart)
                .size(2.dp)
                .alpha(0.01f)
                .focusRequester(focusRequester)
                .onFocusChanged { focus ->
                    // Tapping away / backgrounding ends the line; drop the local copy so a stale field
                    // can't re-diff against whatever the user does next.
                    if (smartSwipe && !focus.isFocused) inputField = TextFieldValue("")
                }
                .onPreviewKeyEvent { e ->
                    if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    fun physicalKey(key: TermKey): Boolean {
                        viewModel.isCtrlPressed = e.isCtrlPressed
                        viewModel.isAltPressed = e.isAltPressed
                        viewModel.isShiftPressed = e.isShiftPressed
                        viewModel.sendKey(key)
                        return true
                    }
                    // A special key acts on the real shell line. In swipe mode our field copy is now
                    // stale (the shell will redraw the line), so resync it to empty after the key.
                    val handled = when (e.key) {
                        Key.Backspace -> physicalKey(TermKey.BACKSPACE)
                        Key.Enter, Key.NumPadEnter -> physicalKey(TermKey.ENTER)
                        Key.Tab -> physicalKey(TermKey.TAB)
                        Key.Escape -> physicalKey(TermKey.ESC)
                        Key.DirectionUp -> physicalKey(TermKey.UP)
                        Key.DirectionDown -> physicalKey(TermKey.DOWN)
                        Key.DirectionLeft -> physicalKey(TermKey.LEFT)
                        Key.DirectionRight -> physicalKey(TermKey.RIGHT)
                        Key.MoveHome -> physicalKey(TermKey.HOME)
                        Key.MoveEnd -> physicalKey(TermKey.END)
                        Key.Insert -> physicalKey(TermKey.INSERT)
                        Key.Delete -> physicalKey(TermKey.DELETE)
                        Key.PageUp -> physicalKey(TermKey.PAGE_UP)
                        Key.PageDown -> physicalKey(TermKey.PAGE_DOWN)
                        Key.F1 -> physicalKey(TermKey.F1)
                        Key.F2 -> physicalKey(TermKey.F2)
                        Key.F3 -> physicalKey(TermKey.F3)
                        Key.F4 -> physicalKey(TermKey.F4)
                        Key.F5 -> physicalKey(TermKey.F5)
                        Key.F6 -> physicalKey(TermKey.F6)
                        Key.F7 -> physicalKey(TermKey.F7)
                        Key.F8 -> physicalKey(TermKey.F8)
                        Key.F9 -> physicalKey(TermKey.F9)
                        Key.F10 -> physicalKey(TermKey.F10)
                        Key.F11 -> physicalKey(TermKey.F11)
                        Key.F12 -> physicalKey(TermKey.F12)
                        else -> {
                            // Android's text field handles unmodified printable keys. Ctrl/Alt
                            // combinations often never reach onValueChange, so translate them here.
                            // Android reports AltGr as Ctrl+Alt. Leave that combination to the
                            // text input path so international layouts are not intercepted.
                            val isAltGr = e.isCtrlPressed && e.isAltPressed
                            if ((e.isCtrlPressed || e.isAltPressed) && !isAltGr) {
                                val unicode = e.utf16CodePoint
                                if (unicode > 0 && !Character.isISOControl(unicode)) {
                                    viewModel.isCtrlPressed = e.isCtrlPressed
                                    viewModel.isAltPressed = e.isAltPressed
                                    viewModel.isShiftPressed = e.isShiftPressed
                                    viewModel.typeText(String(Character.toChars(unicode)))
                                    true
                                } else false
                            } else false
                        }
                    }
                    // sendKey() already triggers pendingSwipeFlush (resync); this covers the few keys
                    // above that we handle without going through sendKey — none today, but keep it safe.
                    handled
                },
        )
        } // end if (isFocused) — hidden input sink

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
                Box(
                    Modifier
                        .fillMaxSize()
                        // The full-screen scrim Box was swallowing outside taps, so the dialog never
                        // dismissed on click-outside. Make the scrim itself dismiss (no ripple), and
                        // let the Surface below consume taps so taps on the card don't bubble up.
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { showCopyOptions = false }
                        .padding(18.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 360.dp)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { /* swallow taps on the card so the scrim doesn't dismiss it */ },
                        shape = RoundedCornerShape(8.dp),
                        tonalElevation = 6.dp,
                    ) {
                        Column(
                            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            // ── Session-scoped quick toggles (runtime only, not saved to settings) ──
                            // Rendered as Switch rows: the switch shows current state at a glance, and
                            // flipping it acts immediately. Unlike the copy actions, these stay on the
                            // menu after toggling so the user can adjust both without re-opening it.
                            Text("This session", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            TerminalToggleRow(
                                title = "Swipe-typing",
                                subtitle = if (viewModel.smartSwipeInput) "On — text streams as you swipe/autocorrect"
                                    else "Off — each keystroke is sent immediately",
                                checked = viewModel.smartSwipeInput,
                                onCheckedChange = { viewModel.toggleSmartSwipeRuntime() },
                            )
                            TerminalToggleRow(
                                title = "Keep screen on",
                                subtitle = if (viewModel.isKeepScreenOnEnabled) "On — screen stays awake in this session"
                                    else "Off — screen may sleep normally",
                                checked = viewModel.isKeepScreenOnEnabled,
                                // Toggle directly: the long-press menu is already an explicit opt-in, so
                                // skip the battery-warning follow-up dialog.
                                onCheckedChange = { viewModel.toggleKeepScreenOnDirect() },
                            )
                            HorizontalDivider()
                            Text("Copy terminal text", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            Text("Choose the terminal text range to copy.", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Button(
                                onClick = {
                                    val start = viewport.firstVisibleRow.coerceIn(0, snapshot.totalRows)
                                    openSelectableText("Visible screen", viewModel.terminalBufferTextFor(currentSession, full = false, firstRow = start, rowCount = visibleRowCount))
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("Visible screen")
                            }
                            OutlinedButton(
                                onClick = {
                                    openSelectableText("Full buffer", viewModel.terminalBufferTextFor(currentSession, full = true))
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
                                        viewModel.clearTerminalScrollbackFor(currentSession)
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
            val context = LocalContext.current
            fun dismiss() {
                copyDialogTitle = null
                copyDialogText = ""
                focusRequester.requestFocus()
                keyboard?.show()
            }
            Dialog(
                onDismissRequest = { dismiss() },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                // A roomy but not edge-to-edge sheet: lines WRAP (no horizontal scrolling), the font
                // is compact, and a one-tap "Copy all" handles the common case so you rarely need to
                // hand-select. Drag-select still works for grabbing just part of the output.
                Surface(
                    modifier = Modifier
                        .fillMaxWidth(0.96f)
                        .fillMaxHeight(0.82f),
                    shape = RoundedCornerShape(12.dp),
                    tonalElevation = 6.dp,
                ) {
                    Column(Modifier.fillMaxSize().padding(horizontal = 14.dp, vertical = 12.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(title, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f))
                            Text("Drag to select, or Copy all", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Spacer(Modifier.height(8.dp))
                        val textColor = MaterialTheme.colorScheme.onSurface.toArgb()
                        // Must be a theme surface, not a fixed dark token: with the light or
                        // high-contrast-light app theme, onSurface is near-black and a fixed
                        // OmniColors.bg2 pane rendered the copy text black-on-black.
                        val backgroundColor = MaterialTheme.colorScheme.surfaceContainerHigh.toArgb()
                        // Wrapping, selectable monospace text in a vertical scroller. No horizontal
                        // scroll: long lines wrap to the dialog width, so selection is a clean vertical
                        // drag — much easier than chasing text off the right edge.
                        AndroidView(
                            factory = { ctx ->
                                android.widget.ScrollView(ctx).apply {
                                    isVerticalScrollBarEnabled = true
                                    isFillViewport = true
                                    val textView = android.widget.TextView(ctx).apply {
                                        tag = "terminal_copy_text"
                                        typeface = android.graphics.Typeface.MONOSPACE
                                        textSize = 11f
                                        setLineSpacing(0f, 1.05f)
                                        setTextColor(textColor)
                                        setBackgroundColor(backgroundColor)
                                        setPadding(20, 16, 20, 16)
                                        setTextIsSelectable(true)
                                        isFocusable = true
                                        isFocusableInTouchMode = true
                                        setHorizontallyScrolling(false) // wrap long lines
                                    }
                                    addView(
                                        textView,
                                        android.view.ViewGroup.LayoutParams(
                                            android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                                        ),
                                    )
                                }
                            },
                            update = { scroll ->
                                val tv = scroll.getChildAt(0) as android.widget.TextView
                                tv.setTextColor(textColor)
                                tv.setBackgroundColor(backgroundColor)
                                val nextText = copyDialogText.ifBlank { "No terminal text in this range." }
                                if (tv.text.toString() != nextText) tv.text = nextText
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                        Spacer(Modifier.height(10.dp))
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { dismiss() }, modifier = Modifier.weight(1f)) {
                                Text("Close")
                            }
                            Button(
                                onClick = {
                                    val cm = context.getSystemService(android.content.ClipboardManager::class.java)
                                    cm?.setPrimaryClip(
                                        android.content.ClipData.newPlainText("Terminal", copyDialogText)
                                    )
                                    // Android 13+ shows its own copy confirmation; toast covers older.
                                    android.widget.Toast.makeText(context, "Copied to clipboard", android.widget.Toast.LENGTH_SHORT).show()
                                    dismiss()
                                },
                                enabled = copyDialogText.isNotBlank(),
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Filled.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Copy all")
                            }
                        }
                    }
                }
            }
        }
    }
}

// A labelled Switch row for the terminal long-press menu's session toggles. The whole row is
// clickable (not just the switch) so it's an easy touch target on the terminal.
@Composable
private fun TerminalToggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
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
    val ansiFg = palette.ansiFgOverride
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
                    // Cell background: theme background for the default, theme foreground for an
                    // inverse-of-default block, raw colour otherwise. (DEFAULT_FG can't collide with
                    // a palette value — 0xFFC8D4E8 is not in the xterm 256 table.)
                    val effectiveBg = when (bgInt) {
                        TerminalEmulator.DEFAULT_BG -> backgroundArgb
                        TerminalEmulator.DEFAULT_FG -> foregroundArgb
                        else -> bgInt
                    }
                    val resolvedFg = when {
                        fgInt == TerminalEmulator.DEFAULT_FG -> foregroundArgb
                        ansiFg != null -> ansi16Index(fgInt).let { if (it >= 0) ansiFg[it] else fgInt }
                        else -> fgInt
                    }
                    // Dim pre-composites 60% toward the cell background (instead of paint alpha, so
                    // the legibility guard sees the colour actually shown). Every foreground then
                    // passes the guard: remote apps assume their own background colour, and e.g.
                    // 256-cube greys picked for a dark terminal are unreadable on the light theme.
                    val dimmedFg = if (span.dim) lerpArgb(effectiveBg, resolvedFg, 0.6f) else resolvedFg
                    paint.color = ensureLegibleOnBackground(dimmedFg, effectiveBg)
                    // SGR text attributes: italic via glyph skew (no italic monospace variant is
                    // guaranteed on-device), underline natively.
                    paint.textSkewX = if (span.italic) -0.25f else 0f
                    paint.isUnderlineText = span.underline
                    paint.alpha = 255
                    val x = col * cellWidthPx
                    val glyphs = if (span.glyphs.isNotEmpty()) span.glyphs else
                        span.text.codePoints().toArray().map { String(Character.toChars(it)) }
                    val glyphWidths = if (span.glyphWidths.size == glyphs.size) span.glyphWidths else
                        List(glyphs.size) { 1 }
                    val widthCells = glyphWidths.sum()
                    val width = widthCells * cellWidthPx
                    if (bgInt != TerminalEmulator.DEFAULT_BG || span.inverse) {
                        bgPaint.color = effectiveBg
                        native.drawRect(x, yTop, x + width, yTop + cellHeightPx, bgPaint)
                    }
                    // Draw each glyph pinned to its own grid cell. Drawing a whole span in one
                    // drawText() call lets the font advance glyphs by their intrinsic (subpixel)
                    // widths, which drifts away from the fixed cellWidthPx grid and makes characters
                    // look bunched up or spread out. Centering each char in its cell keeps the
                    // terminal perfectly monospaced regardless of the font's actual advances.
                    val baselineY = yTop + baselineOffset
                    for (i in glyphs.indices) {
                        val glyphWidth = glyphWidths[i].coerceIn(1, 2)
                        val cellCenterX = col * cellWidthPx + (glyphWidth * cellWidthPx) / 2f
                        native.drawText(glyphs[i], cellCenterX, baselineY, paint)
                        col += glyphWidth
                    }
                }
                if (cursorOn && snapshot.cursorVisible && absoluteRow == snapshot.cursorRow) {
                    val cursorX = snapshot.cursorCol * cellWidthPx
                    native.drawRect(cursorX, yTop, cursorX + cellWidthPx, yTop + cellHeightPx, cursorPaint)
                    val glyph = rowGlyphAt(row, snapshot.cursorCol)
                    if (glyph != null) {
                        // Reset attributes the span loop may have left on the shared paint. The
                        // glyph must stay readable on the cursor block whatever the theme pairing.
                        regularPaint.textSkewX = 0f
                        regularPaint.isUnderlineText = false
                        regularPaint.color = ensureLegibleOnBackground(backgroundArgb, cursorArgb)
                        // Clip to the cursor cell, but retain the glyph's original two-cell origin.
                        // Re-centering a wide glyph in the continuation cell shifts it and paints
                        // over neighbours.
                        native.save()
                        native.clipRect(cursorX, yTop, cursorX + cellWidthPx, yTop + cellHeightPx)
                        val glyphCenter = glyph.startColumn * cellWidthPx +
                            glyph.width * cellWidthPx / 2f
                        native.drawText(glyph.text, glyphCenter, yTop + baselineOffset, regularPaint)
                        native.restore()
                    }
                }
            }
        }
    }
}

/**
 * Mirror an editor-style field edit to the remote shell: keep the shared prefix, BACKSPACE away the
 * rest of the old text, then type the new tail. This makes the hidden field behave like a normal text
 * line — swipe revision, autocorrect, and in-field backspace all reduce to "old → new" and reach the
 * shell as the right sequence of deletes + inserts.
 */
private fun diffToRemote(old: String, new: String, viewModel: AppViewModel) {
    if (old == new) return
    val prefix = commonCodePointPrefixIndex(old, new)
    viewModel.applyLineEdit(
        backspaces = old.codePointCount(prefix, old.length),
        insert = new.substring(prefix),
    )
}

private fun commonCodePointPrefixIndex(first: String, second: String): Int {
    var firstIndex = 0
    var secondIndex = 0
    while (firstIndex < first.length && secondIndex < second.length) {
        val firstCodePoint = first.codePointAt(firstIndex)
        val secondCodePoint = second.codePointAt(secondIndex)
        if (firstCodePoint != secondCodePoint) break
        firstIndex += Character.charCount(firstCodePoint)
        secondIndex += Character.charCount(secondCodePoint)
    }
    return firstIndex // equal code points always consume the same UTF-16 width
}

/**
 * Number of Unicode scalar values [new] shares with [old] at the start and end combined (clamped so
 * the two matched regions never overlap). Subtracting this from [new]'s code-point count gives the
 * changed middle size used to distinguish a paste from an incremental swipe edit.
 */
private fun longestCommonAffix(old: String, new: String): Int {
    val oldPoints = old.codePoints().toArray()
    val newPoints = new.codePoints().toArray()
    val max = minOf(oldPoints.size, newPoints.size)
    var prefix = 0
    while (prefix < max && oldPoints[prefix] == newPoints[prefix]) prefix++
    var suffix = 0
    while (suffix < max - prefix &&
        oldPoints[oldPoints.lastIndex - suffix] == newPoints[newPoints.lastIndex - suffix]
    ) suffix++
    return prefix + suffix
}

/** Number of newly inserted Unicode scalar values, independent of UTF-16 surrogate width. */
internal fun insertedCodePointDelta(old: String, new: String): Int =
    (new.codePointCount(0, new.length) - longestCommonAffix(old, new)).coerceAtLeast(0)

private data class CursorGlyph(val text: String, val startColumn: Int, val width: Int)

private fun rowGlyphAt(row: TermRow, targetCol: Int): CursorGlyph? {
    if (targetCol < 0) return null
    var col = 0
    for (span in row.spans) {
        val glyphs = if (span.glyphs.isNotEmpty()) span.glyphs else
            span.text.codePoints().toArray().map { String(Character.toChars(it)) }
        val widths = if (span.glyphWidths.size == glyphs.size) span.glyphWidths else List(glyphs.size) { 1 }
        for (index in glyphs.indices) {
            val next = col + widths[index].coerceIn(1, 2)
            if (targetCol in col until next) return CursorGlyph(glyphs[index], col, next - col)
            col = next
        }
    }
    return CursorGlyph(" ", targetCol, 1)
}

@Composable
private fun TerminalKeyBar(viewModel: AppViewModel) {
    val chrome = shellChromePalette()
    var showSymbols by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .background(chrome.keyBackground)
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
                KeyCap("TAB", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.TAB) }
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
                KeyCap("HOME", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.HOME) }
                KeyCap("←", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.LEFT) }
                KeyCap("↓", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.DOWN) }
                KeyCap("→", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.RIGHT) }
                KeyCap("END", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.END) }
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
                KeyCap("PGUP", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.PAGE_UP) }
                KeyCap("PGDN", Modifier.weight(1f), repeatable = true) { viewModel.sendKey(TermKey.PAGE_DOWN) }
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
    val chrome = shellChromePalette()
    val haptics = LocalHapticFeedback.current
    val currentOnClick by rememberUpdatedState(onClick)
    val scope = rememberCoroutineScope()
    Box(
        modifier = modifier
            .padding(horizontal = 2.dp)
            .height(34.dp)
            .background(if (active) activeColor else chrome.keyCap, RoundedCornerShape(5.dp))
            .border(1.dp, if (active) activeColor else chrome.border, RoundedCornerShape(5.dp))
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
            color = if (active) Color.Black else chrome.keyText,
            fontSize = fs,
            fontWeight = FontWeight.Bold,
            fontFamily = OmniFonts.mono,
            maxLines = 1,
        )
    }
}

// ── Terminal hyperlink detection ──
// Matched on tap only (never per draw frame): the tapped row's text is assembled from its spans
// and scanned for a URL covering the tapped column. Kept top-level for unit testing.
private val TERMINAL_URL_REGEX = Regex("""(?:https?://|www\.)[^\s'"<>()\[\]{}]+""")

/**
 * The URL under column [col] of a terminal [lineText], or null. Trailing punctuation that shells
 * and prose commonly glue onto a URL (`.` `,` `;` `:` `!` `?`) is trimmed; bare `www.` hosts get
 * an https scheme so they open. Column bounds use the untrimmed match so a tap on trimmed
 * punctuation still counts as "outside".
 */
internal fun terminalLinkAt(lineText: String, col: Int): String? {
    for (m in TERMINAL_URL_REGEX.findAll(lineText)) {
        if (col in m.range) {
            val url = m.value.trimEnd('.', ',', ';', ':', '!', '?')
            if (col >= m.range.first + url.length) return null
            return if (url.startsWith("www.")) "https://$url" else url
        }
    }
    return null
}
