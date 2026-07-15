package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.ExperimentalMaterialApi
import androidx.compose.material.pullrefresh.PullRefreshIndicator
import androidx.compose.material.pullrefresh.pullRefresh
import androidx.compose.material.pullrefresh.rememberPullRefreshState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.appcompat.app.AppCompatActivity
import android.content.Context
import android.content.ContextWrapper
import android.content.res.Configuration
import com.jetsetslow.omniterm.billing.LicenseController
import com.jetsetslow.omniterm.billing.LicenseState

import com.jetsetslow.omniterm.billing.createLicenseController
import com.jetsetslow.omniterm.data.BiometricCryptoGate
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

fun Context.getActivity(): AppCompatActivity? = when (this) {
    is AppCompatActivity -> this
    is ContextWrapper -> baseContext.getActivity()
    else -> null
}

// User-defined accent colour for a server (falls back to a per-name colour for "Default").
fun getServerColor(server: ServerEntity): Color =
    OmniColors.serverAccent(server.serverColor, server.name)

/**
 * Reusable host picker (mirrors the Monitor screen's selector) so SFTP, Containers, etc. all
 * let the user choose which server they're acting on. [onServerChange] fires after the selection
 * changes so callers can reload their data.
 */
@Composable
fun ServerSelectorBar(
    viewModel: AppViewModel,
    overrideServer: ServerEntity? = null,
    onlineOnly: Boolean = false,
    onServerChange: () -> Unit = {},
    allowSplitSelection: Boolean = false,
    onOpenSplit: (List<Int>) -> Unit = {},
    leadingContent: (@Composable RowScope.() -> Unit)? = null,
    trailingContent: (@Composable RowScope.() -> Unit)? = null,
    // Rendered on its own row under the host info so action chips never squeeze out the
    // name/user@host/latency text (used by the terminal's SPLIT/OPEN/BG/DISC actions).
    secondRowContent: (@Composable RowScope.() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val selectableServers = if (onlineOnly) servers.filter { it.status == "online" } else servers
    val srv = overrideServer
        ?: selectableServers.find { it.id == viewModel.selectedServerId }
        ?: selectableServers.firstOrNull()
    if (srv == null) {
        Text(
            if (onlineOnly) "No online hosts available right now." else "No server selected — add or pick one on the Hosts tab.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(16.dp),
        )
        return
    }
    var expanded by remember { mutableStateOf(false) }
    val splitSelection = remember { mutableStateListOf<Int>() }
    LaunchedEffect(selectableServers.map { it.id }) {
        splitSelection.removeAll { selectedId -> selectableServers.none { it.id == selectedId } }
    }
    val accent = getServerColor(srv)
    val latency = if (srv.status == "online") "${srv.lastLatency}ms" else "offline"
    // Anchor width, so the dropdown spans the full bar instead of wrapping its widest row.
    val density = LocalDensity.current
    var anchorWidth by remember { mutableStateOf(0.dp) }
    fun toggleSplitServer(serverId: Int) {
        if (serverId in splitSelection) {
            splitSelection.remove(serverId)
        } else if (splitSelection.size < 2) {
            splitSelection.add(serverId)
        }
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp)
            .onGloballyPositioned { anchorWidth = with(density) { it.size.width.toDp() } },
    ) {
        Column {
            // Outlined, chevroned control so it clearly reads as a host picker; all info on one line.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp))
                    .clickable {
                        if (allowSplitSelection && splitSelection.isEmpty()) {
                            listOfNotNull(viewModel.multiSshSession1, viewModel.multiSshSession2)
                                .map { it.serverId }
                                .distinct()
                                .take(2)
                                .forEach(splitSelection::add)
                            if (splitSelection.isEmpty()) splitSelection.add(srv.id)
                        }
                        expanded = true
                    }
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (leadingContent != null) {
                    leadingContent()
                }
                StatusDot(online = srv.status == "online", color = accent, size = 8.dp)
                Text(srv.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Text(
                    "${srv.username}@${srv.host} · $latency",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (trailingContent != null) {
                    trailingContent()
                } else {
                    Text("Host", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = accent, letterSpacing = 1.sp)
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = "Switch host", tint = accent)
                }
            }
            if (secondRowContent != null) {
                // Action chips span the full bar width (each weights itself) — no dead space.
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    secondRowContent()
                }
            }
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = if (anchorWidth > 0.dp) Modifier.width(anchorWidth) else Modifier,
        ) {
            selectableServers.forEach { s ->
                val checkedForSplit = s.id in splitSelection
                DropdownMenuItem(
                    text = { Text("${s.name} — ${s.username}@${s.host}", fontFamily = OmniFonts.mono) },
                    leadingIcon = { StatusDot(online = s.status == "online", color = getServerColor(s), size = 8.dp) },
                    trailingIcon = if (allowSplitSelection) {
                        {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (checkedForSplit) {
                                    Text(
                                        "P${splitSelection.indexOf(s.id) + 1}",
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                                Checkbox(
                                    checked = checkedForSplit,
                                    enabled = checkedForSplit || splitSelection.size < 2,
                                    onCheckedChange = { toggleSplitServer(s.id) },
                                    modifier = Modifier.semantics {
                                        contentDescription = if (checkedForSplit) {
                                            "Remove ${s.name} from pane ${splitSelection.indexOf(s.id) + 1}"
                                        } else {
                                            "Add ${s.name} to split panes"
                                        }
                                    },
                                )
                            }
                        }
                    } else null,
                    onClick = {
                        if (allowSplitSelection) {
                            toggleSplitServer(s.id)
                        } else {
                            expanded = false
                            if (s.id != viewModel.selectedServerId) {
                                viewModel.selectedServerId = s.id
                                onServerChange()
                            }
                        }
                    },
                )
            }
            if (allowSplitSelection) {
                HorizontalDivider()
                DropdownMenuItem(
                    text = {
                        Text(
                            if (splitSelection.size == 2) "Load selected hosts into panes" else "Select two hosts for the panes",
                            fontWeight = FontWeight.Bold,
                        )
                    },
                    leadingIcon = { Icon(Icons.Filled.VerticalSplit, contentDescription = null) },
                    trailingIcon = { Text("${splitSelection.size}/2", fontFamily = OmniFonts.mono) },
                    enabled = splitSelection.size == 2,
                    onClick = {
                        val selected = splitSelection.toList()
                        expanded = false
                        onOpenSplit(selected)
                    },
                )
            }
        }
    }
}

/**
 * Global live-output panel for any button-triggered remote action (service/container/process/script).
 * Mounted once at the scaffold level so it overlays whichever tab launched the action.
 */
@Composable
fun ActionStreamDialog(viewModel: AppViewModel) {
    if (!viewModel.actionStreamRunning && viewModel.actionStreamOutput.isBlank()) return
    val copyToClipboard = rememberClipboardCopy()
    AlertDialog(
        onDismissRequest = {
            // While still streaming, ignore back/outside-tap so ongoing output isn't lost.
            if (!viewModel.actionStreamRunning) viewModel.closeActionStream()
        },
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (viewModel.actionStreamRunning) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                }
                Text(viewModel.actionStreamTitle.ifBlank { "Output" }, fontFamily = OmniFonts.mono, fontSize = 14.sp)
            }
        },
        text = {
            val outScroll = rememberScrollState()
            LaunchedEffect(viewModel.actionStreamOutput) { outScroll.scrollTo(outScroll.maxValue) }
            Box(
                Modifier.fillMaxWidth().height(300.dp).background(Color.Black)
                    .verticalScroll(outScroll).padding(8.dp)
            ) {
                if (viewModel.actionStreamRunning && viewModel.actionStreamOutput.isBlank()) {
                    Text("Running…", fontFamily = OmniFonts.mono, fontSize = 11.sp, color = Color.Gray)
                } else {
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        Text(viewModel.actionStreamOutput, fontFamily = OmniFonts.mono, fontSize = 11.sp, color = Color.White)
                    }
                }
            }
        },
        dismissButton = {
            TextButton(
                enabled = viewModel.actionStreamOutput.isNotBlank(),
                onClick = {
                    copyToClipboard(viewModel.actionStreamOutput)
                },
            ) {
                Icon(Icons.Filled.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Copy")
            }
        },
        confirmButton = {
            TextButton(onClick = { viewModel.closeActionStream() }) {
                Text(if (viewModel.actionStreamRunning) "Cancel" else "Close")
            }
        },
    )
}

/**
 * Explains a host's current health score: which metrics deducted points (with the tier and
 * threshold each crossed) per the configured scoring rules. Shared by the Servers/Monitor rings.
 */
