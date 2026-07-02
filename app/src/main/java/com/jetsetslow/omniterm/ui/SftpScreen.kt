package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.data.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

@Composable
private fun CompactSftpIconButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier = modifier
            .size(36.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
        content = content,
    )
}

@Composable
private fun CompactSftpIconToggleButton(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    CompactSftpIconButton(
        onClick = { onCheckedChange(!checked) },
        modifier = modifier,
        content = content,
    )
}


@Composable
fun SftpScreen(viewModel: AppViewModel) {
    val srv = viewModel.selectedServer
    if (srv == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Please add a server first.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    LaunchedEffect(srv.id) { viewModel.ensureSftpLoadedForSelectedServer() }

    Column(modifier = Modifier.fillMaxSize()) {
        // Let the user switch hosts from SFTP itself (mirrors the other tabs).
        // The reset itself is driven by SftpFilesTab's LaunchedEffect on the selected host,
        // so here we only jump back to the FILES tab (avoids opening two SFTP sessions).
        ServerSelectorBar(viewModel, onServerChange = {
            viewModel.activeSftpTab = 0
        })
        TabRow(selectedTabIndex = viewModel.activeSftpTab) {
            Tab(selected = viewModel.activeSftpTab == 0, onClick = { viewModel.activeSftpTab = 0 }) { Text("Files", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(selected = viewModel.activeSftpTab == 1, onClick = { viewModel.activeSftpTab = 1 }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Transfers", fontSize = OmniTextSize.Dense)
                    if (viewModel.sftpTransfers.isNotEmpty()) {
                        Spacer(modifier = Modifier.width(6.dp))
                        Box(modifier = Modifier.size(16.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
                            Text("${viewModel.sftpTransfers.size}", fontSize = 10.sp, color = Color.White)
                        }
                    }
                }
            }
            Tab(selected = viewModel.activeSftpTab == 2, onClick = { viewModel.activeSftpTab = 2 }) { Text("Bookmarks", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(12.dp)
        ) {
            when (viewModel.activeSftpTab) {
                0 -> SftpFilesTab(viewModel)
                1 -> SftpTransfersTab(viewModel)
                2 -> SftpBookmarksTab(viewModel)
            }
        }
    }
}

@OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)
@Composable
fun SftpFilesTab(viewModel: AppViewModel) {
    val srv = viewModel.selectedServer ?: return
    val filesList = viewModel.sftpEntries
    val currentPath = viewModel.sftpPath.ifBlank { "~" }
    val selectionMode = viewModel.sftpSelectionMode
    val selectedRemoteFileNames = filesList
        .filter { it.name in viewModel.sftpSelected && !it.isDirectory }
        .map { it.name }
    val selectedRemoteFiles = filesList.filter { it.name in viewModel.sftpSelected && !it.isDirectory }
    val selectedRemoteBytes = selectedRemoteFiles.sumOf { it.size.coerceAtLeast(0L) }
    val largeBatchFileThreshold = viewModel.sftpLargeBatchFileThreshold
    val largeBatchBytesThreshold = viewModel.sftpLargeBatchBytesThreshold

    var showCreateFolderDialog by remember { mutableStateOf(false) }
    var folderNameInput by remember { mutableStateOf("") }
    var showSudoConfirmDialog by remember { mutableStateOf(false) }
    var sortMenuExpanded by remember { mutableStateOf(false) }
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current

    // Editable path bar: tap the path to type a destination and jump straight there.
    var editingPath by remember { mutableStateOf(false) }
    var pathInput by remember { mutableStateOf("") }

    // Entering sudo mode runs every file op as root, so it's gated behind device authentication.
    // The flow: warning dialog (unless dismissed) -> biometric/device-credential prompt -> on
    // success toggle sudo on. A PIN dialog is the fallback when the user has an app PIN.
    var pendingSudoAuth by remember { mutableStateOf(false) }
    var showSudoPinDialog by remember { mutableStateOf(false) }
    var sudoPin by remember { mutableStateOf("") }
    var sudoPinError by remember { mutableStateOf<String?>(null) }
    val authContext = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(pendingSudoAuth) {
        if (!pendingSudoAuth) return@LaunchedEffect
        val activity = authContext.getActivity()
        val canBiometric = activity != null
        if (canBiometric) {
            BiometricCryptoGate.authenticate(
                activity = activity,
                title = "Authenticate for sudo mode",
                subtitle = "Confirm to run SFTP operations as root",
                onAuthenticated = {
                    viewModel.toggleSftpSudo()
                    pendingSudoAuth = false
                },
                onUnavailable = {
                    pendingSudoAuth = false
                    if (viewModel.savedPin != null) { sudoPin = ""; sudoPinError = null; showSudoPinDialog = true }
                },
                onError = {
                    pendingSudoAuth = false
                    if (viewModel.savedPin != null) { sudoPin = ""; sudoPinError = null; showSudoPinDialog = true }
                },
            )
        } else {
            pendingSudoAuth = false
            if (viewModel.savedPin != null) { sudoPin = ""; sudoPinError = null; showSudoPinDialog = true }
        }
    }

    // Scroll the file list back to the top on every directory change. Without an explicit state,
    // Compose reuses the prior scroll offset because common entry names (bin, etc, var…) collide
    // across folders, leaving the new listing scrolled partway down.
    val fileListState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(viewModel.sftpPath) { fileListState.scrollToItem(0) }

    var showRenameDialog by remember { mutableStateOf<SftpFile?>(null) }
    var renameInput by remember { mutableStateOf("") }

    var selectedFileForOption by remember { mutableStateOf<SftpFile?>(null) }
    var pendingLargeDownloadConfirm by remember { mutableStateOf(false) }
    var pendingLargeUploadUris by remember { mutableStateOf<List<android.net.Uri>>(emptyList()) }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val coroutineScope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    // Auto-clear transient status banners (save confirmed, copied, moved…) after a few seconds.
    viewModel.sftpStatus?.let { msg ->
        LaunchedEffect(msg) {
            delay(4000)
            if (viewModel.sftpStatus == msg) viewModel.sftpStatus = null
        }
    }

    // Real download-to-device: remember which remote file the SAF picker is saving.
    var pendingDownloadName by remember { mutableStateOf<String?>(null) }
    val downloadLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.CreateDocument("*/*")
    ) { uri ->
        val name = pendingDownloadName
        if (uri != null && name != null) viewModel.sftpDownload(name, uri, context)
        pendingDownloadName = null
    }

    // Pick a file from the device and upload it into the current remote directory. OpenDocument
    // (Storage Access Framework) hands back a stable, readable content URI; the older GetContent
    // contract often returns URIs whose read grant is already gone by the time we open the stream,
    // which surfaced as a bogus "No such file" and a broken upload button.
    val uploadLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            fun proceed() {
                if (uris.size >= largeBatchFileThreshold) {
                    pendingLargeUploadUris = uris
                } else {
                    viewModel.sftpUploadMany(uris, context)
                }
            }
            // Uploads silently replace same-named remote files, so warn about collisions with the
            // current listing first. Best-effort: files whose display name can't be resolved are
            // uploaded under a generated unique name and can't collide.
            val existing = filesList.mapTo(mutableSetOf()) { it.name }
            val conflicts = uris
                .mapNotNull { contentDisplayName(context, it)?.substringAfterLast('/') }
                .filter { it in existing }
                .distinct()
            if (conflicts.isEmpty()) proceed()
            else confirm.ask(
                "Overwrite existing file(s)?",
                "Already in this folder and will be replaced: " +
                    conflicts.take(5).joinToString(", ") +
                    (if (conflicts.size > 5) " and ${conflicts.size - 5} more" else "") +
                    ". This cannot be undone.",
                confirmLabel = "Overwrite",
            ) { proceed() }
        }
    }

    var pendingFolderDownloadNames by remember { mutableStateOf<List<String>>(emptyList()) }
    val downloadFolderLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        val names = pendingFolderDownloadNames
        if (uri != null && names.isNotEmpty()) viewModel.sftpDownloadFilesToFolder(names, uri, context)
        pendingFolderDownloadNames = emptyList()
    }

    // Back exits selection mode first, then closes the search bar, then navigates up the tree.
    BackHandler(enabled = selectionMode || viewModel.sftpSearchActive || (viewModel.sftpPath.isNotEmpty() && viewModel.sftpPath != "/")) {
        when {
            selectionMode -> viewModel.sftpClearSelection()
            viewModel.sftpSearchActive -> viewModel.sftpSearchClear()
            else -> viewModel.sftpUp()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Breadcrumb / selection toolbar
        OmniCard(
            modifier = Modifier
                .fillMaxWidth()
                .padding(0.dp),
            leftAccent = if (selectionMode) OmniColors.cyan else OmniColors.amber
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                if (selectionMode) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                        IconButton(onClick = { viewModel.sftpClearSelection() }) {
                            Icon(Icons.Filled.Close, contentDescription = "Cancel selection")
                        }
                        Text(
                            "${viewModel.sftpSelected.size} selected",
                            fontFamily = OmniFonts.mono,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                    Row {
                        IconButton(onClick = { viewModel.sftpSelectAll() }) {
                            Icon(Icons.Filled.SelectAll, contentDescription = "Select all")
                        }
                        IconButton(
                            enabled = selectedRemoteFileNames.isNotEmpty(),
                            onClick = {
                                pendingFolderDownloadNames = selectedRemoteFileNames
                                if (selectedRemoteFileNames.size >= largeBatchFileThreshold || selectedRemoteBytes >= largeBatchBytesThreshold) {
                                    pendingLargeDownloadConfirm = true
                                } else {
                                    downloadFolderLauncher.launch(null)
                                }
                            }
                        ) {
                            Icon(Icons.Filled.Download, contentDescription = "Download selected files")
                        }
                        IconButton(onClick = { viewModel.sftpClipSelection(move = false) }) {
                            Icon(Icons.Filled.ContentCopy, contentDescription = "Copy")
                        }
                        IconButton(onClick = { viewModel.sftpClipSelection(move = true) }) {
                            Icon(Icons.Filled.ContentCut, contentDescription = "Cut")
                        }
                        IconButton(onClick = {
                            val count = viewModel.sftpSelected.size
                            confirm.ask(
                                "Delete $count item(s)?",
                                "Permanently delete the selected items from the remote host? This cannot be undone.",
                                confirmLabel = "Delete",
                            ) { viewModel.sftpDeleteSelected() }
                        }) {
                            Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = Color.Red)
                        }
                    }
                } else {
                  // Path gets its own full-width row (like an address box) above the action
                  // buttons, so it's always visible and never squeezed by the icon row, which would
                  // otherwise overflow with 8 buttons on a phone.
                  Column(modifier = Modifier.weight(1f)) {
                    if (editingPath) {
                        OutlinedTextField(
                            value = pathInput,
                            onValueChange = { pathInput = it },
                            singleLine = true,
                            textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 14.sp),
                            leadingIcon = { Icon(Icons.Filled.FolderOpen, contentDescription = null, tint = OmniColors.amber) },
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                            keyboardActions = KeyboardActions(onGo = {
                                val target = pathInput.trim()
                                if (target.isNotEmpty()) viewModel.loadSftp(target)
                                editingPath = false
                            }),
                            trailingIcon = {
                                Row {
                                    IconButton(onClick = {
                                        val target = pathInput.trim()
                                        if (target.isNotEmpty()) viewModel.loadSftp(target)
                                        editingPath = false
                                    }) { Icon(Icons.Filled.Check, contentDescription = "Go to path", tint = OmniColors.cyan) }
                                    IconButton(onClick = { editingPath = false }) {
                                        Icon(Icons.Filled.Close, contentDescription = "Cancel path edit")
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        // Tappable path box: full width, mono, click to edit and type a destination.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                                .clickable {
                                    pathInput = viewModel.sftpPath.ifBlank { "" }
                                    editingPath = true
                                }
                                .padding(horizontal = 10.dp, vertical = 8.dp),
                        ) {
                            Icon(Icons.Filled.FolderOpen, contentDescription = null, tint = OmniColors.amber, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(8.dp))
                            // Long paths: keep the path on one line but horizontally scrollable, and
                            // auto-scroll to the end so the current (deepest) folder — the part that
                            // matters — is what's visible by default. Tap anywhere to edit the full path.
                            val pathScroll = rememberScrollState()
                            LaunchedEffect(currentPath) { pathScroll.scrollTo(pathScroll.maxValue) }
                            Text(
                                text = currentPath,
                                fontFamily = OmniFonts.mono,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                softWrap = false,
                                modifier = Modifier
                                    .weight(1f)
                                    .horizontalScroll(pathScroll),
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Icon(Icons.Filled.Edit, contentDescription = "Edit path", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                        }
                    }

                    // Action buttons wrap only when the viewport is narrow, so the toolbar is not
                    // unnecessarily scrollable on normal widths.
                    if (!editingPath) Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Toolbar grouped left→right: navigate · view · create/transfer · modes.

                        // ── Navigate ──
                        CompactSftpIconButton(onClick = { viewModel.sftpHome() }) {
                            Icon(Icons.Filled.Home, contentDescription = "Go to home folder")
                        }
                        if (viewModel.sftpPath.isNotEmpty() && viewModel.sftpPath != "/") {
                            CompactSftpIconButton(onClick = { viewModel.sftpUp() }) {
                                Icon(Icons.Filled.ArrowUpward, contentDescription = "Go up")
                            }
                        }
                        CompactSftpIconButton(onClick = { viewModel.loadSftp(viewModel.sftpPath.ifBlank { null }) }) {
                            Icon(Icons.Filled.Refresh, contentDescription = "Reload")
                        }

                        // ── View ──
                        CompactSftpIconToggleButton(checked = viewModel.sftpSearchActive, onCheckedChange = {
                            if (viewModel.sftpSearchActive) viewModel.sftpSearchClear()
                            else viewModel.sftpSearchActive = true
                        }) {
                            Icon(
                                Icons.Filled.Search,
                                contentDescription = if (viewModel.sftpSearchActive) "Close search" else "Search this directory",
                                tint = if (viewModel.sftpSearchActive) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Box {
                            CompactSftpIconButton(onClick = { sortMenuExpanded = true }) {
                                Icon(
                                    Icons.AutoMirrored.Filled.Sort,
                                    contentDescription = "Sort files",
                                    tint = if (viewModel.sftpSortOption != SftpSortOption.NameAsc) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            DropdownMenu(
                                expanded = sortMenuExpanded,
                                onDismissRequest = { sortMenuExpanded = false },
                            ) {
                                SftpSortOption.entries.forEach { option ->
                                    DropdownMenuItem(
                                        text = { Text(option.label, fontSize = 13.sp) },
                                        leadingIcon = {
                                            if (viewModel.sftpSortOption == option) {
                                                Icon(Icons.Filled.Check, contentDescription = null, tint = OmniColors.cyan)
                                            }
                                        },
                                        onClick = {
                                            viewModel.chooseSftpSortOption(option)
                                            sortMenuExpanded = false
                                        },
                                    )
                                }
                            }
                        }
                        CompactSftpIconToggleButton(checked = viewModel.showSftpFolderSizes, onCheckedChange = { viewModel.toggleSftpFolderSizes() }) {
                            Icon(
                                Icons.Filled.Straighten,
                                contentDescription = if (viewModel.showSftpFolderSizes) "Hide folder sizes" else "Show folder sizes",
                                tint = if (viewModel.showSftpFolderSizes) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }

                        // ── Create / transfer ──
                        CompactSftpIconButton(onClick = { showCreateFolderDialog = true }) {
                            Icon(Icons.Filled.CreateNewFolder, contentDescription = "Create folder")
                        }
                        CompactSftpIconButton(onClick = { uploadLauncher.launch(arrayOf("*/*")) }) {
                            Icon(Icons.Filled.Upload, contentDescription = "Upload files")
                        }
                        CompactSftpIconButton(
                            enabled = viewModel.sftpEntries.isNotEmpty(),
                            onClick = { viewModel.sftpSelectAll() },
                        ) {
                            Icon(Icons.Filled.SelectAll, contentDescription = "Select all")
                        }

                        // ── Modes ──
                        CompactSftpIconToggleButton(checked = viewModel.sftpSudo, onCheckedChange = {
                            when {
                                // Turning sudo OFF needs no auth.
                                viewModel.sftpSudo -> viewModel.toggleSftpSudo()
                                // Turning sudo ON: warning first (unless dismissed), then auth.
                                !viewModel.sftpSudoConfirmDismissed -> showSudoConfirmDialog = true
                                else -> pendingSudoAuth = true
                            }
                        }) {
                            Icon(
                                Icons.Filled.AdminPanelSettings,
                                contentDescription = if (viewModel.sftpSudo) "Sudo mode on" else "Sudo mode off",
                                tint = if (viewModel.sftpSudo) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        run {
                            val bookmarked = viewModel.sftpPath.isNotBlank() && viewModel.sftpPath in viewModel.sftpBookmarks
                            CompactSftpIconButton(
                                enabled = viewModel.sftpPath.isNotBlank(),
                                onClick = {
                                    if (bookmarked) {
                                        viewModel.removeSftpBookmark(viewModel.sftpPath)
                                        viewModel.sftpStatus = "Bookmark removed"
                                    } else {
                                        viewModel.addSftpBookmark(viewModel.sftpPath)
                                        viewModel.sftpStatus = "Bookmarked ${viewModel.sftpPath}"
                                    }
                                },
                            ) {
                                Icon(
                                    if (bookmarked) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
                                    contentDescription = if (bookmarked) "Remove bookmark" else "Bookmark this directory",
                                    tint = if (bookmarked) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                  }
                }
            }
        }

        // Search bar — non-recursive filters the listing live; recursive runs `find` host-side.
        if (viewModel.sftpSearchActive && !selectionMode) {
            Spacer(modifier = Modifier.height(8.dp))
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column {
                    OutlinedTextField(
                        value = viewModel.sftpSearchQuery,
                        onValueChange = { viewModel.sftpSearchQuery = it },
                        placeholder = {
                            Text(
                                when {
                                    viewModel.sftpSearchWildcard -> "Glob pattern, e.g. *.conf"
                                    viewModel.sftpSearchRecursive -> "Search under $currentPath"
                                    else -> "Filter this folder"
                                },
                                fontSize = 13.sp,
                            )
                        },
                        singleLine = true,
                        textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 14.sp),
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        trailingIcon = {
                            if (viewModel.sftpSearchQuery.isNotEmpty()) {
                                IconButton(onClick = { viewModel.sftpSearchQuery = "" }) {
                                    Icon(Icons.Filled.Close, contentDescription = "Clear query")
                                }
                            }
                        },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = {
                            if (viewModel.sftpSearchRecursive) viewModel.runSftpSearch()
                        }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(modifier = Modifier.height(6.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FilterChip(
                            selected = viewModel.sftpSearchRecursive,
                            onClick = { viewModel.sftpSearchToggleRecursive() },
                            label = { Text("Recursive", fontSize = 12.sp) },
                        )
                        FilterChip(
                            selected = viewModel.sftpSearchWildcard,
                            onClick = { viewModel.sftpSearchWildcard = !viewModel.sftpSearchWildcard },
                            label = { Text("Wildcards * ?", fontSize = 12.sp) },
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        if (viewModel.sftpSearchRecursive) {
                            Button(
                                onClick = { viewModel.runSftpSearch() },
                                enabled = viewModel.sftpSearchQuery.isNotBlank() && !viewModel.sftpSearchRunning,
                            ) { Text("Search") }
                        }
                    }
                    if (viewModel.sftpSearchTruncated) {
                        Text(
                            "Showing first ${viewModel.sftpSearchResults?.size ?: 0} matches — narrow the pattern for more precision.",
                            fontSize = 11.sp,
                            color = OmniColors.amber,
                        )
                    }
                }
            }
        }

        if (pendingLargeDownloadConfirm) {
            AlertDialog(
                onDismissRequest = { pendingLargeDownloadConfirm = false },
                title = { Text("Large download selection") },
                text = {
                    Text(
                        "You selected ${selectedRemoteFileNames.size} file(s), about ${formatBytes(selectedRemoteBytes)}. " +
                            "This meets your configured large-transfer warning threshold. It downloads file-by-file into a folder without zipping. " +
                            "For reliability on slow links, consider smaller batches.",
                        fontSize = 14.sp,
                    )
                },
                confirmButton = {
                    Button(onClick = {
                        pendingLargeDownloadConfirm = false
                        downloadFolderLauncher.launch(null)
                    }) { Text("Continue") }
                },
                dismissButton = {
                    TextButton(onClick = { pendingLargeDownloadConfirm = false }) { Text("Cancel") }
                }
            )
        }

        if (pendingLargeUploadUris.isNotEmpty()) {
            AlertDialog(
                onDismissRequest = { pendingLargeUploadUris = emptyList() },
                title = { Text("Large upload batch") },
                text = {
                    Text(
                        "You selected ${pendingLargeUploadUris.size} file(s). They will upload one at a time so failures are isolated. " +
                            "This meets your configured large-transfer warning threshold. " +
                            "For very large batches, smaller groups are easier to retry.",
                        fontSize = 14.sp,
                    )
                },
                confirmButton = {
                    Button(onClick = {
                        val uris = pendingLargeUploadUris
                        pendingLargeUploadUris = emptyList()
                        viewModel.sftpUploadMany(uris, context)
                    }) { Text("Continue") }
                },
                dismissButton = {
                    TextButton(onClick = { pendingLargeUploadUris = emptyList() }) { Text("Cancel") }
                }
            )
        }

        // Sudo-mode notice — this elevates writes/deletes/copies, so make it unmistakable.
        if (viewModel.sftpSudo) {
            Spacer(modifier = Modifier.height(8.dp))
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.red) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.AdminPanelSettings, null, tint = OmniColors.red)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        "Sudo mode: edits, copy/move, and delete run as root",
                        fontSize = 12.sp,
                        fontFamily = OmniFonts.mono,
                    )
                }
            }
        }

        // Clipboard / paste bar — shown whenever something is staged to copy or move.
        if (viewModel.sftpClipboard.isNotEmpty()) {
            Spacer(modifier = Modifier.height(8.dp))
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                        Icon(
                            if (viewModel.sftpClipboardIsMove) Icons.Filled.ContentCut else Icons.Filled.ContentCopy,
                            contentDescription = null,
                            tint = OmniColors.green,
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            "${viewModel.sftpClipboard.size} item(s) ready to ${if (viewModel.sftpClipboardIsMove) "move" else "copy"}",
                            fontSize = 12.sp,
                            fontFamily = OmniFonts.mono,
                        )
                    }
                    if (viewModel.sftpPasteRunning) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Row {
                            TextButton(onClick = { viewModel.sftpClearClipboard() }) { Text("Clear") }
                            Button(onClick = {
                                // Paste runs `cp -a` / `mv -f` server-side, which silently replaces
                                // (or merges into) same-named entries in this folder — warn first.
                                val existing = viewModel.sftpEntries.mapTo(mutableSetOf()) { it.name }
                                val conflicts = viewModel.sftpClipboard
                                    .map { it.substringAfterLast('/') }
                                    .filter { it in existing }
                                    .distinct()
                                if (conflicts.isEmpty()) viewModel.sftpPaste()
                                else confirm.ask(
                                    "Overwrite existing item(s)?",
                                    "Already in this folder and will be replaced (folders are merged): " +
                                        conflicts.take(5).joinToString(", ") +
                                        (if (conflicts.size > 5) " and ${conflicts.size - 5} more" else "") +
                                        ". This cannot be undone.",
                                    confirmLabel = "Overwrite",
                                ) { viewModel.sftpPaste() }
                            }) {
                                Icon(Icons.Filled.ContentPaste, null)
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Paste here")
                            }
                        }
                    }
                }
            }
        }

        // Transient success/info banner (save confirmed, copied, moved, deleted…).
        viewModel.sftpStatus?.let {
            Spacer(modifier = Modifier.height(8.dp))
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = OmniColors.green)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(it, fontSize = 12.sp, fontFamily = OmniFonts.mono)
                }
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        viewModel.sftpError?.let {
            Text(it, color = Color.Red, fontSize = 12.sp, fontFamily = OmniFonts.mono, modifier = Modifier.padding(bottom = 6.dp))
        }

        // Live filter of the current listing (non-recursive search). Recursive results render
        // separately below because they're full paths, not entries of this folder.
        val searchQuery = viewModel.sftpSearchQuery.trim()
        val filterActive = viewModel.sftpSearchActive && !viewModel.sftpSearchRecursive &&
            !selectionMode && searchQuery.isNotEmpty()
        val displayedFiles = when {
            !filterActive -> filesList
            viewModel.sftpSearchWildcard -> {
                val rx = globToRegex(searchQuery)
                filesList.filter { rx.matches(it.name) }
            }
            else -> filesList.filter { it.name.contains(searchQuery, ignoreCase = true) }
        }
        val searchResults = viewModel.sftpSearchResults
        val showRecursiveResults = viewModel.sftpSearchActive && viewModel.sftpSearchRecursive && !selectionMode

        // Files listing grid
        if (showRecursiveResults && viewModel.sftpSearchRunning) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(modifier = Modifier.height(8.dp))
                    Text("Searching $currentPath…", fontSize = 12.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else if (showRecursiveResults && searchResults != null) {
            if (searchResults.isEmpty()) {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text("No matches under $currentPath", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    items(searchResults, key = { it.path }) { hit ->
                        OmniCard(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    // Folders open in place; files open their parent folder, so the
                                    // hit is visible in a normal listing with all actions available.
                                    val target = if (hit.isDirectory) hit.path
                                    else hit.path.substringBeforeLast('/').ifEmpty { "/" }
                                    viewModel.loadSftp(target)
                                }
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = if (hit.isDirectory) Icons.Filled.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                                    contentDescription = null,
                                    tint = if (hit.isDirectory) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column {
                                    Text(
                                        hit.path.removePrefix(if (currentPath == "/") "/" else "$currentPath/"),
                                        fontWeight = FontWeight.Bold,
                                        fontFamily = OmniFonts.mono,
                                        fontSize = 13.sp,
                                    )
                                    Text(
                                        if (hit.isDirectory) "Folder · tap to open" else "File · tap to open its folder",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } else if (showRecursiveResults) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text(
                    "Type a ${if (viewModel.sftpSearchWildcard) "pattern" else "name"} and hit Search to scan under $currentPath",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                )
            }
        } else if (viewModel.sftpLoading && filesList.isEmpty()) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else if (filesList.isEmpty()) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("Empty Directory", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else if (displayedFiles.isEmpty()) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("No matches in this folder", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                state = fileListState,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                items(displayedFiles, key = { it.name }) { file ->
                    val isSelected = file.name in viewModel.sftpSelected
                    OmniCard(
                        leftAccent = if (isSelected) OmniColors.cyan else null,
                        modifier = Modifier
                            .fillMaxWidth()
                            .combinedClickable(
                                onClick = {
                                    when {
                                        selectionMode -> viewModel.sftpToggleSelect(file.name)
                                        file.isDirectory -> viewModel.sftpCd(file.name)
                                        else -> selectedFileForOption = file
                                    }
                                },
                                onLongClick = { viewModel.sftpToggleSelect(file.name) },
                            )
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(0.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                                if (selectionMode) {
                                    Icon(
                                        imageVector = if (isSelected) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                                        contentDescription = null,
                                        tint = if (isSelected) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Spacer(modifier = Modifier.width(8.dp))
                                }
                                Icon(
                                    imageVector = if (file.isDirectory) Icons.Filled.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                                    contentDescription = null,
                                    tint = if (file.isDirectory) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column {
                                    Text(file.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 14.sp)
                                    Text(
                                        text = "${if (file.isDirectory) "Folder" else "File"} · ${formatBytes(file.size)} · ${file.modDate}",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }

                            if (!selectionMode) {
                                IconButton(onClick = { selectedFileForOption = file }) {
                                    Icon(Icons.Filled.MoreVert, contentDescription = null)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Selected cell Actions popup drawer
        selectedFileForOption?.let { file ->
            AlertDialog(
                onDismissRequest = { selectedFileForOption = null },
                title = { Text(file.name, fontFamily = OmniFonts.mono) },
                text = {
                    Column(
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (!file.isDirectory) {
                            TextButton(
                                onClick = {
                                    pendingDownloadName = file.name
                                    selectedFileForOption = null
                                    downloadLauncher.launch(file.name)
                                }
                            ) {
                                Icon(Icons.Filled.Download, null)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Download to Device")
                            }
                            TextButton(
                                onClick = {
                                    selectedFileForOption = null
                                    viewModel.openSftpFileForEdit(file)
                                }
                            ) {
                                Icon(Icons.Filled.EditNote, null)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Edit Text File Configuration")
                            }
                        } else {
                            TextButton(
                                onClick = {
                                    selectedFileForOption = null
                                    val fullPath = viewModel.sftpPath.ifBlank { "" } + "/" + file.name
                                    viewModel.addSftpBookmark(fullPath.replace("//", "/"))
                                    viewModel.sftpStatus = "Bookmarked ${file.name}"
                                }
                            ) {
                                Icon(Icons.Filled.BookmarkAdd, null)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Bookmark Directory")
                            }
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                renameInput = file.name
                                showRenameDialog = file
                            }
                        ) {
                            Icon(Icons.Filled.DriveFileRenameOutline, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Rename node")
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                val fullPath = (viewModel.sftpPath.ifBlank { "" } + "/" + file.name).replace("//", "/")
                                clipboard.setText(androidx.compose.ui.text.AnnotatedString(fullPath))
                                viewModel.sftpStatus = "Path copied: $fullPath"
                            }
                        ) {
                            Icon(Icons.Filled.ContentCopy, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Copy ${if (file.isDirectory) "folder" else "file"} path")
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                viewModel.sftpSelected.clear()
                                viewModel.sftpSelected.add(file.name)
                                viewModel.sftpClipSelection(move = false)
                            }
                        ) {
                            Icon(Icons.Filled.FileCopy, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Copy")
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                viewModel.sftpSelected.clear()
                                viewModel.sftpSelected.add(file.name)
                                viewModel.sftpClipSelection(move = true)
                            }
                        ) {
                            Icon(Icons.Filled.ContentCut, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Cut")
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                confirm.ask(
                                    "Delete ${file.name}?",
                                    if (file.isDirectory)
                                        "Permanently delete this directory and its contents from the remote host? This cannot be undone."
                                    else
                                        "Permanently delete this file from the remote host? This cannot be undone.",
                                    confirmLabel = "Delete",
                                ) { viewModel.sftpDelete(file) }
                            }
                        ) {
                            Icon(Icons.Filled.Delete, null, tint = Color.Red)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Delete node", color = Color.Red)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { selectedFileForOption = null }) { Text("Dismiss") }
                }
            )
        }

        // NOTE: The full-screen text editor is hosted at the top level in MainAppScreen (above
        // the app Scaffold), not here. Rendering it inside this screen put it under the app
        // Scaffold's consumeWindowInsets(), which zeroed out the IME inset and pushed the editor's
        // action bar off-screen behind the keyboard. See SftpFileEditor + MainAppScreen.

        if (showSudoConfirmDialog) {
            var dontShowAgain by remember { mutableStateOf(false) }
            AlertDialog(
                onDismissRequest = { showSudoConfirmDialog = false },
                title = { Text("Enable sudo mode?") },
                text = {
                    Column {
                        Text("All file operations will run as root. Only enable this if you intend to edit protected system files.")
                        Spacer(Modifier.height(12.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = dontShowAgain, onCheckedChange = { dontShowAgain = it })
                            Spacer(Modifier.width(4.dp))
                            Text("Don't show again", fontSize = 13.sp)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        if (dontShowAgain) viewModel.sftpSudoConfirmDismissed = true
                        showSudoConfirmDialog = false
                        // Require device authentication before sudo actually turns on.
                        pendingSudoAuth = true
                    }) { Text("Authenticate", color = OmniColors.red) }
                },
                dismissButton = {
                    TextButton(onClick = { showSudoConfirmDialog = false }) { Text("Cancel") }
                },
            )
        }

        // PIN fallback when biometrics/device credential aren't available but an app PIN is set.
        if (showSudoPinDialog) {
            AlertDialog(
                onDismissRequest = { showSudoPinDialog = false },
                title = { Text("Enter PIN for sudo mode") },
                text = {
                    Column {
                        Text("Confirm your app PIN to run SFTP operations as root.", fontSize = 14.sp)
                        Spacer(Modifier.height(8.dp))
                        OutlinedTextField(
                            value = sudoPin,
                            onValueChange = { sudoPin = it; sudoPinError = null },
                            label = { Text("PIN") },
                            singleLine = true,
                            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        sudoPinError?.let { Text(it, color = OmniColors.red, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp)) }
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        val err = viewModel.verifyPinForSensitiveAction(sudoPin)
                        if (err == null) {
                            showSudoPinDialog = false
                            viewModel.toggleSftpSudo()
                        } else sudoPinError = err
                    }) { Text("Confirm") }
                },
                dismissButton = {
                    TextButton(onClick = { showSudoPinDialog = false }) { Text("Cancel") }
                },
            )
        }

        // Directory Creator Dialogue Box
        if (showCreateFolderDialog) {
            AlertDialog(
                onDismissRequest = { showCreateFolderDialog = false },
                title = { Text("Create Directory") },
                text = {
                    OutlinedTextField(
                        value = folderNameInput,
                        onValueChange = { folderNameInput = it },
                        label = { Text("Directory Name") },
                        modifier = Modifier.fillMaxWidth()
                    )
                },
                confirmButton = {
                    Button(
                        onClick = {
                            if (folderNameInput.isNotBlank()) {
                                viewModel.sftpMkdir(folderNameInput)
                                folderNameInput = ""
                                showCreateFolderDialog = false
                            }
                        }
                    ) {
                        Text("Create")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showCreateFolderDialog = false }) { Text("Cancel") }
                }
            )
        }

        // Renamer Dialog Box
        showRenameDialog?.let { renameFile ->
            AlertDialog(
                onDismissRequest = { showRenameDialog = null },
                title = { Text("Rename file") },
                text = {
                    OutlinedTextField(
                        value = renameInput,
                        onValueChange = { renameInput = it },
                        label = { Text("New Name") },
                        modifier = Modifier.fillMaxWidth()
                    )
                },
                confirmButton = {
                    Button(
                        onClick = {
                            if (renameInput.isNotBlank()) {
                                val newName = renameInput
                                showRenameDialog = null
                                // Renaming onto an existing name replaces that entry (`mv` semantics
                                // in sudo mode) — warn before clobbering.
                                val clobbers = newName != renameFile.name &&
                                    viewModel.sftpEntries.any { it.name == newName }
                                if (!clobbers) viewModel.sftpRename(renameFile, newName)
                                else confirm.ask(
                                    "Overwrite \"$newName\"?",
                                    "\"$newName\" already exists in this folder and will be replaced by the rename. This cannot be undone.",
                                    confirmLabel = "Overwrite",
                                ) { viewModel.sftpRename(renameFile, newName) }
                            }
                        }
                    ) {
                        Text("Rename")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showRenameDialog = null }) { Text("Cancel") }
                }
            )
        }
    }
}

@Composable
fun SftpTransfersTab(viewModel: AppViewModel) {
    var confirmClearTransfers by remember { mutableStateOf(false) }
    val hasRunningTransfers = viewModel.sftpTransfers.any { it.status == SftpTransferStatus.InProgress }
    if (viewModel.sftpTransfers.isEmpty()) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No transfers recorded this session.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    } else {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Text("Transfer Log Feed", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!hasRunningTransfers) {
                    Text("Clear logs", fontSize = 11.sp, color = Color.Red, modifier = Modifier.clickable { confirmClearTransfers = true })
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
            LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(viewModel.sftpTransfers, key = { it.id }) { item ->
                    val accent = when (item.status) {
                        SftpTransferStatus.Success -> OmniColors.green
                        SftpTransferStatus.Failure -> OmniColors.red
                        SftpTransferStatus.InProgress -> OmniColors.cyan
                    }
                    val progress = if (item.totalBytes > 0) {
                        (item.bytesTransferred.toFloat() / item.totalBytes.toFloat()).coerceIn(0f, 1f)
                    } else null
                    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accent) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(0.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    when {
                                        item.status == SftpTransferStatus.Failure -> Icons.Filled.Error
                                        item.status == SftpTransferStatus.Success -> Icons.Filled.CheckCircle
                                        item.direction == "Download" -> Icons.Filled.Downloading
                                        else -> Icons.Filled.Upload
                                    },
                                    contentDescription = null,
                                    tint = accent
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("${item.direction}: ${item.name}", fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(
                                        "${item.serverName} · ${item.message.ifBlank { item.remotePath }}",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                Text(
                                    when (item.status) {
                                        SftpTransferStatus.InProgress -> "Running"
                                        SftpTransferStatus.Success -> "Done"
                                        SftpTransferStatus.Failure -> "Failed"
                                    },
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = accent,
                                )
                            }
                            if (item.status == SftpTransferStatus.InProgress) {
                                Spacer(Modifier.height(8.dp))
                                if (progress != null) {
                                    LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth(), color = accent)
                                } else {
                                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = accent)
                                }
                                if (item.speedKbps > 0f) {
                                    Spacer(Modifier.height(4.dp))
                                    val speedStr = if (item.speedKbps >= 1024f) "${"%.1f".format(item.speedKbps / 1024f)} MB/s" else "${"%.0f".format(item.speedKbps)} KB/s"
                                    val etaStr = if (item.etaSeconds > 0) " · ETA ${item.etaSeconds}s" else ""
                                    Text(speedStr + etaStr, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            if (item.retryable) {
                                Spacer(Modifier.height(8.dp))
                                OmniButton("Retry", onClick = { viewModel.retrySftpTransfer(item) }, small = true, color = OmniColors.amber)
                            }
                        }
                    }
                }
            }
        }
    }

    if (confirmClearTransfers) {
        AlertDialog(
            onDismissRequest = { confirmClearTransfers = false },
            title = { Text("Clear transfer history?") },
            text = { Text("This clears completed transfer rows. Running transfers cannot be cleared.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.sftpTransfers.clear()
                        confirmClearTransfers = false
                    }
                ) { Text("Clear", color = Color.Red) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClearTransfers = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Full-screen remote text-file editor. Uses a plain [BasicTextField] (markedly cheaper than
 * OutlinedTextField for large buffers) over the entire screen so text is actually selectable and
 * scrollable on a phone. Save is explicit and verified by the ViewModel before the editor closes;
 * a dirty buffer prompts before discarding so edits are never lost to an accidental dismiss.
 */
@Composable
fun SftpFileEditor(
    file: SftpFile,
    saving: Boolean,
    error: String?,
    sudo: Boolean,
    onToggleSudo: () -> Unit,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
    confirm: ConfirmController,
    highlightLimit: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
) {
    var buffer by remember(file.name) { mutableStateOf(file.content) }
    val dirty = buffer != file.content
    val lineCount = remember(buffer) { buffer.count { it == '\n' } + 1 }

    fun attemptDismiss() {
        if (dirty) {
            confirm.ask(
                "Discard changes?",
                "You have unsaved edits to ${file.name}. Discard them?",
                confirmLabel = "Discard",
            ) { onDismiss() }
        } else onDismiss()
    }

    FullScreenCodeEditor(
        title = file.name,
        value = buffer,
        onValueChange = { buffer = it },
        onClose = { attemptDismiss() },
        onSave = { onSave(buffer) },
        subtitle = "$lineCount lines · ${buffer.length} chars" + if (sudo) " · sudo" else "",
        subtitleColor = if (sudo) OmniColors.red else null,
        dirty = dirty,
        saving = saving,
        canSave = dirty,
        error = error,
        saveLabel = if (sudo) "Save as root" else "Save & verify",
        language = remember(file.name) { languageForFileName(file.name) },
        highlightMaxChars = highlightLimit,
        topBarAction = {
            IconToggleButton(checked = sudo, onCheckedChange = { onToggleSudo() }) {
                Icon(
                    Icons.Filled.AdminPanelSettings,
                    contentDescription = if (sudo) "Save as root: on" else "Save as root: off",
                    tint = if (sudo) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
    )
}

@Composable
fun SftpBookmarksTab(viewModel: AppViewModel) {
    val bookmarks = viewModel.sftpBookmarks
    var newBookmarkPath by remember { mutableStateOf("") }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = newBookmarkPath,
                onValueChange = { newBookmarkPath = it },
                label = { Text("Enter path to bookmark") },
                modifier = Modifier.weight(1f)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Button(
                onClick = {
                    if (newBookmarkPath.isNotBlank()) {
                        viewModel.addSftpBookmark(newBookmarkPath.trim())
                        newBookmarkPath = ""
                    }
                }
            ) {
                Text("Add")
            }
        }

        Spacer(modifier = Modifier.height(4.dp))
        Text("Quick-access bookmarks", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(bookmarks) { bmk ->
                OmniCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (viewModel.selectedServer != null) {
                                viewModel.activeSftpTab = 0
                                viewModel.loadSftp(bmk)
                            }
                        }
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Filled.Bookmark, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            text = bmk,
                            fontFamily = OmniFonts.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 14.sp,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = {
                            confirm.ask("Remove Bookmark?", "Remove bookmark $bmk?", confirmLabel = "Remove") {
                                viewModel.removeSftpBookmark(bmk)
                            }
                        }) {
                            Icon(Icons.Filled.Delete, contentDescription = "Delete bookmark", tint = Color.Red)
                        }
                    }
                }
            }
        }
    }
}

/** Converts a glob (`*`/`?`) to a case-insensitive Regex; every other character is literal. */
private fun globToRegex(glob: String): Regex {
    val sb = StringBuilder()
    for (c in glob) when (c) {
        '*' -> sb.append(".*")
        '?' -> sb.append('.')
        else -> sb.append(Regex.escape(c.toString()))
    }
    return Regex(sb.toString(), RegexOption.IGNORE_CASE)
}

/** Resolves a content URI's display name (the filename an upload will use), or null if unknown. */
private fun contentDisplayName(context: android.content.Context, uri: android.net.Uri): String? =
    runCatching {
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    }.getOrNull()