@Composable
fun HealthBreakdownDialog(viewModel: AppViewModel, server: ServerEntity, onDismiss: () -> Unit) {
    val breakdown = viewModel.healthBreakdown(server)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Health score · ${server.name}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Score: ${breakdown.score} / 100", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                HorizontalDivider()
                when {
                    breakdown.offline ->
                        Text("Host is offline or unreachable — score is forced to 0.", color = Color.Red, fontSize = 14.sp)
                    breakdown.healthy ->
                        Text("All metrics within healthy thresholds. No deductions (start 100).", color = OmniColors.green, fontSize = 14.sp)
                    else -> {
                        Text("Starting from 100, the following deductions apply:", fontSize = 14.sp)
                        breakdown.factors.forEach { f ->
                            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(f.label, fontSize = 14.sp, modifier = Modifier.weight(1f))
                                Text("-${f.penalty}", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = OmniColors.red)
                            }
                        }
                    }
                }
                HorizontalDivider()
                Text("Thresholds and weights are editable in Tools → Settings → Health scoring.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

/** A queued destructive-action confirmation. */
data class ConfirmRequest(
    val title: String,
    val message: String,
    val confirmLabel: String,
    val destructive: Boolean,
    val onConfirm: () -> Unit,
)

/** Holds the pending confirmation for a screen; `ask` queues one, `ConfirmHost` renders it. */
class ConfirmController {
    var pending by mutableStateOf<ConfirmRequest?>(null)
        private set

    fun ask(
        title: String,
        message: String,
        confirmLabel: String = "Confirm",
        destructive: Boolean = true,
        onConfirm: () -> Unit,
    ) {
        pending = ConfirmRequest(title, message, confirmLabel, destructive, onConfirm)
    }

    fun dismiss() {
        pending = null
    }
}

@Composable
fun rememberConfirm(): ConfirmController = remember { ConfirmController() }

/** Renders the queued confirmation dialog (if any). Place once per screen. */
@Composable
fun ConfirmHost(controller: ConfirmController) {
    val req = controller.pending ?: return
    AlertDialog(
        onDismissRequest = { controller.dismiss() },
        title = { Text(req.title) },
        text = { Text(req.message) },
        confirmButton = {
            TextButton(onClick = {
                controller.dismiss()
                req.onConfirm()
            }) {
                Text(req.confirmLabel, color = if (req.destructive) OmniColors.red else MaterialTheme.colorScheme.primary)
            }
        },
        dismissButton = { TextButton(onClick = { controller.dismiss() }) { Text("Cancel") } },
    )
}

/**
 * Confirmation gate for a privileged (sudo) action that has been staged in
 * `viewModel.pendingSudoAction`. Presents biometrics (if enabled) and/or a PIN field, then runs
 * or cancels the staged action. Only shown when an action is actually pending.
 */
@Composable
fun SudoAuthDialog(viewModel: AppViewModel) {
    if (viewModel.pendingSudoAction == null) return
    val context = LocalContext.current
    var pin by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        if (viewModel.useBiometrics) {
            context.getActivity()?.let { activity ->
                BiometricCryptoGate.authenticate(
                    activity = activity,
                    title = "Authenticate for sudo",
                    subtitle = "Confirm to run the privileged action",
                    onAuthenticated = { viewModel.confirmPendingSudoAction() },
                )
            }
        }
    }

    AlertDialog(
        onDismissRequest = { viewModel.cancelPendingSudoAction() },
        title = { Text("Authenticate for sudo") },
        text = {
            Column {
                Text("Confirm to run this privileged action with the stored sudo password.", fontSize = 14.sp)
                if (viewModel.savedPin != null) {
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = pin,
                        onValueChange = { pin = it; error = null },
                        label = { Text("PIN") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    error?.let { Text(it, color = OmniColors.red, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
                } else {
                    Spacer(Modifier.height(8.dp))
                    Text("Use your biometric prompt to continue.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            if (viewModel.savedPin != null) {
                TextButton(onClick = {
                    val err = viewModel.verifyPinForSensitiveAction(pin)
                    if (err == null) viewModel.confirmPendingSudoAction() else error = err
                }) { Text("Confirm") }
            }
        },
        dismissButton = { TextButton(onClick = { viewModel.cancelPendingSudoAction() }) { Text("Cancel") } },
    )
}

@Composable
fun MainAppScreen(viewModel: AppViewModel) {
    val context = LocalContext.current
    var backPressDisabledTime by remember { mutableStateOf(0L) }
    var showExitDialog by remember { mutableStateOf(false) }
    val fullScreenEditorHost = remember { FullScreenEditorHost() }

    BackHandler(
        enabled = fullScreenEditorHost.content == null &&
            viewModel.edittingSftpFile == null && viewModel.edittingShareFile == null,
    ) {
        if (!viewModel.navigateBack()) {
            val currentTime = System.currentTimeMillis()
            if (currentTime - backPressDisabledTime < 2000) {
                if (viewModel.activeSessions.any { it.isConnected }) {
                    showExitDialog = true
                } else {
                    context.getActivity()?.finish()
                }
            } else {
                backPressDisabledTime = currentTime
                android.widget.Toast.makeText(context, "Press back again to exit", android.widget.Toast.LENGTH_SHORT).show()
            }
        }
    }

    if (showExitDialog) {
        AlertDialog(
            onDismissRequest = { showExitDialog = false },
            title = { Text("Exit OmniTerm?") },
            text = { Text("Exiting will terminate all active background SSH sessions.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.closeAllSessions()
                        showExitDialog = false
                        context.getActivity()?.finish()
                    }
                ) {
                    Text("Terminate & Exit", color = Color.Red)
                }
            },
            dismissButton = {
                TextButton(onClick = { showExitDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    if (viewModel.isAppLocked && viewModel.isAppLockEnabled) {
        PinLockGateway(viewModel)
    } else {
        CompositionLocalProvider(LocalFullScreenEditorHost provides fullScreenEditorHost) {
            AppCoreScaffold(viewModel)
        }

        // Global first-connect host key approval: must overlay every screen AND every dialog
        // (Add Server's Test Connection blocks on it), so it lives here, not in ShellScreen.
        HostKeyApprovalDialog(viewModel)

        // First-connect tmux install prompt for persistent-session hosts.
        TmuxInstallDialog(viewModel)

        // Warn (but allow) when connecting to a host whose last probe found it offline. Hosted here
        // so it overlays both the terminal screen and the server-list connect action.
        OfflineConnectDialog(viewModel)

        // Full-screen SFTP text editor, hosted here at the top of the Activity window rather than
        // inside SftpScreen. SftpScreen lives under AppCoreScaffold's content Box, which calls
        // consumeWindowInsets() — so any editor placed there sees a zero IME inset and its bottom
        // action bar slides under the keyboard. Hosting it here (above that Scaffold, in the raw
        // Activity window with real WindowInsets.ime) is what actually keeps the Save/Discard bar
        // pinned above the soft keyboard. This replaces the old Compose Dialog, whose separate
        // window had unreliable IME insets across devices.
        viewModel.edittingSftpFile?.let { editingFile ->
            val editorConfirm = rememberConfirm()
            SftpFileEditor(
                file = editingFile,
                saving = viewModel.sftpSaving,
                error = viewModel.sftpError,
                sudo = viewModel.sftpSudo,
                onToggleSudo = { viewModel.toggleSftpSudo() },
                onSave = { buffer ->
                    viewModel.sftpSaveText(editingFile, buffer) {
                        // Only dismiss once the save is verified persisted on the remote.
                        viewModel.edittingSftpFile = null
                        viewModel.edittingSftpFilePath = ""
                    }
                },
                onDismiss = {
                    viewModel.edittingSftpFile = null
                    viewModel.edittingSftpFilePath = ""
                },
                confirm = editorConfirm,
                highlightLimit = viewModel.editorHighlightLimit,
            )
            ConfirmHost(editorConfirm)
        }

        // Full-screen editor for a network-share text file — same host rationale as the SFTP editor
        // above (must sit over the Scaffold so its action bar clears the keyboard). Shares can't
        // elevate, so there's no sudo toggle.
        viewModel.edittingShareFile?.let { editingFile ->
            val shareEditorConfirm = rememberConfirm()
            SftpFileEditor(
                file = editingFile,
                saving = viewModel.shareSaving,
                error = viewModel.shareError,
                sudo = false,
                onToggleSudo = {},
                onSave = { buffer ->
                    viewModel.shareSaveText(editingFile, buffer) { viewModel.edittingShareFile = null }
                },
                onDismiss = { viewModel.edittingShareFile = null },
                confirm = shareEditorConfirm,
                highlightLimit = viewModel.editorHighlightLimit,
                showSudo = false,
            )
            ConfirmHost(shareEditorConfirm)
        }

        // Compose/YAML editors are requested from inside the Containers screen but rendered here,
        // alongside the already-hoisted SFTP/share editors, so they receive the whole Activity
        // window and the real IME insets.
        fullScreenEditorHost.content?.invoke()
    }
}

/**
 * First-connect prompt to install tmux on a host configured for persistent sessions. Nothing runs
 * until the user taps Install; the install command (distro-detected, sudo via stdin) streams its
 * output live. The user can also connect once without persistence, or cancel.
 */
@Composable
fun TmuxInstallDialog(viewModel: AppViewModel) {
    val srv = viewModel.tmuxInstallPromptServer ?: return
    val installing = viewModel.tmuxInstalling
    val output = viewModel.tmuxInstallOutput
    AlertDialog(
        onDismissRequest = { if (!installing) viewModel.dismissTmuxInstallPrompt() },
        title = { Text("Install tmux on ${srv.name}?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "This host is set to use persistent sessions, but tmux isn't installed. tmux lets " +
                        "sessions survive network drops and keeps long-running commands going after a " +
                        "reconnect.",
                    fontSize = 13.sp,
                )
                Text(
                    "Install runs the appropriate package-manager command on this host (using your sudo password if set). " +
                        "Connecting without tmux opens a normal, non-resumable shell.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (output != null) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 180.dp)
                            .verticalScroll(rememberScrollState())
                            .background(MaterialTheme.colorScheme.surfaceContainerHighest)
                            .padding(8.dp),
                    ) {
                        Text(output.ifEmpty { "Starting…" }, fontFamily = OmniFonts.mono, fontSize = 11.sp)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { viewModel.installTmuxAndConnect() }, enabled = !installing) {
                Text(if (installing) "Installing…" else "Install tmux")
            }
        },
        dismissButton = {
            Row {
                TextButton(onClick = { viewModel.connectWithoutPersistence() }, enabled = !installing) {
                    Text("Connect non-resumable")
                }
                TextButton(onClick = { viewModel.dismissTmuxInstallPrompt() }, enabled = !installing) {
                    Text("Cancel")
                }
            }
        },
    )
}

@Composable
fun OfflineConnectDialog(viewModel: AppViewModel) {
    val srv = viewModel.offlineConnectPromptServer ?: return
    AlertDialog(
        onDismissRequest = { viewModel.dismissOfflineConnectPrompt() },
        title = { Text("Host Appears Offline") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "${srv.name} (${srv.host}:${srv.port}) didn't answer on its SSH port at the last " +
                        "check, so it looks offline.",
                    fontSize = 13.sp,
                )
                Text(
                    "The status may be out of date — connect anyway to try, or cancel and wait for it to come back online.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { viewModel.connectTerminalConfirmedOffline() }) {
                Text("Connect anyway")
            }
        },
        dismissButton = {
            TextButton(onClick = { viewModel.dismissOfflineConnectPrompt() }) {
                Text("Cancel")
            }
        },
    )
}

@Composable
fun PinLockGateway(viewModel: AppViewModel) {
    val context = LocalContext.current

    // Single biometric trigger reused by auto-prompt and the "Use biometrics" button.
    val triggerBiometric: () -> Unit = {
        context.getActivity()?.let { activity ->
            BiometricCryptoGate.authenticate(
                activity = activity,
                title = "Unlock OmniTerm",
                subtitle = "Authenticate to continue",
                onAuthenticated = { viewModel.biometricSuccessUnlock() },
            )
        }
    }

    // When biometrics is the chosen method, present the system prompt automatically on entry.
    LaunchedEffect(Unit) { if (viewModel.useBiometrics) triggerBiometric() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .imePadding(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(24.dp)
        ) {
            Text(
                text = "OmniTerm",
                fontSize = 42.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = OmniFonts.mono,
                color = Color.White,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            Text(
                text = viewModel.lockScreenError ?: "Enter PIN to unlock",
                color = if (viewModel.lockScreenError != null) Color.Red else Color.Gray,
                fontSize = 16.sp,
                modifier = Modifier.padding(bottom = 28.dp)
            )

            // System keyboard PIN entry (no custom keypad).
            OutlinedTextField(
                value = viewModel.currentPinInput,
                onValueChange = { input ->
                    viewModel.lockScreenError = null
                    viewModel.currentPinInput = input.filter { it.isDigit() }.take(8)
                },
                label = { Text("PIN") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.NumberPassword,
                    imeAction = androidx.compose.ui.text.input.ImeAction.Done,
                ),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                    onDone = { viewModel.submitPinCode() }
                ),
                colors = omniTextFieldColors(),
                modifier = Modifier.fillMaxWidth(0.75f),
            )

            Spacer(modifier = Modifier.height(20.dp))
            Button(
                onClick = { viewModel.submitPinCode() },
                enabled = viewModel.currentPinInput.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(0.75f),
            ) { Text("Unlock") }

            if (viewModel.useBiometrics) {
                Spacer(modifier = Modifier.height(12.dp))
                TextButton(onClick = triggerBiometric) {
                    Icon(Icons.Filled.Fingerprint, contentDescription = null, tint = Color.White)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Use biometrics", color = Color.White)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterialApi::class, ExperimentalLayoutApi::class)
@Composable
fun AppCoreScaffold(viewModel: AppViewModel) {
    val context = LocalContext.current
    val licenseController = remember(context) { createLicenseController(context) }
    DisposableEffect(licenseController) {
        licenseController.start()
        onDispose { licenseController.close() }
    }
    // Re-query owned purchases every time the app returns to the foreground (Google's guidance):
    // catches purchases finalized while backgrounded, out-of-app/promo redemptions, refunds, and
    // revocations. Quiet — no "Checking…" UI; the Restore button stays the explicit path.
    androidx.lifecycle.compose.LifecycleResumeEffect(licenseController) {
        licenseController.onResume()
        onPauseOrDispose { }
    }
    val licenseState by licenseController.state.collectAsStateWithLifecycle()
    LaunchedEffect(licenseState.enabled, licenseState.unlocked) {
        viewModel.updateLicenseEntitlement(licenseState.enabled, licenseState.unlocked)
    }
    // Upsell/ads gating: nothing monetization-related is shown while Billing is still resolving
    // (so a paying user never flashes the free-tier UI). The free-plan banner and ad are shown
    // from first launch — including a fresh zero-host install — so the free-tier limit is disclosed
    // up front rather than only surfacing when the user hits it.
    val showMonetizationUi = licenseState.enabled && !licenseState.loading

    val navItems = remember {
        listOf(
            OmniNavItem(Screen.Servers, "Servers", Icons.Filled.Dns, OmniColors.cyan),
            OmniNavItem(Screen.Fleet, "Fleet", Icons.Filled.Hub, OmniColors.green),
            OmniNavItem(Screen.Monitor, "Monitor", Icons.Filled.Speed, OmniColors.amber),
            OmniNavItem(Screen.Shell, "Term", Icons.Filled.Terminal, OmniColors.cyan),
            // The screen is more than SFTP now (transfers, cross-endpoint bookmarks, SMB/FTP/
            // WebDAV shares) — "Files" names what it does; SFTP is its first subtab.
            OmniNavItem(Screen.SFTP, "Files", Icons.Filled.FolderZip, OmniColors.orange),
            OmniNavItem(Screen.Infra, "Containers", Icons.Filled.Layers, OmniColors.purple),
            OmniNavItem(Screen.Tools, "Tools", Icons.Filled.Build, OmniColors.red),
        )
    }
    val current = viewModel.currentScreen
    fun activeFor(key: Any) = key == current || (key == Screen.Tools && isToolSubScreen(current))
    val activeColor = navItems.firstOrNull { activeFor(it.key) }?.color ?: OmniColors.cyan
    val alerts by viewModel.activeAlerts.collectAsStateWithLifecycle()
    // A landscape software keyboard can consume over half of the physical display. Keeping both
    // global bars mounted in that state left the terminal with zero drawable rows (and made split
    // panes effectively unusable). Terminal-local controls remain available; the global chrome
    // returns as soon as the IME closes.
    val compactTerminalIme = viewModel.currentScreen == Screen.Shell &&
        WindowInsets.isImeVisible &&
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    val pullRefreshState = rememberPullRefreshState(
        refreshing = viewModel.isRefreshing,
        onRefresh = { viewModel.refreshCurrentScreen() }
    )

    Scaffold(
        topBar = {
            if (!compactTerminalIme) Column {
                OmniAppBar(
                    activeColor = activeColor,
                    alertCount = if (viewModel.alertsEnabled) {
                        alerts.count { !it.acknowledged && it.mutedUntil < System.currentTimeMillis() }
                    } else {
                        0
                    },
                    keepScreenOn = viewModel.isKeepScreenOnEnabled,
                    onHome = { viewModel.navigateTo(Screen.Servers) },
                    onAlerts = { viewModel.navigateTo(Screen.Alerts) },
                    onToggleKeepScreenOn = { viewModel.requestKeepScreenOnToggle() },
                )
                if (showMonetizationUi && !licenseState.unlocked) {
                    FreePlanBanner(licenseState, licenseController)
                }
            }
        },
        bottomBar = {
            if (!compactTerminalIme) Column {
                if (showMonetizationUi && !licenseState.adsRemoved) {
                    AdBanner()
                }
                OmniBottomNav(
                    items = navItems,
                    isActive = { activeFor(it) },
                    onNavigate = { viewModel.navigateTo(it as Screen) },
                )
            }
        },
    ) { innerPadding ->
        val allowGlobalGestures = viewModel.currentScreen != Screen.Shell
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                // Mark the scaffold padding as consumed so child imePadding() (terminal) does
                // not double-count the bottom bar / nav bar and leave a black gap by the keyboard.
                .consumeWindowInsets(innerPadding)
                .then(if (allowGlobalGestures) Modifier.pullRefresh(pullRefreshState) else Modifier)
                // Swipe horizontally to page between subtabs and, at the edges, adjacent top tabs.
                .then(if (allowGlobalGestures) Modifier.swipeTabs { forward -> viewModel.swipeNavigate(forward) } else Modifier)
        ) {
            when (viewModel.currentScreen) {
                Screen.Servers -> ServersMainView(viewModel)
                Screen.Fleet -> FleetScreen(viewModel)
                Screen.Monitor -> MonitorScreen(viewModel)
                Screen.Shell -> ShellScreen(viewModel)
                Screen.SFTP -> SftpScreen(viewModel)
                Screen.Infra -> InfraScreen(viewModel)
                // Tools Screen inside Servers tab context
                Screen.Tools -> ToolsScreen(viewModel)
                Screen.Alerts -> AlertsToolView(viewModel)
                Screen.QuickScripts -> QuickScriptsToolView(viewModel)
                Screen.Network -> NetworkToolView(viewModel)
                Screen.AuthKeys -> AuthKeysToolView(viewModel)
                Screen.Backup -> BackupToolView(viewModel)
                Screen.HealthScoring -> HealthScoringToolView(viewModel)
                Screen.Settings -> SettingsToolView(viewModel)
                Screen.About -> AboutToolView(viewModel)
            }

            if (allowGlobalGestures) {
                PullRefreshIndicator(
                    refreshing = viewModel.isRefreshing,
                    state = pullRefreshState,
                    modifier = Modifier.align(Alignment.TopCenter),
                    backgroundColor = MaterialTheme.colorScheme.surface,
                    contentColor = MaterialTheme.colorScheme.primary
                )
            }

            // Global live-output panel for any button-triggered remote action, regardless of tab.
            ActionStreamDialog(viewModel)

            // Biometric/PIN gate for privileged (sudo) actions, shown when one is staged.
            SudoAuthDialog(viewModel)

            // Low-battery saver engaged: tell the user what was shed and offer an instant resume.
            if (viewModel.showBatterySaverDialog) {
                AlertDialog(
                    onDismissRequest = { viewModel.showBatterySaverDialog = false },
                    title = { Text("Battery saver engaged") },
                    text = {
                        Text(
                            "Battery reached ${viewModel.batterySaverEngagedAtPct}% (threshold " +
                                "${viewModel.batterySaverThresholdPct}%). To conserve power, keep-screen-on was " +
                                "turned off, auto-refresh is paused, and persistent (tmux) terminals were parked — " +
                                "they keep running on the host and reattach on your next connect. Non-persistent " +
                                "shells were left connected.\n\nEverything resumes when you charge, when the " +
                                "battery recovers, or when you pull to refresh."
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = { viewModel.showBatterySaverDialog = false }) { Text("Keep saving") }
                    },
                    dismissButton = {
                        TextButton(onClick = { viewModel.resumeFromBatterySaver() }) { Text("Resume now") }
                    },
                )
            }

            // Disconnect dialog safety check
            if (viewModel.showKeepScreenOnBatteryWarning) {
                AlertDialog(
                    onDismissRequest = { viewModel.showKeepScreenOnBatteryWarning = false },
                    title = { Text("Keep Screen On?") },
                    text = { Text("Keeping the screen on prevents display sleep and will increase battery consumption.") },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                viewModel.isKeepScreenOnEnabled = true
                                viewModel.showKeepScreenOnBatteryWarning = false
                            }
                        ) {
                            Text("Enable")
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { viewModel.showKeepScreenOnBatteryWarning = false }) {
                            Text("Cancel")
                        }
                    },
                )
            }

            // Disconnect dialog safety check
            if (viewModel.showDisconnectTerminalDialog) {
                val sessions = viewModel.pendingTerminalNavigationSessions
                val count = sessions.size
                val allPersistent = sessions.isNotEmpty() && sessions.all { it.persistent }
                val hasPersistent = sessions.any { it.persistent }
                val hasNormal = sessions.any { !it.persistent }
                val connecting = viewModel.pendingTerminalNavigationIncludesConnectAttempt
                AlertDialog(
                    onDismissRequest = { viewModel.cancelTerminalNavigation() },
                    title = {
                        Text(
                            when {
                                count > 1 -> "$count active SSH sessions"
                                allPersistent -> "Persistent SSH session"
                                connecting && count == 0 -> "SSH connection in progress"
                                else -> "Active SSH session"
                            }
                        )
                    },
                    text = {
                        Text(
                            when {
                                count == 1 && allPersistent ->
                                    "Leave ${sessions.first().serverName} resumable, or terminate its tmux session and stop anything running there?"
                                count > 1 && hasPersistent && hasNormal ->
                                    "Choose what to do with the terminal sessions in both panes. Persistent sessions can be left resumable; other SSH sessions stay connected in the background."
                                count > 1 && allPersistent ->
                                    "Leave both persistent sessions resumable, or terminate them and stop anything running there?"
                                count > 1 ->
                                    "Choose what to do with the active SSH sessions in both panes. Sending them to the background keeps OmniTerm active and may increase battery consumption."
                                connecting && count == 0 ->
                                    "Cancel the connection attempt, or let it finish in the background?"
                                connecting ->
                                    "Choose what to do with the active terminal session and connection attempt."
                                else ->
                                    "Choose what to do with the active SSH terminal session.\n\n" +
                                        "Sending sessions to the background keeps OmniTerm active and may increase battery consumption."
                            }
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = { viewModel.completeTerminalNavigation(disconnect = true) }
                        ) {
                            Text(
                                when {
                                    connecting && count == 0 -> "Cancel connection"
                                    count > 1 -> "Disconnect all"
                                    else -> "Disconnect"
                                },
                                color = Color.Red,
                            )
                        }
                    },
                    dismissButton = {
                        Row {
                            TextButton(
                                onClick = { viewModel.completeTerminalNavigation(disconnect = false) }
                            ) {
                                Text(
                                    when {
                                        connecting && count == 0 -> "Continue in background"
                                        allPersistent -> "Leave resumable"
                                        hasPersistent && hasNormal -> "Keep sessions"
                                        else -> "Send to background"
                                    }
                                )
                            }
                            TextButton(
                                onClick = { viewModel.cancelTerminalNavigation() }
                            ) {
                                Text("Stay")
                            }
                        }
                    }
                )
            }

            viewModel.pendingDisconnectSessionId?.let { sessionId ->
                val session = viewModel.activeSessions.find { it.id == sessionId }
                AlertDialog(
                    onDismissRequest = { viewModel.cancelPendingDisconnect() },
                    title = { Text(if (session?.persistent == true) "Close persistent session?" else "Disconnect session?") },
                    text = {
                        Text(
                            if (session?.persistent == true) {
                                "Leave ${session.serverName} resumable, or terminate its tmux session and stop anything running there?"
                            } else {
                                "Keep ${session?.serverName ?: "this terminal session"} connected in the background, or disconnect and stop anything running in that terminal?"
                            }
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                viewModel.disconnectSession(sessionId)
                                viewModel.cancelPendingDisconnect()
                            }
                        ) {
                            Text(if (session?.persistent == true) "Terminate" else "Disconnect", color = Color.Red)
                        }
                    },
                    dismissButton = {
                        Row {
                            if (session?.persistent == true) {
                                TextButton(
                                    onClick = {
                                        viewModel.leaveSessionResumable(sessionId)
                                        viewModel.cancelPendingDisconnect()
                                    }
                                ) {
                                    Text("Leave resumable")
                                }
                            } else if (session != null) {
                                TextButton(
                                    onClick = {
                                        viewModel.sendSessionToBackground(sessionId)
                                        viewModel.cancelPendingDisconnect()
                                    }
                                ) {
                                    Text("Send to background")
                                }
                            }
                            TextButton(onClick = { viewModel.cancelPendingDisconnect() }) { Text("Cancel") }
                        }
                    },
                )
            }

            if (viewModel.pendingDisconnectAllSessions) {
                AlertDialog(
                    onDismissRequest = { viewModel.cancelPendingDisconnect() },
                    title = { Text("Disconnect all sessions?") },
                    text = { Text("Disconnect all active terminal sessions? Any running shell processes in those PTYs will be terminated.") },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                viewModel.closeAllSessions()
                                viewModel.cancelPendingDisconnect()
                            }
                        ) {
                            Text("Disconnect all", color = Color.Red)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { viewModel.cancelPendingDisconnect() }) { Text("Cancel") }
                    },
                )
            }

            if (viewModel.hostLimitReconciliationRequired) {
                HostLimitReconciliationDialog(viewModel)
            }

            // Force permissions
            val context = androidx.compose.ui.platform.LocalContext.current
            var needsPermissions by remember { mutableStateOf(false) }
            var permissionPromptDismissed by rememberSaveable { mutableStateOf(false) }
            val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
            DisposableEffect(lifecycleOwner) {
                val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
                    if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                        val hasNotif = android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU ||
                            ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        val pm = context.getSystemService(android.os.PowerManager::class.java)
                        val hasBatt = pm?.isIgnoringBatteryOptimizations(context.packageName) == true
                        needsPermissions = viewModel.isBackgroundKeepAlive &&
                            viewModel.activeSessions.isNotEmpty() && (!hasNotif || !hasBatt)
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
            }

            if (needsPermissions && !permissionPromptDismissed) {
                FirstRunDialog(viewModel) { permissionPromptDismissed = true }
            }
        }
    }
}

@Composable
private fun HostLimitReconciliationDialog(viewModel: AppViewModel) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var selectedId by remember(servers) { mutableStateOf(servers.firstOrNull()?.id) }
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Choose host to keep") },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    viewModel.hostLimitReconciliationReason.ifBlank {
                        "The free Play Store build supports one saved host."
                    },
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                servers.forEach { server ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { selectedId = server.id }
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = selectedId == server.id, onClick = { selectedId = server.id })
                        Column(Modifier.weight(1f)) {
                            Text(server.name, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                "${server.username}@${server.host}:${server.port}",
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = selectedId != null,
                onClick = { selectedId?.let(viewModel::keepOnlyHostAfterLimitChange) },
            ) { Text("Keep selected") }
        },
    )
}

@Composable
private fun FreePlanBanner(state: LicenseState, controller: LicenseController) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(OmniColors.cyan.copy(alpha = 0.12f))
            .border(1.dp, OmniColors.cyan.copy(alpha = 0.28f))
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.WorkspacePremium, contentDescription = null, tint = OmniColors.cyan, modifier = Modifier.size(18.dp))
                Text(
                    // Reflect what the free build actually is: ad-supported and limited to 1 host until
                    // ads are removed; once ads are gone it's just the host/credential limit.
                    if (state.adsRemoved) {
                        "Free Play Store build: 1 host & 1 credential"
                    } else {
                        "Free, ad-supported build: 1 host & 1 credential"
                    },
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
            }
            // FlowRow so the three upsell buttons (Restore / Remove ads / Unlock unlimited) wrap to a
            // second line on narrow screens instead of clipping when prices make them too wide.
            @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
            androidx.compose.foundation.layout.FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                verticalArrangement = Arrangement.Center,
            ) {
            // Re-queries owned purchases from Play — the "Restore purchase" path for reinstalls
            // and new devices.
            TextButton(
                onClick = { controller.refresh() },
                enabled = !state.loading,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) {
                Text("Restore", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            // Cheaper ads-only removal. Its only entry point in the app — shown next to the full
            // Unlock here (not as a separate bottom strip) so the ad area stays just ad + nav. Hidden
            // once ads are already removed (or the user fully unlocked).
            if (!state.adsRemoved) {
                TextButton(
                    onClick = { context.getActivity()?.let(controller::launchAdRemovalPurchase) },
                    enabled = !state.loading,
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                ) {
                    Text(
                        when {
                            state.loading -> "Checking…"
                            state.adRemovalPrice != null -> "Remove ads ${state.adRemovalPrice}"
                            else -> "Remove ads"
                        },
                        fontSize = 11.sp,
                        color = OmniColors.green,
                    )
                }
            }
            TextButton(
                onClick = { context.getActivity()?.let(controller::launchPurchase) },
                enabled = !state.loading,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) {
                Text(
                    when {
                        state.loading -> "Checking..."
                        state.productPrice != null -> "Unlock unlimited ${state.productPrice}"
                        else -> "Unlock unlimited"
                    },
                    fontSize = 11.sp,
                )
            }
            }
        }
        // Billing problems (Play unavailable, purchase failed, restore failed) were previously
        // swallowed; surface them where the purchase buttons live.
        state.message?.let { msg ->
            Text(
                msg,
                fontSize = 11.sp,
                color = OmniColors.amber,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun AdBanner() {
    Column(modifier = Modifier.fillMaxWidth().background(OmniColors.bg1)) {
        // Just the ad — a single anchored adaptive banner (Play Store build only; nothing in the
        // source-available build). The "Remove ads" purchase lives in the top FreePlanBanner alongside
        // "Unlock unlimited", so the bottom is only the ad + nav with no empty upsell strip.
        FlavorAdBanner(modifier = Modifier.fillMaxWidth())
    }
}

@Composable
fun FirstRunDialog(viewModel: AppViewModel, onNotNow: () -> Unit = {}) {
    val context = androidx.compose.ui.platform.LocalContext.current
    fun launchBatteryOptimizationSettings() {
        // Open Android's neutral settings list. Requesting a direct package exemption requires a
        // policy-sensitive manifest permission and is unnecessary for a user-controlled choice.
        runCatching {
            context.startActivity(
                android.content.Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            )
        }
    }

    val notificationPermissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            launchBatteryOptimizationSettings()
        } else {
            runCatching {
                context.startActivity(
                    android.content.Intent(
                        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.parse("package:${context.packageName}")
                    )
                )
            }
        }
    }

    AlertDialog(
        onDismissRequest = onNotNow,
        title = { Text("Keep sessions active in background?") },
        text = {
            Column {
                Text("Notification access and a battery-optimization exemption improve background SSH reliability. They are optional; foreground terminals continue to work without them.")
                Spacer(Modifier.height(8.dp))
                Text("Please tap below to grant them.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val needsNotificationPermission = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    if (needsNotificationPermission) {
                        notificationPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        launchBatteryOptimizationSettings()
                    }
                }
            ) {
                Text("Grant Permissions")
            }
        },
        dismissButton = { TextButton(onClick = onNotNow) { Text("Not now") } },
    )
}

fun isToolSubScreen(screen: Screen): Boolean {
    return screen in listOf(
        Screen.Tools, Screen.Alerts, Screen.QuickScripts, Screen.Network,
        Screen.AuthKeys, Screen.Backup, Screen.HealthScoring, Screen.Settings, Screen.About
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ServersMainView(viewModel: AppViewModel) {
    val srvList by viewModel.servers.collectAsStateWithLifecycle()
    var showAddSheet by remember { mutableStateOf(false) }
    var editingServer by remember { mutableStateOf<ServerEntity?>(null) }
    // Source host for a "Duplicate": opens the add-sheet pre-filled from it (see AddServerSheet).
    var duplicatingFrom by remember { mutableStateOf<ServerEntity?>(null) }
    var selectedForActionSheet by remember { mutableStateOf<ServerEntity?>(null) }
    var showBulkGroupDialog by remember { mutableStateOf(false) }
    var bulkGroupName by remember { mutableStateOf("") }
    var scoreDialogServer by remember { mutableStateOf<ServerEntity?>(null) }
    val hostLimitReached = viewModel.hasHostLimit && srvList.size >= viewModel.hostLimit
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Box(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Summary Dashboard Banner
            OmniCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 10.dp, vertical = 10.dp)
            ) {
                val total = srvList.size
                val online = srvList.count { it.status == "online" }
                val offline = srvList.count { it.status == "offline" }
                val groups = srvList.mapNotNull { it.groupName }.distinct().size

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    OmniStatBox(value = "$total", label = "Total", modifier = Modifier.weight(1f))
                    OmniStatBox(value = "$online", label = "Online", modifier = Modifier.weight(1f), color = OmniColors.green)
                    OmniStatBox(value = "$offline", label = "Offline", modifier = Modifier.weight(1f), color = if (offline > 0) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant)
                    OmniStatBox(value = "$groups", label = "Groups", modifier = Modifier.weight(1f), color = OmniColors.cyan)
                }
            }

            // Search and Multi-Select action buttons
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = viewModel.serverSearchText,
                    onValueChange = { viewModel.serverSearchText = it },
                    placeholder = { Text("Hostname or IP") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = "Search") },
                    trailingIcon = {
                        if (viewModel.serverSearchText.isNotEmpty()) {
                            IconButton(onClick = { viewModel.serverSearchText = "" }) {
                                Icon(Icons.Filled.Close, contentDescription = "Clear")
                            }
                        }
                    },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    shape = RoundedCornerShape(8.dp),
                    colors = omniTextFieldColors()
                )
                Spacer(modifier = Modifier.width(8.dp))
                // Compact auto-refresh countdown lives inline in the toolbar (no dedicated row).
                RefreshCountdown(viewModel.lastTelemetryStartMs, viewModel.telemetryIntervalMs, size = 26.dp)
                Spacer(modifier = Modifier.width(4.dp))
                IconButton(
                    onClick = {
                        viewModel.isMultiSelectMode = !viewModel.isMultiSelectMode
                        viewModel.selectedServerIdsForBulk.clear()
                    }
                ) {
                    Icon(
                        if (viewModel.isMultiSelectMode) Icons.Filled.Checklist else Icons.Outlined.Checklist,
                        contentDescription = "Multi-select",
                        tint = if (viewModel.isMultiSelectMode) MaterialTheme.colorScheme.primary else Color.Gray
                    )
                }
                Spacer(modifier = Modifier.width(4.dp))
                // Add-server lives at the top so it never overlaps cards in a long host list.
                FilledIconButton(
                    onClick = { if (!hostLimitReached) showAddSheet = true },
                    enabled = !hostLimitReached,
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "Add server")
                }
            }

            if (hostLimitReached) {
                Text(
                    "Free Play Store build is limited to 1 saved host. Unlock OmniTerm to add more.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                )
            }

            // Horizontal Filters (Groups chips list)
            val distinctGroups = listOf("All") + srvList.mapNotNull { it.groupName }.distinct()
            LazyRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(distinctGroups) { grp ->
                    val selected = viewModel.selectedGroupChip == grp
                    FilterChip(
                        selected = selected,
                        onClick = { viewModel.selectedGroupChip = grp },
                        label = { Text(grp) }
                    )
                }
            }

            // Bulk actions for the current multi-select set.
            if (viewModel.isMultiSelectMode) {
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(text = "${viewModel.selectedServerIdsForBulk.size} servers selected", fontWeight = FontWeight.Medium)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { viewModel.selectAllServers() }) { Text("Select All") }
                            Button(
                                enabled = viewModel.selectedServerIdsForBulk.isNotEmpty(),
                                onClick = {
                                    bulkGroupName = viewModel.selectedGroupChip.takeUnless { it == "All" }.orEmpty()
                                    showBulkGroupDialog = true
                                }
                            ) { Text("Group") }
                            IconButton(onClick = { viewModel.clearBulkSelect() }) { Icon(Icons.Filled.Close, "Cancel") }
                        }
                    }
                }
            }

            // Srv Cards Layout Feed
            val filteredList = srvList.filter {
                val matchesSearch = it.name.contains(viewModel.serverSearchText, ignoreCase = true) ||
                        it.host.contains(viewModel.serverSearchText, ignoreCase = true)
                val matchesGroup = viewModel.selectedGroupChip == "All" || it.groupName == viewModel.selectedGroupChip
                matchesSearch && matchesGroup
            }

            if (filteredList.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Filled.Dns, contentDescription = null, modifier = Modifier.size(64.dp), tint = Color.LightGray)
                        Spacer(modifier = Modifier.height(8.dp))
                        if (srvList.isEmpty()) {
                            // True first run (no hosts at all): a short checklist instead of a
                            // bare "not found", so a beginner knows what they need before tapping +.
                            Text("Connect your first server", fontWeight = FontWeight.Bold)
                            Column(
                                horizontalAlignment = Alignment.Start,
                                modifier = Modifier.padding(top = 8.dp, start = 32.dp, end = 32.dp),
                            ) {
                                listOf(
                                    "1.  An SSH server must be running on it (on most Linux: sudo apt install openssh-server)",
                                    "2.  Find its IP address or hostname (e.g. 192.168.1.50)",
                                    "3.  Have your username and password — or an SSH key — ready",
                                    "4.  On first connect, OmniTerm shows the server's key fingerprint so you can verify it",
                                ).forEach {
                                    Text(
                                        it,
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(vertical = 2.dp),
                                    )
                                }
                            }
                        } else {
                            Text("No servers found", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Button(
                            onClick = { showAddSheet = true },
                            modifier = Modifier.padding(top = 16.dp),
                            enabled = !hostLimitReached,
                        ) {
                            Text("Add Host Server")
                        }
                        if (hostLimitReached) {
                            Text(
                                "Free Play Store build is limited to 1 saved host. Unlock OmniTerm to add more.",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(top = 8.dp, start = 24.dp, end = 24.dp),
                            )
                        }
                    }
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // Stable keys: only the cards whose host actually changed recompose on the
                    // 15-second telemetry ticks.
                    items(filteredList, key = { it.id }) { server ->
                        val identityColor = getServerColor(server)
                        // Live metrics for THIS host — populated for every reachable host by
                        // the concurrent telemetry loop, so all cards show real CPU/RAM/DISK.
                        val liveMetrics = viewModel.hostMetricsById[server.id]
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .combinedClickable(
                                    onClick = {
                                        if (viewModel.isMultiSelectMode) {
                                            viewModel.toggleBulkSelectServer(server.id)
                                        } else {
                                            viewModel.selectedServerId = server.id
                                            viewModel.navigateTo(Screen.Monitor)
                                        }
                                    },
                                    onLongClick = {
                                        if (!viewModel.isMultiSelectMode) {
                                            viewModel.isMultiSelectMode = true
                                            viewModel.toggleBulkSelectServer(server.id)
                                        }
                                    }
                                )
                        ) {
                            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = identityColor) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                                            if (viewModel.isMultiSelectMode) {
                                                Checkbox(
                                                    checked = viewModel.selectedServerIdsForBulk.contains(server.id),
                                                    onCheckedChange = { viewModel.toggleBulkSelectServer(server.id) }
                                                )
                                                Spacer(modifier = Modifier.width(4.dp))
                                            }
                                            StatusDot(
                                                online = server.status == "online" || server.status == "connecting",
                                                color = if (server.status == "connecting") OmniColors.amber else identityColor,
                                                size = 8.dp,
                                            )
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text(
                                                text = server.name,
                                                fontWeight = FontWeight.Bold,
                                                fontFamily = OmniFonts.mono,
                                                fontSize = 16.sp,
                                                color = MaterialTheme.colorScheme.onSurface,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                                modifier = Modifier.weight(1f, fill = false),
                                            )
                                        }

                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            val probed = viewModel.probedServerIds.containsKey(server.id)
                                            Text(
                                                text = when {
                                                    server.status == "online" -> "${server.lastLatency}ms"
                                                    server.status == "connecting" || !probed -> "…"
                                                    else -> "Offline"
                                                },
                                                fontSize = 12.sp,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Box(modifier = Modifier.clickable { scoreDialogServer = server }) {
                                                ScoreRing(score = if (server.status == "online") server.healthScore else 0, size = 38.dp)
                                            }
                                            IconButton(onClick = { selectedForActionSheet = server }) {
                                                Icon(Icons.Filled.MoreVert, contentDescription = "Actions")
                                            }
                                        }
                                    }

                                    // Host line + the group tag, kept together below the name in a
                                    // neutral colour so the tag no longer competes with the actions.
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = "${server.username}@${server.host}:${server.port}",
                                            fontSize = 14.sp,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f, fill = false),
                                        )
                                        server.groupName?.takeIf { it.isNotBlank() }?.let { groupName ->
                                            Spacer(modifier = Modifier.width(8.dp))
                                            OmniTag(groupName, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }

                                    // Host notes (if documented) — shown below the connection line.
                                    if (server.notes.isNotBlank()) {
                                        Text(
                                            text = server.notes,
                                            fontSize = 12.sp,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
                                            maxLines = 3,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp),
                                        )
                                    }

                                    // Online + auth OK → show real gauges (hardcoded values removed).
                                    // Online + auth FAILED → show the actual error, no fake metrics.
                                    if (server.status == "online" && server.authStatus == "failed") {
                                        // Host reachable but SSH failed: lead with the category
                                        // (login vs trust vs network), raw error underneath.
                                        Column(modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                Icon(Icons.Filled.Warning, contentDescription = null, tint = OmniColors.red, modifier = Modifier.size(16.dp))
                                                Spacer(Modifier.width(6.dp))
                                                Text(
                                                    "Online · ${sshFailureSummary(server.authError)}",
                                                    color = OmniColors.red, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                                )
                                                Spacer(Modifier.weight(1f))
                                                OmniButton(
                                                    label = "Retry",
                                                    onClick = { viewModel.refreshServer(server.id) },
                                                    color = OmniColors.red,
                                                    small = true
                                                )
                                            }
                                            server.authError?.let {
                                                Text(
                                                    it,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                    fontSize = 11.sp, fontFamily = OmniFonts.mono,
                                                    modifier = Modifier.padding(start = 22.dp, top = 2.dp),
                                                )
                                            }
                                        }
                                    } else if (server.status == "online") {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                                        ) {
                                            MiniMetric("CPU", liveMetrics?.cpuPercent ?: 0f, modifier = Modifier.weight(1f), color = identityColor)
                                            MiniMetric("RAM", liveMetrics?.memPercent ?: 0f, modifier = Modifier.weight(1f), color = identityColor)
                                            MiniMetric("DISK", liveMetrics?.diskPercent ?: 0f, modifier = Modifier.weight(1f), color = identityColor)
                                        }

                                        Row(
                                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                                            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            StatusDot(online = true, color = identityColor, size = 5.dp)
                                            Text(
                                                if (server.authStatus == "ok") "authenticated" else "online · ssh not verified yet",
                                                color = if (server.authStatus == "ok") OmniColors.green else OmniColors.amber,
                                                fontFamily = OmniFonts.mono, fontSize = 11.sp,
                                            )
                                            Spacer(Modifier.weight(1f))
                                            OmniButton(
                                                label = "SSH",
                                                onClick = {
                                                    viewModel.selectedServerId = server.id
                                                    viewModel.connectTerminal()
                                                    // If the offline warning gate fired, stay here —
                                                    // confirming it navigates to the terminal itself.
                                                    if (viewModel.offlineConnectPromptServer == null) {
                                                        viewModel.navigateTo(Screen.Shell)
                                                    }
                                                },
                                                color = identityColor,
                                                small = true
                                            )
                                            OmniButton(
                                                label = "SFTP",
                                                onClick = {
                                                    viewModel.selectedServerId = server.id
                                                    viewModel.navigateTo(Screen.SFTP)
                                                },
                                                color = identityColor,
                                                small = true
                                            )
                                            OmniButton(
                                                label = "DOCKER",
                                                onClick = {
                                                    viewModel.selectedServerId = server.id
                                                    viewModel.navigateTo(Screen.Infra)
                                                },
                                                color = identityColor,
                                                small = true
                                            )
                                        }
                                    } else if (server.status == "connecting" || !viewModel.probedServerIds.containsKey(server.id)) {
                                        // Covers an explicit "connecting" state AND the window
                                        // after app start before the first probe has finished —
                                        // the DB says "offline" then only because of the startup
                                        // reset, which used to read as a false Offline.
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Text("Checking host…", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    } else {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text("Offline · unreachable", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.Red)
                                                Text(
                                                    "No TCP route to ${server.host}:${server.port} — host down, wrong address/port, or network blocked",
                                                    fontSize = 10.sp,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                )
                                            }
                                            OmniButton(
                                                label = "Retry",
                                                onClick = { viewModel.refreshServer(server.id) },
                                                color = OmniColors.red,
                                                small = true
                                            )
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }

        scoreDialogServer?.let { s ->
            HealthBreakdownDialog(viewModel, s) { scoreDialogServer = null }
        }

        if (showAddSheet) {
            AddServerSheet(viewModel = viewModel, serverToEdit = null) { showAddSheet = false }
        }

        editingServer?.let { s ->
            AddServerSheet(viewModel = viewModel, serverToEdit = s) { editingServer = null }
        }

        duplicatingFrom?.let { s ->
            AddServerSheet(viewModel = viewModel, serverToEdit = null, prefillFrom = s) { duplicatingFrom = null }
        }

        // Host ellipsis parameters selector actions drawer drawer
        selectedForActionSheet?.let { srv ->
            AlertDialog(
                onDismissRequest = { selectedForActionSheet = null },
                title = { Text(srv.name, fontWeight = FontWeight.Bold) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                editingServer = srv
                            }
                        ) {
                            Icon(Icons.Filled.Edit, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Edit Server Configuration")
                        }
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                // Open a NEW-host draft pre-filled (incl. credentials) from this host.
                                // Nothing is saved until the user confirms, so the copy is fully
                                // independent and still passes the first-connect host-key trust gate.
                                duplicatingFrom = srv
                            }
                        ) {
                            Icon(Icons.Filled.ContentCopy, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Duplicate Host (reuse credentials)")
                        }
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                viewModel.selectedServerId = srv.id
                                viewModel.connectTerminal()
                                // If the offline warning gate fired, stay here — confirming it
                                // navigates to the terminal itself.
                                if (viewModel.offlineConnectPromptServer == null) {
                                    viewModel.navigateTo(Screen.Shell)
                                }
                            }
                        ) {
                            Icon(Icons.Filled.Terminal, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Open Terminal Console")
                        }
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                viewModel.selectedServerId = srv.id
                                viewModel.navigateTo(Screen.Monitor)
                            }
                        ) {
                            Icon(Icons.Filled.Speed, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Monitor Live Metrics")
                        }
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                viewModel.selectedServerId = srv.id
                                viewModel.navigateTo(Screen.Infra)
                            }
                        ) {
                            Icon(Icons.Filled.Layers, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Infrastructure & Containers")
                        }
                        TextButton(
                            onClick = {
                                selectedForActionSheet = null
                                confirm.ask(
                                    "Delete ${srv.name}?",
                                    "Remove this host connection (and its saved credentials) from OmniTerm? This does not affect the remote machine, but cannot be undone here.",
                                    confirmLabel = "Delete",
                                ) { viewModel.deleteServer(srv) }
                            }
                        ) {
                            Icon(Icons.Filled.Delete, null, tint = Color.Red)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Delete Server Host Connection", color = Color.Red)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { selectedForActionSheet = null }) { Text("Dismiss") }
                }
            )
        }

        if (showBulkGroupDialog) {
            val existingGroups = (listOf("Default") + srvList.mapNotNull { it.groupName?.takeIf { g -> g.isNotBlank() } }).distinct()
            var groupMenuOpen by remember { mutableStateOf(false) }
            AlertDialog(
                onDismissRequest = { showBulkGroupDialog = false },
                title = { Text("Assign Group") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${viewModel.selectedServerIdsForBulk.size} selected server(s) will be moved to this group.")
                        Box {
                            OutlinedTextField(
                                value = bulkGroupName,
                                onValueChange = { bulkGroupName = it },
                                label = { Text("Group name") },
                                singleLine = true,
                                trailingIcon = {
                                    IconButton(onClick = { groupMenuOpen = true }) {
                                        Icon(Icons.Filled.ArrowDropDown, contentDescription = "Pick existing group")
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            )
                            DropdownMenu(expanded = groupMenuOpen, onDismissRequest = { groupMenuOpen = false }) {
                                existingGroups.forEach { g ->
                                    DropdownMenuItem(text = { Text(g) }, onClick = { bulkGroupName = g; groupMenuOpen = false })
                                }
                            }
                        }
                        Text("Pick an existing group or type a new group name.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                confirmButton = {
                    Button(
                        onClick = {
                            viewModel.assignGroupToBulk(bulkGroupName)
                            showBulkGroupDialog = false
                            bulkGroupName = ""
                        }
                    ) { Text("Apply") }
                },
                dismissButton = {
                    TextButton(onClick = { showBulkGroupDialog = false }) { Text("Cancel") }
                }
            )
        }
    }
}

/**
 * One-line human classification of an SSH failure, so the hosts list can say WHAT went wrong
 * (login vs trust vs network) instead of a bare "Authentication failed". The raw error stays
 * visible underneath for diagnosis.
 */
private fun sshFailureSummary(err: String?): String = when {
    err == null -> "SSH failed"
    err.contains("hostkey", true) || err.contains("host key", true) ||
        err.contains("UnknownHostKey", true) || err.contains("reject", true) -> "Host key not trusted"
    err.contains("auth", true) -> "Login failed"
    err.contains("timeout", true) || err.contains("timed out", true) -> "SSH timed out"
    err.contains("refused", true) -> "SSH connection refused"
    else -> "SSH error"
}

/**
 * Password input for the server editor that never displays a stored secret. When a value is
 * already saved ([hasStored]) and nothing has been typed, it explains that leaving the field
 * blank keeps the saved value and offers Forget to remove it on save — so the reveal toggle
 * can only ever expose text typed in this session.
 */
@Composable
private fun StoredSecretField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    hasStored: Boolean,
    forgetStored: Boolean,
    onForgetStoredChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        OmniPasswordField(
            value = value,
            onValueChange = onValueChange,
            label = label,
            modifier = Modifier.fillMaxWidth(),
        )
        if (hasStored && value.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (forgetStored) "Saved password will be removed when you save."
                    else "A password is saved (never shown here). Leave blank to keep it, or type to replace.",
                    fontSize = 11.sp,
                    color = if (forgetStored) Color.Red else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { onForgetStoredChange(!forgetStored) }) {
                    Text(if (forgetStored) "Keep" else "Forget", fontSize = 11.sp)
                }
            }
        }
    }
}

// Bottom sheet simulation layout component that allows connection/credential wizard splits
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddServerSheet(
    viewModel: AppViewModel,
    serverToEdit: ServerEntity?,
    // When set (and serverToEdit is null), this is a DUPLICATE: the form pre-fills from [prefillFrom]
    // — including credentials — but the sheet stays in add-mode. Nothing is written until the user
    // saves, the save goes through addServer() as a brand-new independent host, and the first-connect
    // host-key trust gate is enforced (testedOkSignature starts null) exactly like any new host. This
    // guarantees the copy shares no live state with its source.
    prefillFrom: ServerEntity? = null,
    onDismiss: () -> Unit,
) {
    var activeTab by remember { mutableStateOf(0) } // 0: Connect, 1: Auth, 2: Adv

    // Source for pre-filling non-secret fields: the edited host, else a duplicate's source, else none.
    val src = serverToEdit ?: prefillFrom
    val isDuplicate = serverToEdit == null && prefillFrom != null

    // Form parameter captures
    var name by remember { mutableStateOf(if (isDuplicate) "${src?.name} copy" else (src?.name ?: "")) }
    var host by remember { mutableStateOf(src?.host ?: "") }
    var port by remember { mutableStateOf(src?.port?.toString() ?: "22") }
    var user by remember { mutableStateOf(src?.username ?: "") }
    var group by remember { mutableStateOf(src?.groupName ?: "Default") }
    var serverColor by remember { mutableStateOf(src?.serverColor ?: "Default") }

    // Existing group labels (so a typo can't silently fork a new label).
    val allServers by viewModel.servers.collectAsStateWithLifecycle()
    val existingGroups = remember(allServers) {
        (listOf("Default") + allServers.mapNotNull { it.groupName }).distinct()
    }

    // Auth vars
    var authType by remember { mutableStateOf(src?.authType ?: "password") } // password, key, profile
    // Stored secrets are never loaded back into the form for an EDIT: an empty field means "keep the
    // saved value" (or "remove it" when the matching forget* flag is set), keeping saved passwords out
    // of the UI. For a DUPLICATE there is no saved row to fall back to, so the source's secrets ARE
    // seeded here — that's the whole point of "reuse credentials" — and travel through addServer().
    var password by remember { mutableStateOf(if (isDuplicate) prefillFrom.authPassword ?: "" else "") }
    var forgetPassword by remember { mutableStateOf(false) }
    var selectedKey by remember { mutableStateOf(src?.authKeyAlias ?: "") }
    var selectedProfileId by remember { mutableStateOf<Int?>(src?.authProfileId) }
    var saveProfile by remember { mutableStateOf(false) }
    val hasStoredPassword = !serverToEdit?.authPassword.isNullOrEmpty()

    // Advanced vars
    var notes by remember { mutableStateOf(src?.notes ?: "") }
    var keepAlive by remember { mutableStateOf(src?.keepAlive?.toString() ?: "30") }
    var compression by remember { mutableStateOf(src?.sshCompression ?: false) }
    var persistentSession by remember { mutableStateOf(src?.persistentSession ?: false) }
    var agentForwarding by remember { mutableStateOf(src?.agentForwarding ?: false) }
    var sudoPassword by remember { mutableStateOf(if (isDuplicate) prefillFrom.sudoPassword else "") }
    var forgetSudoPassword by remember { mutableStateOf(false) }
    val hasStoredSudoPassword = !serverToEdit?.sudoPassword.isNullOrEmpty()
    var proxyType by remember { mutableStateOf(src?.proxyType ?: "none") }
    var proxyHost by remember { mutableStateOf(src?.proxyHost ?: "") }
    var proxyPort by remember { mutableStateOf(src?.proxyPort?.takeIf { it > 0 }?.toString() ?: "") }
    var proxyUser by remember { mutableStateOf(src?.proxyUser ?: "") }
    var proxyPassword by remember { mutableStateOf(if (isDuplicate) prefillFrom.proxyPassword else "") }
    var forgetProxyPassword by remember { mutableStateOf(false) }
    val hasStoredProxyPassword = !serverToEdit?.proxyPassword.isNullOrEmpty()
    var proxyKeyAlias by remember { mutableStateOf(src?.proxyKeyAlias ?: "") }

    var errorText by remember { mutableStateOf<String?>(null) }
    var testingConnection by remember { mutableStateOf(false) }
    var testResultText by remember { mutableStateOf<String?>(null) }
    var confirmDuplicateHost by remember { mutableStateOf<ServerEntity?>(null) }
    val coroutineScope = rememberCoroutineScope()

    DisposableEffect(Unit) {
        onDispose {
            password = ""
            sudoPassword = ""
            proxyPassword = ""
        }
    }

    val savedKeys by viewModel.keys.collectAsStateWithLifecycle()
    val savedProfiles by viewModel.profiles.collectAsStateWithLifecycle()

    // Resolve what each secret should be on save: typed text wins, otherwise the stored value is
    // kept unless the user asked to forget it. Also used by Test Connection so a blank field
    // (= keep saved) still tests with the real credential.
    fun effectivePassword() = when {
        password.isNotEmpty() -> password
        forgetPassword -> ""
        else -> serverToEdit?.authPassword ?: ""
    }
    fun effectiveSudoPassword() = when {
        sudoPassword.isNotEmpty() -> sudoPassword
        forgetSudoPassword -> ""
        else -> serverToEdit?.sudoPassword ?: ""
    }
    fun effectiveProxyPassword() = when {
        proxyPassword.isNotEmpty() -> proxyPassword
        forgetProxyPassword -> ""
        else -> serverToEdit?.proxyPassword ?: ""
    }

    // Fingerprint of every connection-relevant field. Saving requires a successful Test
    // Connection for the CURRENT fingerprint so the first-connect host key approval can never
    // be skipped; editing cosmetic fields (name, group, colour, notes) never forces a retest,
    // and an existing host's stored config counts as already tested.
    fun connectionSignature() = listOf(
        host.trim(), port, user, authType, effectivePassword(), selectedKey,
        selectedProfileId?.toString() ?: "", proxyType, proxyHost.trim(), proxyPort, proxyUser,
        effectiveProxyPassword(), proxyKeyAlias,
    ).joinToString("\u0000")
    var testedOkSignature by remember {
        mutableStateOf(if (serverToEdit != null) connectionSignature() else null)
    }

    fun saveServerDraft() {
        if (serverToEdit != null) {
            viewModel.updateServer(
                serverToEdit.copy(
                    name = name,
                    host = host,
                    port = port.toIntOrNull() ?: 22,
                    username = user,
                    groupName = group,
                    serverColor = serverColor,
                    authType = authType,
                    authPassword = effectivePassword(),
                    authKeyAlias = selectedKey,
                    authProfileId = selectedProfileId,
                    notes = notes,
                    keepAlive = keepAlive.toIntOrNull() ?: 30,
                    sshCompression = compression,
                    persistentSession = persistentSession,
                    agentForwarding = agentForwarding,
                    proxyCommand = "",
                    sudoPassword = effectiveSudoPassword(),
                    proxyType = proxyType,
                    proxyHost = proxyHost,
                    proxyPort = proxyPort.toIntOrNull() ?: 0,
                    proxyUser = proxyUser,
                    proxyPassword = effectiveProxyPassword(),
                    proxyKeyAlias = proxyKeyAlias.takeIf { it.isNotBlank() && proxyType == "ssh" }
                )
            )
            onDismiss()
        } else {
            if (viewModel.hasHostLimit && allServers.size >= viewModel.hostLimit) {
                errorText = "The free Play Store build supports 1 saved host. Unlock OmniTerm to add unlimited hosts."
                return
            }
            viewModel.addServer(
                name = name,
                host = host,
                port = port.toIntOrNull() ?: 22,
                username = user,
                group = group,
                authType = authType,
                notes = notes,
                keepAlive = keepAlive.toIntOrNull() ?: 30,
                compression = compression,
                persistentSession = persistentSession,
                agentForwarding = agentForwarding,
                proxy = "",
                password = password,
                keyAlias = selectedKey,
                profileId = selectedProfileId,
                createProfile = saveProfile,
                serverColor = serverColor,
                sudoPassword = sudoPassword,
                proxyType = proxyType,
                proxyHost = proxyHost,
                proxyPort = proxyPort.toIntOrNull() ?: 0,
                proxyUser = proxyUser,
                proxyPassword = proxyPassword,
                proxyKeyAlias = proxyKeyAlias.takeIf { it.isNotBlank() && proxyType == "ssh" },
            ) { err ->
                if (err != null) {
                    errorText = err
                } else {
                    onDismiss()
                }
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (isDuplicate) "Duplicate Host" else if (serverToEdit == null) "Add Linux Remote Host" else "Edit Linux Remote Host") },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
            ) {
                PrimaryTabRow(selectedTabIndex = activeTab) {
                    Tab(selected = activeTab == 0, onClick = { activeTab = 0 }) { Text("Connection", fontSize = 12.sp, modifier = Modifier.padding(8.dp)) }
                    Tab(selected = activeTab == 1, onClick = { activeTab = 1 }) { Text("Credentials", fontSize = 12.sp, modifier = Modifier.padding(8.dp)) }
                    Tab(selected = activeTab == 2, onClick = { activeTab = 2 }) { Text("Advanced", fontSize = 12.sp, modifier = Modifier.padding(8.dp)) }
                }

                Spacer(modifier = Modifier.height(16.dp))

                errorText?.let {
                    Text(it, color = Color.Red, fontSize = 12.sp, modifier = Modifier.padding(bottom = 8.dp))
                }

                if (activeTab == 0) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Display Name (Unique)") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                        OutlinedTextField(value = host, onValueChange = { host = it }, label = { Text("IP Address / Hostname") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), singleLine = true)
                        OutlinedTextField(value = port, onValueChange = { port = it }, label = { Text("SSH Port") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true)

                        // Group label: pick an existing one (prevents typo-forked labels) or type a new one.
                        var groupMenuOpen by remember { mutableStateOf(false) }
                        Box {
                            OutlinedTextField(
                                value = group,
                                onValueChange = { group = it },
                                label = { Text("Group (optional)") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true,
                                trailingIcon = {
                                    IconButton(onClick = { groupMenuOpen = true }) {
                                        Icon(Icons.Filled.ArrowDropDown, contentDescription = "Pick existing group")
                                    }
                                }
                            )
                            DropdownMenu(expanded = groupMenuOpen, onDismissRequest = { groupMenuOpen = false }) {
                                existingGroups.forEach { g ->
                                    DropdownMenuItem(text = { Text(g) }, onClick = { group = g; groupMenuOpen = false })
                                }
                            }
                        }

                        Text("Accent color", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            OmniColors.namedColors.forEach { (cname, c) ->
                                Box(
                                    modifier = Modifier
                                        .size(28.dp)
                                        .clip(androidx.compose.foundation.shape.CircleShape)
                                        .background(c)
                                        .border(
                                            width = if (serverColor == cname) 3.dp else 0.dp,
                                            color = MaterialTheme.colorScheme.onSurface,
                                            shape = androidx.compose.foundation.shape.CircleShape,
                                        )
                                        .clickable { serverColor = cname }
                                )
                            }
                        }
                    }
                } else if (activeTab == 1) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        // Username lives with credentials; a selected profile overrides it.
                        OutlinedTextField(
                            value = user,
                            onValueChange = { user = it },
                            label = { Text("SSH Username") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            enabled = authType != "profile",
                            supportingText = if (authType == "profile") { { Text("Provided by the selected profile") } } else null,
                        )
                        @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                        androidx.compose.foundation.layout.FlowRow(
                            verticalArrangement = Arrangement.Center,
                            horizontalArrangement = Arrangement.spacedBy(16.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = authType == "password", onClick = { authType = "password" })
                                Text("Password")
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = authType == "key", onClick = { authType = "key" })
                                Text("SSH Private Key")
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                RadioButton(selected = authType == "profile", onClick = { authType = "profile" })
                                Text("Profile")
                            }
                        }

                        if (authType == "password") {
                            StoredSecretField(
                                value = password,
                                onValueChange = { password = it },
                                label = "SSH Password",
                                hasStored = hasStoredPassword,
                                forgetStored = forgetPassword,
                                onForgetStoredChange = { forgetPassword = it },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = saveProfile, onCheckedChange = { saveProfile = it })
                                Text("Save securely to Credential Store", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (saveProfile) {
                                Text("A new credentials profile will be built for this connection automatically.", fontSize = 11.sp, color = Color(0xFF10B981), modifier = Modifier.padding(start = 12.dp))
                            } else {
                                Text(
                                    "Either way the password is stored encrypted on this device so OmniTerm can reconnect; the Credential Store just makes it reusable across hosts.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 12.dp),
                                )
                            }
                        } else if (authType == "key") {
                            if (savedKeys.isEmpty()) {
                                Text("No SSH keys saved yet. Go to Tools → Keys to generate or import one.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                            } else {
                                Text("Select Keypair Alias:")
                                @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                                androidx.compose.foundation.layout.FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    savedKeys.forEach { key ->
                                        ElevatedFilterChip(
                                            selected = selectedKey == key.alias,
                                            onClick = { selectedKey = key.alias },
                                            label = { Text(key.alias) }
                                        )
                                    }
                                }
                            }
                        } else if (authType == "profile") {
                            if (savedProfiles.isEmpty()) {
                                Text("No credentials profiles found. Go to Tools -> Auth to create one or enter a raw password.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                            } else {
                                Text("Select Credentials Profile:")
                                LazyColumn(modifier = Modifier.height(100.dp)) {
                                    items(savedProfiles) { profile ->
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            modifier = Modifier.fillMaxWidth().clickable { selectedProfileId = profile.id }.padding(vertical = 4.dp)
                                        ) {
                                            RadioButton(selected = selectedProfileId == profile.id, onClick = null)
                                            Spacer(modifier = Modifier.width(8.dp))
                                            Column {
                                                Text(profile.profileName)
                                                Text("User: ${profile.username}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // REAL SSH connection + credential test (not just a TCP ping).
                        testResultText?.let {
                            Text(it, color = if (it == "Connection OK") Color(0xFF10B981) else Color.Red, fontSize = 12.sp)
                        }
                        Button(
                            onClick = {
                                testingConnection = true
                                testResultText = null
                                // Bind the eventual OK to the fields as they were when the test
                                // started — edits made while it runs still require a retest.
                                val signatureAtStart = connectionSignature()
                                viewModel.testConnectionDraft(
                                    host = host, port = port.toIntOrNull() ?: 22, username = user,
                                    authType = authType, password = effectivePassword(),
                                    keyAlias = selectedKey, profileId = selectedProfileId,
                                    proxyType = proxyType, proxyHost = proxyHost,
                                    proxyPort = proxyPort.toIntOrNull() ?: 0,
                                    proxyUser = proxyUser, proxyPassword = effectiveProxyPassword(),
                                    proxyKeyAlias = proxyKeyAlias.takeIf { it.isNotBlank() && proxyType == "ssh" },
                                ) { err ->
                                    testingConnection = false
                                    testResultText = err?.let { "Connection failed: $it" } ?: "Connection OK"
                                    if (err == null) testedOkSignature = signatureAtStart
                                }
                            },
                            modifier = Modifier.align(Alignment.End),
                            enabled = !testingConnection
                        ) {
                            if (testingConnection) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Text("Test Connection")
                            }
                        }
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Server Notes") }, modifier = Modifier.fillMaxWidth(), minLines = 2)
                        Text("Keep alive interval:")
                        val intervals = listOf("10s", "20s", "30s", "60s", "120s")
                        @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                        androidx.compose.foundation.layout.FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            intervals.forEach { item ->
                                FilterChip(
                                    selected = keepAlive == item.replace("s", ""),
                                    onClick = { keepAlive = item.replace("s", "") },
                                    label = { Text(item) }
                                )
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = compression, onCheckedChange = { compression = it })
                            Text("Use SSH Payload compression")
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = persistentSession, onCheckedChange = { persistentSession = it })
                            Column {
                                Text("Persistent session (tmux)")
                                Text(
                                    "Runs shells inside tmux so a dropped connection reconnects and " +
                                        "long-running commands keep going. Requires tmux on the host — " +
                                        "you'll be offered to install it on first connect.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = agentForwarding, onCheckedChange = { agentForwarding = it })
                            Column {
                                Text("Forward SSH agent (ssh -A)")
                                Text(
                                    "Lets onward SSH hops from this host authenticate with the key you " +
                                        "connect with, without copying it to the server. Only enable for hosts you trust.",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        StoredSecretField(
                            value = sudoPassword,
                            onValueChange = { sudoPassword = it },
                            label = "Sudo password (optional)",
                            hasStored = hasStoredSudoPassword,
                            forgetStored = forgetSudoPassword,
                            onForgetStoredChange = { forgetSudoPassword = it },
                            modifier = Modifier.fillMaxWidth(),
                        )

                        Spacer(Modifier.height(12.dp))
                        Text("Proxy / SSH jump", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                        androidx.compose.foundation.layout.FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.padding(vertical = 4.dp),
                        ) {
                            listOf("none" to "None", "http" to "HTTP", "socks5" to "SOCKS5", "ssh" to "SSH Jump").forEach { (key, label) ->
                                FilterChip(selected = proxyType == key, onClick = { proxyType = key }, label = { Text(label, fontSize = 11.sp) })
                            }
                        }
                        if (proxyType != "none") {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedTextField(value = proxyHost, onValueChange = { proxyHost = it }, label = { Text("Proxy host") }, modifier = Modifier.weight(2f), singleLine = true)
                                OutlinedTextField(value = proxyPort, onValueChange = { proxyPort = it.filter { c -> c.isDigit() } }, label = { Text("Port") }, modifier = Modifier.weight(1f), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                            }
                            Spacer(Modifier.height(8.dp))
                            OutlinedTextField(value = proxyUser, onValueChange = { proxyUser = it }, label = { Text(if (proxyType == "ssh") "Jump user (optional)" else "Proxy user (optional)") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                            Spacer(Modifier.height(8.dp))
                            StoredSecretField(
                                value = proxyPassword,
                                onValueChange = { proxyPassword = it },
                                label = if (proxyType == "ssh") "Jump password (optional)" else "Proxy password (optional)",
                                hasStored = hasStoredProxyPassword,
                                forgetStored = forgetProxyPassword,
                                onForgetStoredChange = { forgetProxyPassword = it },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            if (proxyType == "ssh") {
                                Spacer(Modifier.height(8.dp))
                                Text("Jump host key (optional):", fontSize = 12.sp)
                                if (savedKeys.isEmpty()) {
                                    Text("No SSH keys saved yet. Go to Tools → Keys to generate or import one.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
                                } else {
                                    @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                                    androidx.compose.foundation.layout.FlowRow(
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        verticalArrangement = Arrangement.spacedBy(4.dp),
                                    ) {
                                        savedKeys.forEach { key ->
                                            ElevatedFilterChip(
                                                selected = proxyKeyAlias == key.alias,
                                                // Tap again to deselect — key auth on the jump host is optional.
                                                onClick = { proxyKeyAlias = if (proxyKeyAlias == key.alias) "" else key.alias },
                                                label = { Text(key.alias) }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (activeTab < 2) {
                // Tabs 1 & 2 are mandatory steps → advance with Next (with light validation).
                Button(onClick = {
                    errorText = null
                    if (activeTab == 0) {
                        if (name.isBlank() || host.isBlank()) { errorText = "Name and host are required."; return@Button }
                        activeTab = 1
                    } else {
                        if (authType != "profile" && user.isBlank()) { errorText = "SSH username is required."; return@Button }
                        if (authType == "profile" && selectedProfileId == null) { errorText = "Select a credential profile."; return@Button }
                        if (authType == "key" && selectedKey.isBlank()) { errorText = "Select a key."; return@Button }
                        activeTab = 2
                    }
                }) { Text("Next") }
            } else {
                Button(
                    onClick = {
                        if (connectionSignature() != testedOkSignature) {
                            errorText = "Run Test Connection first — it verifies the login and lets you trust the server's host key, so the host can't end up saved but unable to connect."
                            activeTab = 1
                            return@Button
                        }
                        errorText = null
                        val duplicate = allServers.firstOrNull {
                            it.id != (serverToEdit?.id ?: 0) && it.host.equals(host.trim(), ignoreCase = true)
                        }
                        if (serverToEdit == null && duplicate != null) confirmDuplicateHost = duplicate else saveServerDraft()
                    }
                ) {
                    Text(if (serverToEdit != null) "Update Server" else "Save Server")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = { if (activeTab > 0) activeTab -= 1 else onDismiss() }) {
                Text(if (activeTab > 0) "Back" else "Cancel")
            }
        }
    )

    confirmDuplicateHost?.let { duplicate ->
        AlertDialog(
            onDismissRequest = { confirmDuplicateHost = null },
            title = { Text("Duplicate IP address") },
            text = {
                Text("Host ${duplicate.name} already uses ${duplicate.host}. You can still save this server if it intentionally uses a different credential profile.")
            },
            confirmButton = {
                Button(onClick = {
                    confirmDuplicateHost = null
                    saveServerDraft()
                }) { Text("Save anyway") }
            },
            dismissButton = {
                TextButton(onClick = { confirmDuplicateHost = null }) { Text("Review") }
            },
        )
    }
}
