package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val onlineServers = servers.filter { it.status == "online" }
    val explicitlySelected = servers.find { it.id == viewModel.selectedServerId }
    val srv = explicitlySelected ?: onlineServers.firstOrNull()
    LaunchedEffect(srv?.id) {
        if (srv != null) {
            if (explicitlySelected == null && viewModel.selectedServerId != srv.id) {
                viewModel.selectedServerId = srv.id
            }
            viewModel.ensureSftpLoadedForSelectedServer()
        }
        // Only the SFTP subtab needs an online SSH host; Shares/Bookmarks/Transfers work without.
        else if (viewModel.activeSftpTab == 0) viewModel.activeSftpTab = 1
    }

    Column(modifier = Modifier.fillMaxSize()) {
        if (srv != null && viewModel.activeSftpTab == 0) {
            // The host picker belongs to the SFTP subtab only — Transfers and Bookmarks span every
            // endpoint and Shares has its own list, so a host bar there is misleading clutter.
            // The reset itself is driven by SftpFilesTab's LaunchedEffect on the selected host.
            ServerSelectorBar(viewModel, onlineOnly = true, onServerChange = {
                viewModel.activeSftpTab = 0
            })
        }
        // Subtab order groups the two browsing surfaces first (SFTP host, then network Shares),
        // Bookmarks as the jump list between them, and the Transfers activity log last.
        PrimaryTabRow(selectedTabIndex = viewModel.activeSftpTab) {
            Tab(selected = viewModel.activeSftpTab == 0, enabled = srv != null, onClick = { viewModel.activeSftpTab = 0 }) { Text("SFTP", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(selected = viewModel.activeSftpTab == 1, onClick = { viewModel.activeSftpTab = 1 }) { Text("Shares", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(selected = viewModel.activeSftpTab == 2, onClick = { viewModel.activeSftpTab = 2 }) { Text("Bookmarks", fontSize = OmniTextSize.Dense, modifier = Modifier.padding(vertical = 8.dp)) }
            Tab(selected = viewModel.activeSftpTab == 3, onClick = { viewModel.activeSftpTab = 3 }) {
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
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(12.dp)
        ) {
            when (viewModel.activeSftpTab) {
                0 -> if (srv != null) SftpFilesTab(viewModel) else NoOnlineSshHostMessage()
                1 -> NetworkSharesTab(viewModel)
                2 -> SftpBookmarksTab(viewModel)
                3 -> SftpTransfersTab(viewModel)
            }
        }
    }
}

@Composable
private fun NoOnlineSshHostMessage() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("No online SSH hosts available. Offline hosts reappear here after the next successful probe.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun NetworkSharesTab(viewModel: AppViewModel) {
    // A share is open in the file browser — the browser owns the tab until Back closes it.
    viewModel.browsingShare?.let { share ->
        ShareBrowserView(viewModel, share)
        return
    }
    val shares by viewModel.networkShares.collectAsStateWithLifecycle()
    val scannedHostsByIp = viewModel.hostScanResults.associateBy { it.ip }
    val credentialProfiles by viewModel.profiles.collectAsStateWithLifecycle()
    val credentialProfilesById = credentialProfiles.associateBy { it.id }
    var showDialog by remember { mutableStateOf(false) }
    var showScanDialog by remember { mutableStateOf(false) }
    var editingShare by remember { mutableStateOf<NetworkShareEntity?>(null) }
    val protocols = listOf("SMB", "FTP", "SFTP", "NFS", "WEBDAV", "CUSTOM")
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Network Shares", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Text(
                    "Saved SMB/FTP/SFTP/NFS/WebDAV profiles are separate from SSH hosts.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(onClick = {
                editingShare = null
                showDialog = true
            }) {
                Icon(Icons.Filled.Add, null)
                Spacer(Modifier.width(6.dp))
                Text("Add")
            }
        }

        Spacer(Modifier.height(12.dp))

        OutlinedButton(
            onClick = { showScanDialog = true },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Radar, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Scan LAN for shares", fontSize = 12.sp)
        }

        Spacer(Modifier.height(12.dp))

        if (shares.isEmpty()) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("No network shares saved yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(shares, key = { it.id }) { share ->
                    val authProfile = share.authProfileId?.let { credentialProfilesById[it] }
                    NetworkShareCard(
                        share = share,
                        scannedHost = scannedHostsByIp[share.address],
                        authLabel = when {
                            share.anonymous -> "anonymous"
                            authProfile != null -> "profile: ${authProfile.profileName}"
                            else -> listOf(share.workgroup, share.username).filter { it.isNotBlank() }.joinToString("\\").ifBlank { "credentials" }
                        },
                        browsable = viewModel.isShareBrowsable(share),
                        onBrowse = { viewModel.openShareBrowser(share) },
                        onTest = { viewModel.testNetworkShare(share) },
                        onEdit = {
                            editingShare = share
                            showDialog = true
                        },
                        onDelete = {
                            confirm.ask(
                                "Delete \"${share.name}\"?",
                                "Removes this saved share profile. Files on the share are not touched.",
                                confirmLabel = "Delete",
                            ) { viewModel.deleteNetworkShare(share) }
                        },
                    )
                }
            }
        }
    }

    if (showDialog) {
        NetworkShareDialog(
            initial = editingShare,
            protocols = protocols,
            credentialProfiles = credentialProfiles,
            defaultPort = { viewModel.defaultNetworkSharePort(it) },
            onDismiss = { showDialog = false },
            onSave = {
                viewModel.saveNetworkShare(it)
                showDialog = false
            },
        )
    }

    if (showScanDialog) {
        NetworkShareScanDialog(
            viewModel = viewModel,
            scannedHostsByIp = scannedHostsByIp,
            onDismiss = { showScanDialog = false },
            onConfigure = { hit ->
                editingShare = shareDraftFromScan(hit, anonymous = hit.protocol != "SFTP")
                showScanDialog = false
                showDialog = true
            },
            onSave = { hit ->
                viewModel.addNetworkShareFromScan(hit)
                if (hit.protocol !in setOf("SMB", "SFTP")) {
                    showScanDialog = false
                }
            },
        )
    }
}

@Composable
private fun NetworkShareScanDialog(
    viewModel: AppViewModel,
    scannedHostsByIp: Map<String, AppViewModel.ScannedHost>,
    onDismiss: () -> Unit,
    onConfigure: (NetworkShareScanHit) -> Unit,
    onSave: (NetworkShareScanHit) -> Unit,
) {
    val hits = viewModel.networkShareScanHits
    val scanning = viewModel.networkShareScanRunning

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("LAN share scan") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = viewModel.networkShareScanCidr,
                    onValueChange = { viewModel.networkShareScanCidr = it },
                    label = { Text("Subnet or host") },
                    placeholder = { Text("192.168.1.0/24 or nas.local") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    colors = omniTextFieldColors(),
                )
                Button(
                    onClick = { viewModel.scanNetworkShares() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !scanning,
                ) {
                    if (scanning) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Scanning shares")
                    } else {
                        Icon(Icons.Filled.Search, null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (hits.isEmpty()) "Scan LAN shares" else "Rescan LAN shares", fontSize = 12.sp)
                    }
                }
                // Protocol noise filter: e.g. drop WebDAV on networks where every printer
                // answers on 80/443. Persisted; at least one stays enabled.
                @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("SMB", "FTP", "SFTP", "NFS", "WEBDAV").forEach { proto ->
                        FilterChip(
                            selected = proto in viewModel.networkShareScanProtocols,
                            onClick = { viewModel.toggleShareScanProtocol(proto) },
                            enabled = !scanning,
                            label = { Text(proto, fontSize = 10.sp) },
                        )
                    }
                }
                Text(
                    "Probes SMB 445, FTP 21, SFTP 22, NFS 2049, WebDAV 80/443 — untick protocols to cut noise.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                viewModel.networkShareScanStatus?.let {
                    Text(it, fontSize = 12.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (!scanning && hits.isEmpty()) {
                    Text("No shares yet - run a scan.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(hits) { hit ->
                        NetworkShareScanHitRow(
                            hit = hit,
                            scannedHost = scannedHostsByIp[hit.address],
                            onClick = {
                                if (hit.protocol in setOf("SMB", "SFTP")) onConfigure(hit) else onSave(hit)
                            },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
private fun NetworkShareScanHitRow(
    hit: NetworkShareScanHit,
    scannedHost: AppViewModel.ScannedHost?,
    onClick: () -> Unit,
) {
    val hostLabel = scannedHost?.hostname?.takeIf { it.isNotBlank() } ?: hit.address
    // Enumerated SMB shares produce one hit per share on the same host:port — without the share
    // name the rows would be indistinguishable.
    val title = if (hit.sharePath.isNotBlank()) "$hostLabel · ${hit.protocol} · ${hit.sharePath}" else "$hostLabel · ${hit.protocol}"
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
            Icon(Icons.Filled.Lan, null, tint = OmniColors.green)
            Spacer(Modifier.width(8.dp))
            Column {
                Text(title, fontFamily = OmniFonts.mono, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Text("${hit.address}:${hit.port}", fontFamily = OmniFonts.mono, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        TextButton(onClick = onClick) {
            Text(if (hit.protocol in setOf("SMB", "SFTP")) "Configure" else "Save")
        }
    }
}

private fun shareDraftFromScan(hit: NetworkShareScanHit, anonymous: Boolean): NetworkShareEntity =
    NetworkShareEntity(
        name = hit.label,
        protocol = hit.protocol,
        address = hit.address,
        port = hit.port,
        sharePath = hit.sharePath,
        anonymous = anonymous,
        useHttps = hit.protocol == "WEBDAV" && (hit.port == 443 || hit.port == 8443),
        lastChecked = System.currentTimeMillis(),
        lastStatus = "online",
    )

@Composable
private fun NetworkShareCard(
    share: NetworkShareEntity,
    scannedHost: AppViewModel.ScannedHost?,
    authLabel: String,
    browsable: Boolean,
    onBrowse: () -> Unit,
    onTest: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val accent = shareProtocolColor(share.protocol)
    val hostLabel = scannedHost?.hostname?.takeIf { it.isNotBlank() } ?: share.address
    val shareName = share.sharePath.ifBlank { share.name }
    val availability = shareAvailabilityUi(share.lastStatus)
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accent) {
        Column(modifier = Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.FolderShared, null, tint = accent)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            share.name,
                            modifier = Modifier.weight(1f, fill = false),
                            fontWeight = FontWeight.Bold,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.width(8.dp))
                        Box(
                            modifier = Modifier
                                .size(9.dp)
                                .clip(RoundedCornerShape(50))
                                .background(availability.color),
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            availability.label,
                            fontSize = 11.sp,
                            color = availability.color,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text(hostLabel, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Row {
                    IconButton(onClick = onBrowse, enabled = browsable) {
                        Icon(
                            Icons.Filled.FolderOpen,
                            contentDescription = if (browsable) "Browse files" else "Browsing not supported for ${share.protocol}",
                            tint = if (browsable) accent else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                        )
                    }
                    IconButton(onClick = onTest) {
                        Icon(Icons.Filled.NetworkPing, contentDescription = "Test share")
                    }
                    IconButton(onClick = onEdit) {
                        Icon(Icons.Filled.Edit, contentDescription = "Edit share")
                    }
                    IconButton(onClick = onDelete) {
                        Icon(Icons.Filled.Delete, contentDescription = "Delete share", tint = Color.Red)
                    }
                }
            }
            Text(
                "$shareName · ${share.protocol} · $authLabel",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                shareUri(share),
                fontFamily = OmniFonts.mono,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (scannedHost != null) {
                val details = buildString {
                    append(scannedHost.mac.ifBlank { "MAC unavailable" })
                    if (scannedHost.vendor.isNotBlank()) append(" · ${scannedHost.vendor}")
                    if (scannedHost.openPorts.isNotEmpty()) append(" · ports ${scannedHost.openPorts.joinToString(", ")}")
                }
                Text(details, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

private data class ShareAvailabilityUi(val label: String, val color: Color)

private fun shareAvailabilityUi(status: String): ShareAvailabilityUi =
    when (status.lowercase(Locale.ROOT)) {
        "online", "available", "ok" -> ShareAvailabilityUi("Available", OmniColors.green)
        "checking", "testing" -> ShareAvailabilityUi("Checking", OmniColors.amber)
        "unreachable", "offline", "failed", "error" -> ShareAvailabilityUi("Unavailable", Color.Red)
        else -> ShareAvailabilityUi("Unknown", Color.Gray)
    }

/**
 * Full file browser for one saved network share (SMB/FTP/SFTP/WebDAV): navigation, mkdir, rename,
 * delete, device download/upload, and the cross-endpoint copy/paste clipboard shared with the
 * SFTP Files tab. Every mutating action is gated while it runs and confirms before overwriting
 * or deleting; transfers report live progress both inline and on the Transfers tab.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ShareBrowserView(viewModel: AppViewModel, share: NetworkShareEntity) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    var pendingDownloadName by remember { mutableStateOf<String?>(null) }
    val downloadLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.CreateDocument("*/*")
    ) { uri ->
        val name = pendingDownloadName
        if (uri != null && name != null) viewModel.shareDownload(name, uri, context)
        pendingDownloadName = null
    }
    // Same large-batch thresholds as the SFTP Files tab (the "SFTP Transfer Warnings" setting),
    // so a big multi-file upload/download warns identically on both browsers.
    val largeBatchFileThreshold = viewModel.sftpLargeBatchFileThreshold
    val largeBatchBytesThreshold = viewModel.sftpLargeBatchBytesThreshold
    var pendingLargeUploadUris by remember { mutableStateOf<List<android.net.Uri>>(emptyList()) }
    var pendingLargeDownloadConfirm by remember { mutableStateOf(false) }

    val uploadLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        fun proceed() {
            if (uris.size >= largeBatchFileThreshold) pendingLargeUploadUris = uris
            else viewModel.shareUploadMany(uris, context)
        }
        // Uploads silently replace same-named files on the share, so warn about collisions first.
        val existing = viewModel.shareEntries.mapTo(mutableSetOf()) { it.name }
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

    var showCreateFolderDialog by remember { mutableStateOf(false) }
    var folderNameInput by remember { mutableStateOf("") }
    var renameTarget by remember { mutableStateOf<SftpFile?>(null) }
    var renameInput by remember { mutableStateOf("") }
    var menuForName by remember { mutableStateOf<String?>(null) }
    var sortMenuExpanded by remember { mutableStateOf(false) }
    val copyToClipboard = rememberClipboardCopy()
    val selectionMode = viewModel.shareSelectionMode
    val selectedShareFiles = viewModel.shareEntries.filter { it.name in viewModel.shareSelected && !it.isDirectory }
    val selectedShareFileNames = selectedShareFiles.map { it.name }
    val selectedShareBytes = selectedShareFiles.sumOf { it.size.coerceAtLeast(0L) }

    // Batch download of selected share files into a SAF-picked folder.
    val downloadFolderLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri != null && selectedShareFileNames.isNotEmpty()) {
            viewModel.shareDownloadSelectedToFolder(selectedShareFileNames, uri, context)
        }
    }

    if (pendingLargeDownloadConfirm) {
        AlertDialog(
            onDismissRequest = { pendingLargeDownloadConfirm = false },
            title = { Text("Large download selection") },
            text = {
                Text(
                    "You selected ${selectedShareFileNames.size} file(s), about ${formatBytes(selectedShareBytes)}. " +
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
                    viewModel.shareUploadMany(uris, context)
                }) { Text("Continue") }
            },
            dismissButton = {
                TextButton(onClick = { pendingLargeUploadUris = emptyList() }) { Text("Cancel") }
            }
        )
    }

    // Auto-clear the transient success banner, mirroring the SFTP Files tab.
    viewModel.shareStatus?.let { msg ->
        LaunchedEffect(msg) {
            delay(4000)
            if (viewModel.shareStatus == msg) viewModel.shareStatus = null
        }
    }

    val atRoot = viewModel.sharePath.trim('/').isEmpty()
    // Back peels off state one layer at a time: selection → search → up a folder → close browser.
    BackHandler {
        when {
            selectionMode -> viewModel.shareClearSelection()
            viewModel.shareSearchActive -> viewModel.shareSearchClear()
            !atRoot -> viewModel.shareNavigateUp()
            else -> viewModel.closeShareBrowser()
        }
    }

    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(viewModel.sharePath) { listState.scrollToItem(0) }

    Column(modifier = Modifier.fillMaxSize()) {
        if (selectionMode) {
            // Selection toolbar: mirrors the SFTP Files tab (select-all, download, copy/cut, delete).
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { viewModel.shareClearSelection() }) {
                    Icon(Icons.Filled.Close, contentDescription = "Cancel selection")
                }
                Text(
                    "${viewModel.shareSelected.size} selected",
                    fontFamily = OmniFonts.mono, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { viewModel.shareSelectAll() }) {
                    Icon(Icons.Filled.SelectAll, contentDescription = "Select all")
                }
                IconButton(
                    enabled = selectedShareFileNames.isNotEmpty() && !viewModel.shareTransferRunning,
                    onClick = {
                        if (selectedShareFileNames.size >= largeBatchFileThreshold || selectedShareBytes >= largeBatchBytesThreshold) {
                            pendingLargeDownloadConfirm = true
                        } else {
                            downloadFolderLauncher.launch(null)
                        }
                    },
                ) { Icon(Icons.Filled.Download, contentDescription = "Download selected files") }
                IconButton(onClick = { viewModel.shareClipSelection(move = false) }) {
                    Icon(Icons.Filled.ContentCopy, contentDescription = "Copy")
                }
                IconButton(onClick = { viewModel.shareClipSelection(move = true) }) {
                    Icon(Icons.Filled.ContentCut, contentDescription = "Cut")
                }
                IconButton(
                    enabled = !viewModel.shareOpRunning,
                    onClick = {
                        val count = viewModel.shareSelected.size
                        confirm.ask(
                            "Delete $count item(s)?",
                            "Delete the selected items from the share? This cannot be undone.",
                            confirmLabel = "Delete",
                        ) { viewModel.shareDeleteSelected() }
                    },
                ) { Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = Color.Red) }
            }
        } else {
        // Header: back to the share list, identity, view/create/upload actions.
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { viewModel.closeShareBrowser() }) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to share list")
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(share.name, fontWeight = FontWeight.Bold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    shareUri(share),
                    fontFamily = OmniFonts.mono,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // Search toggle.
            IconButton(onClick = {
                if (viewModel.shareSearchActive) viewModel.shareSearchClear() else viewModel.shareSearchActive = true
            }) {
                Icon(
                    Icons.Filled.Search,
                    contentDescription = if (viewModel.shareSearchActive) "Close search" else "Search",
                    tint = if (viewModel.shareSearchActive) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // Sort menu.
            Box {
                IconButton(onClick = { sortMenuExpanded = true }) {
                    Icon(
                        Icons.AutoMirrored.Filled.Sort,
                        contentDescription = "Sort",
                        tint = if (viewModel.shareSortOption != SftpSortOption.NameAsc) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                DropdownMenu(expanded = sortMenuExpanded, onDismissRequest = { sortMenuExpanded = false }) {
                    SftpSortOption.entries.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.label, fontSize = 13.sp) },
                            leadingIcon = {
                                if (viewModel.shareSortOption == option) Icon(Icons.Filled.Check, null, tint = OmniColors.cyan)
                            },
                            onClick = { viewModel.chooseShareSortOption(option); sortMenuExpanded = false },
                        )
                    }
                }
            }
            IconButton(
                onClick = { viewModel.loadShareDir(viewModel.sharePath.ifBlank { null }) },
                enabled = !viewModel.shareLoading,
            ) { Icon(Icons.Filled.Refresh, contentDescription = "Refresh") }
            IconButton(
                enabled = viewModel.shareEntries.isNotEmpty(),
                onClick = { viewModel.shareSelectAll() },
            ) { Icon(Icons.Filled.SelectAll, contentDescription = "Select all") }
            IconButton(
                onClick = { folderNameInput = ""; showCreateFolderDialog = true },
                enabled = !viewModel.shareOpRunning && !viewModel.shareLoading,
            ) { Icon(Icons.Filled.CreateNewFolder, contentDescription = "New folder") }
            IconButton(
                onClick = { uploadLauncher.launch(arrayOf("*/*")) },
                enabled = !viewModel.shareTransferRunning,
            ) { Icon(Icons.Filled.UploadFile, contentDescription = "Upload files from device") }
        }

        // Search bar — non-recursive filters the listing live; recursive walks the tree.
        if (viewModel.shareSearchActive) {
            val currentDir = viewModel.sharePath.ifBlank { "/" }
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column {
                    OutlinedTextField(
                        value = viewModel.shareSearchQuery,
                        onValueChange = { viewModel.shareSearchQuery = it },
                        placeholder = {
                            Text(
                                when {
                                    viewModel.shareSearchWildcard -> "Glob pattern, e.g. *.conf"
                                    viewModel.shareSearchRecursive -> "Search under $currentDir"
                                    else -> "Filter this folder"
                                },
                                fontSize = 13.sp,
                            )
                        },
                        singleLine = true,
                        textStyle = TextStyle(fontFamily = OmniFonts.mono, fontSize = 14.sp),
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        trailingIcon = {
                            if (viewModel.shareSearchQuery.isNotEmpty()) {
                                IconButton(onClick = { viewModel.shareSearchQuery = "" }) {
                                    Icon(Icons.Filled.Close, contentDescription = "Clear query")
                                }
                            }
                        },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { if (viewModel.shareSearchRecursive) viewModel.runShareSearch() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        FilterChip(
                            selected = viewModel.shareSearchRecursive,
                            onClick = { viewModel.shareSearchToggleRecursive() },
                            label = { Text("Recursive", fontSize = 12.sp) },
                        )
                        FilterChip(
                            selected = viewModel.shareSearchWildcard,
                            onClick = { viewModel.shareSearchWildcard = !viewModel.shareSearchWildcard },
                            label = { Text("Wildcards * ?", fontSize = 12.sp) },
                        )
                        Spacer(Modifier.weight(1f))
                        if (viewModel.shareSearchRecursive) {
                            Button(
                                onClick = { viewModel.runShareSearch() },
                                enabled = viewModel.shareSearchQuery.isNotBlank() && !viewModel.shareSearchRunning,
                            ) { Text("Search") }
                        }
                    }
                    if (viewModel.shareSearchTruncated) {
                        Text(
                            "Showing first ${viewModel.shareSearchResults?.size ?: 0} matches — narrow the pattern.",
                            fontSize = 11.sp, color = OmniColors.amber,
                        )
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }

        // Path bar with Up navigation and the listing spinner.
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { viewModel.shareNavigateUp() }, enabled = !atRoot && !viewModel.shareLoading) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = "Up one folder")
            }
            Text(
                viewModel.sharePath.ifBlank { "/" },
                fontFamily = OmniFonts.mono,
                fontSize = 12.sp,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // Star the current folder — mirrors the SFTP Files tab; lands in the Bookmarks tab.
            val currentDir = viewModel.sharePath.ifBlank { "/" }
            val bookmarked = currentDir in viewModel.shareBookmarks
            IconButton(onClick = {
                if (bookmarked) {
                    viewModel.removeShareBookmark(currentDir)
                    viewModel.shareStatus = "Bookmark removed"
                } else {
                    viewModel.addShareBookmark(currentDir)
                }
            }) {
                Icon(
                    if (bookmarked) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
                    contentDescription = if (bookmarked) "Remove bookmark" else "Bookmark this folder",
                    tint = if (bookmarked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (viewModel.shareLoading || viewModel.shareOpRunning) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
        }
        } // end non-selection header block

        // Error banner with retry — connection/auth problems must be visible and recoverable.
        viewModel.shareError?.let { err ->
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.red) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.ErrorOutline, null, tint = OmniColors.red)
                    Spacer(Modifier.width(8.dp))
                    Text(err, fontSize = 12.sp, fontFamily = OmniFonts.mono, modifier = Modifier.weight(1f))
                    TextButton(onClick = { viewModel.loadShareDir(viewModel.sharePath.ifBlank { null }) }) { Text("Retry") }
                }
            }
            Spacer(Modifier.height(8.dp))
        }

        // Transient success banner.
        viewModel.shareStatus?.let {
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = OmniColors.green)
                    Spacer(Modifier.width(8.dp))
                    Text(it, fontSize = 12.sp, fontFamily = OmniFonts.mono)
                }
            }
            Spacer(Modifier.height(8.dp))
        }

        // Cross-endpoint clipboard bar — paste files copied here, in another share, or in SFTP.
        if (viewModel.crossClipboard.isNotEmpty()) {
            CrossClipboardBar(
                viewModel = viewModel,
                existingNames = viewModel.shareEntries.map { it.name },
                confirm = confirm,
                onPaste = { viewModel.pasteIntoShare() },
            )
            Spacer(Modifier.height(8.dp))
        }

        // Live aggregate progress for this share's in-flight transfers (files + total size,
        // Windows-style). A recursive folder paste also shows the file currently being copied.
        val hasActive = viewModel.sftpTransfers.any {
            it.serverId == -share.id && it.status == SftpTransferStatus.InProgress
        }
        // Cross-endpoint pastes into this share are logged under endpointId 0 (mixed source),
        // so surface those too whenever a cross paste is running while this browser is open.
        if (hasActive || viewModel.crossPasteRunning) {
            TransferAggregateBar(viewModel, endpointId = if (viewModel.crossPasteRunning) null else -share.id)
            viewModel.crossPasteProgress?.let { current ->
                Text(
                    "Copying: $current",
                    fontSize = 10.sp,
                    fontFamily = OmniFonts.mono,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
        }

        // Live folder filter (non-recursive search) applied to the current listing.
        val searchQuery = viewModel.shareSearchQuery.trim()
        val filterActive = viewModel.shareSearchActive && !viewModel.shareSearchRecursive &&
            !selectionMode && searchQuery.isNotEmpty()
        val displayedFiles = when {
            !filterActive -> viewModel.shareEntries
            viewModel.shareSearchWildcard -> {
                val rx = globToRegex(searchQuery)
                viewModel.shareEntries.filter { rx.matches(it.name) }
            }
            else -> viewModel.shareEntries.filter { it.name.contains(searchQuery, ignoreCase = true) }
        }
        val showRecursiveResults = viewModel.shareSearchActive && viewModel.shareSearchRecursive && !selectionMode
        val recursiveResults = viewModel.shareSearchResults
        val currentDir = viewModel.sharePath.ifBlank { "/" }

        // The listing itself.
        when {
            showRecursiveResults && viewModel.shareSearchRunning -> {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator()
                        Spacer(Modifier.height(8.dp))
                        Text("Searching $currentDir…", fontSize = 12.sp, fontFamily = OmniFonts.mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            showRecursiveResults && recursiveResults != null -> {
                if (recursiveResults.isEmpty()) {
                    Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                        Text("No matches under $currentDir", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(recursiveResults, key = { it.path }) { hit ->
                            OmniCard(
                                modifier = Modifier.fillMaxWidth().clickable {
                                    val target = if (hit.isDirectory) hit.path else hit.path.substringBeforeLast('/').ifEmpty { "/" }
                                    viewModel.loadShareDir(target)
                                }
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        if (hit.isDirectory) Icons.Filled.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                                        null,
                                        tint = if (hit.isDirectory) shareProtocolColor(share.protocol) else MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Column {
                                        Text(
                                            hit.path.removePrefix(if (currentDir == "/") "/" else "$currentDir/"),
                                            fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 13.sp,
                                        )
                                        Text(
                                            if (hit.isDirectory) "Folder · tap to open" else "File · tap to open its folder",
                                            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            showRecursiveResults -> {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text(
                        "Type a ${if (viewModel.shareSearchWildcard) "pattern" else "name"} and hit Search to scan under $currentDir",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp,
                    )
                }
            }
            viewModel.shareLoading && viewModel.shareEntries.isEmpty() -> {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            viewModel.shareEntries.isEmpty() -> {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text(
                        if (viewModel.shareError != null) "Could not open this folder." else "Empty folder.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            displayedFiles.isEmpty() -> {
                Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text("No matches in this folder", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            else -> {
                LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f), state = listState) {
                    items(displayedFiles, key = { it.name }) { file ->
                        val isSelected = file.name in viewModel.shareSelected
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(if (isSelected) OmniColors.cyanDim else Color.Transparent)
                                .combinedClickable(
                                    onClick = {
                                        when {
                                            selectionMode -> viewModel.shareToggleSelect(file.name)
                                            file.isDirectory && !viewModel.shareLoading -> viewModel.shareNavigateInto(file.name)
                                            !file.isDirectory -> menuForName = file.name
                                        }
                                    },
                                    onLongClick = { viewModel.shareToggleSelect(file.name) },
                                )
                                .padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (selectionMode) {
                                Icon(
                                    if (isSelected) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                                    null,
                                    tint = if (isSelected) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(Modifier.width(8.dp))
                            }
                            Icon(
                                if (file.isDirectory) Icons.Filled.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                                null,
                                tint = if (file.isDirectory) shareProtocolColor(share.protocol) else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Spacer(Modifier.width(10.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(file.name, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    listOfNotNull(
                                        if (file.isDirectory) null else formatBytes(file.size),
                                        file.modDate.takeIf { it.isNotBlank() },
                                    ).joinToString(" · ").ifBlank { "folder" },
                                    fontSize = 10.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            if (!selectionMode) Box {
                                IconButton(onClick = { menuForName = file.name }) {
                                    Icon(Icons.Filled.MoreVert, contentDescription = "Actions for ${file.name}")
                                }
                                DropdownMenu(
                                    expanded = menuForName == file.name,
                                    onDismissRequest = { menuForName = null },
                                ) {
                                    if (!file.isDirectory) {
                                        DropdownMenuItem(
                                            text = { Text("Edit text file") },
                                            leadingIcon = { Icon(Icons.Filled.EditNote, null) },
                                            onClick = { menuForName = null; viewModel.openShareFileForEdit(file) },
                                        )
                                    }
                                    DropdownMenuItem(
                                        text = { Text("Copy") },
                                        leadingIcon = { Icon(Icons.Filled.ContentCopy, null) },
                                        onClick = { menuForName = null; viewModel.shareClipFile(file, move = false) },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Cut") },
                                        leadingIcon = { Icon(Icons.Filled.ContentCut, null) },
                                        onClick = { menuForName = null; viewModel.shareClipFile(file, move = true) },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Copy path") },
                                        leadingIcon = { Icon(Icons.Filled.ContentCopy, null) },
                                        onClick = {
                                            menuForName = null
                                            val full = (viewModel.sharePath.ifBlank { "" } + "/" + file.name).replace("//", "/")
                                            copyToClipboard(full)
                                            viewModel.shareStatus = "Path copied: $full"
                                        },
                                    )
                                    if (!file.isDirectory) {
                                        DropdownMenuItem(
                                            text = { Text("Download to device") },
                                            leadingIcon = { Icon(Icons.Filled.Download, null) },
                                            enabled = !viewModel.shareTransferRunning,
                                            onClick = {
                                                menuForName = null
                                                pendingDownloadName = file.name
                                                downloadLauncher.launch(file.name)
                                            },
                                        )
                                    }
                                    DropdownMenuItem(
                                        text = { Text("Rename") },
                                        leadingIcon = { Icon(Icons.Filled.DriveFileRenameOutline, null) },
                                        enabled = !viewModel.shareOpRunning,
                                        onClick = {
                                            menuForName = null
                                            renameInput = file.name
                                            renameTarget = file
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Delete", color = Color.Red) },
                                        leadingIcon = { Icon(Icons.Filled.Delete, null, tint = Color.Red) },
                                        enabled = !viewModel.shareOpRunning,
                                        onClick = {
                                            menuForName = null
                                            confirm.ask(
                                                "Delete \"${file.name}\"?",
                                                if (file.isDirectory) "Deletes this folder on the share (must be empty on most servers). This cannot be undone."
                                                else "Deletes this file on the share. This cannot be undone.",
                                                confirmLabel = "Delete",
                                            ) { viewModel.shareDelete(file) }
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showCreateFolderDialog) {
        AlertDialog(
            onDismissRequest = { showCreateFolderDialog = false },
            title = { Text("New folder") },
            text = {
                OutlinedTextField(
                    value = folderNameInput,
                    onValueChange = { folderNameInput = it },
                    label = { Text("Folder name") },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                )
            },
            confirmButton = {
                Button(
                    enabled = folderNameInput.isNotBlank() && !folderNameInput.contains('/'),
                    onClick = {
                        viewModel.shareMkdir(folderNameInput)
                        showCreateFolderDialog = false
                    },
                ) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { showCreateFolderDialog = false }) { Text("Cancel") } },
        )
    }

    renameTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename \"${target.name}\"") },
            text = {
                OutlinedTextField(
                    value = renameInput,
                    onValueChange = { renameInput = it },
                    label = { Text("New name") },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                )
            },
            confirmButton = {
                Button(
                    enabled = renameInput.isNotBlank() && !renameInput.contains('/') && renameInput != target.name,
                    onClick = {
                        viewModel.shareRename(target, renameInput)
                        renameTarget = null
                    },
                ) { Text("Rename") }
            },
            dismissButton = { TextButton(onClick = { renameTarget = null }) { Text("Cancel") } },
        )
    }
}

/**
 * The shared paste bar for the cross-endpoint clipboard. Shows what's staged and from where,
 * warns about same-named entries at the destination, and gates itself while a paste runs.
 */
@Composable
private fun CrossClipboardBar(
    viewModel: AppViewModel,
    existingNames: List<String>,
    confirm: ConfirmController,
    onPaste: () -> Unit,
) {
    val hasFolders = viewModel.crossClipboard.any { it.isDirectory }
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.green) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                    Icon(
                        if (viewModel.crossClipboardIsMove) Icons.Filled.ContentCut else Icons.Filled.ContentCopy,
                        contentDescription = null,
                        tint = OmniColors.green,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Column {
                        Text(
                            "${viewModel.crossClipboard.size} item(s) ready to ${if (viewModel.crossClipboardIsMove) "move" else "copy"}",
                            fontSize = 12.sp,
                            fontFamily = OmniFonts.mono,
                        )
                        Text(
                            "from ${viewModel.crossClipboard.map { it.sourceLabel }.distinct().joinToString(", ")}",
                            fontSize = 10.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (viewModel.crossPasteRunning) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Row {
                        TextButton(onClick = { viewModel.sftpClearClipboard() }) { Text("Clear") }
                        Button(onClick = {
                            // Same large-transfer thresholds as uploads/downloads: a cross-endpoint
                            // paste streams every byte through this device, so it deserves the same
                            // heads-up. Runs after the (destructive) overwrite confirm when both apply.
                            val totalBytes = viewModel.crossClipboard.sumOf { if (it.isDirectory) 0L else it.size.coerceAtLeast(0L) }
                            fun pasteWithSizeGate() {
                                val large = viewModel.crossClipboard.size >= viewModel.sftpLargeBatchFileThreshold ||
                                    totalBytes >= viewModel.sftpLargeBatchBytesThreshold
                                if (!large) { onPaste(); return }
                                confirm.ask(
                                    "Large paste",
                                    "You're pasting ${viewModel.crossClipboard.size} item(s), about ${formatBytes(totalBytes)}" +
                                        (if (hasFolders && viewModel.crossPasteRecurseFolders) " plus folder contents" else "") +
                                        ". This meets your configured large-transfer warning threshold; files stream one at a time through this device.",
                                    confirmLabel = "Paste",
                                    destructive = false,
                                ) { onPaste() }
                            }
                            val conflicts = viewModel.crossClipboard
                                .map { it.name }
                                .filter { it in existingNames }
                                .distinct()
                            if (conflicts.isEmpty()) pasteWithSizeGate()
                            else confirm.ask(
                                "Overwrite existing item(s)?",
                                "Already in this folder and will be replaced: " +
                                    conflicts.take(5).joinToString(", ") +
                                    (if (conflicts.size > 5) " and ${conflicts.size - 5} more" else "") +
                                    ". This cannot be undone.",
                                confirmLabel = "Overwrite",
                            ) { pasteWithSizeGate() }
                        }) {
                            Icon(Icons.Filled.ContentPaste, null)
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Paste here")
                        }
                    }
                }
            }
            // Folders in a cross-endpoint paste are copied file-by-file, which is slower and moves
            // more data — off by default, opt in here. Only shown when the clipboard has folders.
            if (hasFolders && !viewModel.crossPasteRunning) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
                    Checkbox(
                        checked = viewModel.crossPasteRecurseFolders,
                        onCheckedChange = { viewModel.toggleCrossPasteRecurseFolders(it) },
                    )
                    Text(
                        "Include folders (copy their contents recursively)",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NetworkShareDialog(
    initial: NetworkShareEntity?,
    protocols: List<String>,
    credentialProfiles: List<CredentialProfileEntity>,
    defaultPort: (String) -> Int,
    onDismiss: () -> Unit,
    onSave: (NetworkShareEntity) -> Unit,
) {
    var name by remember(initial) { mutableStateOf(initial?.name.orEmpty()) }
    var protocol by remember(initial) { mutableStateOf(initial?.protocol ?: "SMB") }
    var address by remember(initial) { mutableStateOf(initial?.address.orEmpty()) }
    var portText by remember(initial) { mutableStateOf((initial?.port ?: defaultPort(protocol)).toString()) }
    var sharePath by remember(initial) { mutableStateOf(initial?.sharePath.orEmpty()) }
    var workgroup by remember(initial) { mutableStateOf(initial?.workgroup.orEmpty()) }
    var username by remember(initial) { mutableStateOf(initial?.username.orEmpty()) }
    var password by remember(initial) { mutableStateOf(initial?.password.orEmpty()) }
    var authProfileId by remember(initial) { mutableStateOf(initial?.authProfileId) }
    var anonymous by remember(initial) { mutableStateOf(initial?.anonymous ?: true) }
    var useHttps by remember(initial) { mutableStateOf(initial?.useHttps ?: (protocol == "WEBDAV")) }
    var notes by remember(initial) { mutableStateOf(initial?.notes.orEmpty()) }
    var menuExpanded by remember { mutableStateOf(false) }
    var errorText by remember(initial) { mutableStateOf<String?>(null) }

    fun validateDraft(): String? {
        val normalizedProtocol = protocol.uppercase(Locale.ROOT)
        val port = portText.toIntOrNull()
        return when {
            address.isBlank() -> "Address is required."
            normalizedProtocol != "CUSTOM" && (port == null || port !in 1..65535) -> "Port must be between 1 and 65535."
            normalizedProtocol == "SMB" && sharePath.trim().trim('/').isBlank() ->
                "SMB needs a Share/path value such as Public or Media."
            normalizedProtocol == "SFTP" && anonymous ->
                "SFTP needs a username or credential profile."
            !anonymous && authProfileId == null && username.isBlank() ->
                "Username is required when anonymous login is off and no profile is selected."
            else -> null
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (initial == null) "Add network share" else "Edit network share") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Custom name") }, modifier = Modifier.fillMaxWidth(), singleLine = true, colors = omniTextFieldColors())
                ExposedDropdownMenuBox(
                    expanded = menuExpanded,
                    onExpandedChange = { menuExpanded = !menuExpanded },
                ) {
                    OutlinedTextField(
                        value = protocol,
                        onValueChange = {},
                        label = { Text("Protocol") },
                        modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
                        readOnly = true,
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menuExpanded) },
                        colors = omniTextFieldColors(),
                    )
                    ExposedDropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                        protocols.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option) },
                                onClick = {
                                    protocol = option
                                    portText = defaultPort(option).takeIf { it > 0 }?.toString().orEmpty()
                                    if (option == "SFTP") anonymous = false
                                    // Sensible TLS default when switching to WebDAV; still user-editable.
                                    if (option == "WEBDAV") useHttps = true
                                    menuExpanded = false
                                    errorText = null
                                },
                            )
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = address, onValueChange = { address = it }, label = { Text("Address") }, modifier = Modifier.weight(1f), singleLine = true, colors = omniTextFieldColors())
                    OutlinedTextField(
                        value = portText,
                        onValueChange = { portText = it.filter(Char::isDigit).take(5) },
                        label = { Text("Port") },
                        modifier = Modifier.width(96.dp),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = omniTextFieldColors(),
                    )
                }
                OutlinedTextField(value = sharePath, onValueChange = { sharePath = it }, label = { Text("Share/path") }, placeholder = { Text("SharedFolder or exports/media") }, modifier = Modifier.fillMaxWidth(), singleLine = true, colors = omniTextFieldColors())
                if (protocol == "WEBDAV") {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .padding(vertical = 4.dp)
                    ) {
                        Icon(Icons.Filled.Lock, contentDescription = null, tint = OmniColors.green)
                        Spacer(Modifier.width(6.dp))
                        Column {
                            Text("HTTPS (TLS) required")
                            Text(
                                "Cleartext WebDAV is disabled because it exposes credentials and file contents.",
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(enabled = protocol != "SFTP") {
                            anonymous = !anonymous
                            if (anonymous) {
                                authProfileId = null
                                username = ""
                                password = ""
                            }
                        }
                        .padding(vertical = 4.dp)
                ) {
                    Checkbox(
                        checked = anonymous,
                        onCheckedChange = null,
                        enabled = protocol != "SFTP",
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Anonymous / guest login")
                }
                if (!anonymous) {
                    if (protocol == "FTP") {
                        Text(
                            "FTP sends usernames and passwords in cleartext. Prefer SFTP for credentials.",
                            fontSize = 12.sp,
                            color = OmniColors.amber,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Text("Credential profile", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        item {
                            FilterChip(
                                selected = authProfileId == null,
                                onClick = { authProfileId = null },
                                label = { Text("New profile") },
                            )
                        }
                        items(credentialProfiles, key = { it.id }) { profile ->
                            FilterChip(
                                selected = authProfileId == profile.id,
                                onClick = { authProfileId = profile.id },
                                label = { Text(profile.profileName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            )
                        }
                    }
                    if (authProfileId == null) {
                        Text("Saving will create a reusable credential profile in the Network Shares group.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        OutlinedTextField(value = workgroup, onValueChange = { workgroup = it }, label = { Text("Workgroup / domain") }, modifier = Modifier.fillMaxWidth(), singleLine = true, colors = omniTextFieldColors())
                        OutlinedTextField(value = username, onValueChange = { username = it }, label = { Text("Username") }, modifier = Modifier.fillMaxWidth(), singleLine = true, colors = omniTextFieldColors())
                        OmniPasswordField(value = password, onValueChange = { password = it }, label = "Password", modifier = Modifier.fillMaxWidth())
                    }
                }
                OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes") }, modifier = Modifier.fillMaxWidth(), minLines = 2, colors = omniTextFieldColors())
                errorText?.let {
                    Text(it, color = OmniColors.red, fontSize = 12.sp, modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                validateDraft()?.let {
                    errorText = it
                    return@Button
                }
                onSave(
                    NetworkShareEntity(
                        id = initial?.id ?: 0,
                        name = name,
                        protocol = protocol,
                        address = address,
                        port = portText.toIntOrNull() ?: defaultPort(protocol),
                        sharePath = sharePath,
                        workgroup = workgroup,
                        username = username,
                        password = password,
                        authProfileId = authProfileId,
                        anonymous = anonymous,
                        useHttps = protocol == "WEBDAV" || useHttps,
                        notes = notes,
                        lastChecked = initial?.lastChecked ?: 0L,
                        lastStatus = initial?.lastStatus ?: "unknown",
                    )
                )
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun shareUri(share: NetworkShareEntity): String {
    val scheme = when (share.protocol.uppercase(Locale.ROOT)) {
        "SMB" -> "smb"
        "WEBDAV" -> "https"
        else -> share.protocol.lowercase(Locale.ROOT)
    }
    val port = if (share.port > 0) ":${share.port}" else ""
    val path = share.sharePath.trim('/').takeIf { it.isNotBlank() }?.let { "/$it" }.orEmpty()
    return "$scheme://${share.address}$port$path"
}

private fun shareProtocolColor(protocol: String): Color = when (protocol.uppercase(Locale.ROOT)) {
    "SMB" -> OmniColors.cyan
    "FTP" -> OmniColors.green
    "SFTP" -> OmniColors.amber
    "NFS" -> OmniColors.purple
    "WEBDAV" -> OmniColors.orange
    else -> OmniColors.cyan
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
    val copyToClipboard = rememberClipboardCopy()

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

    // Dual-pane split ratio (pane B's share of the vertical space). In-session only, defaults 50/50.
    var dualPaneFraction by remember { mutableStateOf(0.5f) }
    var columnHeightPx by remember { mutableStateOf(0f) }
    val density = androidx.compose.ui.platform.LocalDensity.current

    Column(
        modifier = Modifier.fillMaxSize()
            .onSizeChanged { columnHeightPx = it.height.toFloat() },
    ) {
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
                        // Compress selection → archive (format chosen from a small menu).
                        Box {
                            var archiveMenu by remember { mutableStateOf(false) }
                            IconButton(onClick = { archiveMenu = true }) {
                                Icon(Icons.Filled.Archive, contentDescription = "Compress to archive")
                            }
                            DropdownMenu(expanded = archiveMenu, onDismissRequest = { archiveMenu = false }) {
                                listOf("zip" to "ZIP (.zip)", "tar.gz" to "Gzipped tar (.tar.gz)", "tar" to "Tar (.tar)").forEach { (fmt, label) ->
                                    DropdownMenuItem(
                                        text = { Text(label, fontSize = 13.sp) },
                                        onClick = { archiveMenu = false; viewModel.sftpArchiveSelection(fmt) },
                                    )
                                }
                            }
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
                        CompactSftpIconToggleButton(checked = viewModel.dualPaneEnabled, onCheckedChange = { viewModel.toggleDualPane() }) {
                            Icon(
                                Icons.Filled.VerticalSplit,
                                contentDescription = if (viewModel.dualPaneEnabled) "Close second pane" else "Open second pane",
                                tint = if (viewModel.dualPaneEnabled) OmniColors.cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
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

        // Clipboard / paste bar — server-side cp/mv, so only when the staged files live on THIS
        // host. After switching hosts the cross-endpoint bar below takes over (streamed paste).
        if (viewModel.sftpClipboardIsLocal) {
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

        // Windows-style aggregate progress for transfers on this host (uploads/downloads) and any
        // running cross-endpoint paste. Full per-file history stays on the Transfers tab.
        val srvId = viewModel.selectedServerId
        val hasHostTransfers = srvId != null && viewModel.sftpTransfers.any {
            it.serverId == srvId && it.status == SftpTransferStatus.InProgress
        }
        if (hasHostTransfers || viewModel.crossPasteRunning) {
            Spacer(modifier = Modifier.height(8.dp))
            TransferAggregateBar(viewModel, endpointId = if (viewModel.crossPasteRunning) null else srvId)
            viewModel.crossPasteProgress?.let { current ->
                Text(
                    "Copying: $current",
                    fontSize = 10.sp,
                    fontFamily = OmniFonts.mono,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        // Cross-endpoint paste bar — appears when files copied from a network share or a *different*
        // SSH host are staged. Pasting here streams them onto the current host (the same-host case
        // above already handles server-side cp/mv, so this bar hides when the clipboard is local).
        if (viewModel.crossClipboard.isNotEmpty() && !viewModel.sftpClipboardIsLocal) {
            Spacer(modifier = Modifier.height(8.dp))
            CrossClipboardBar(
                viewModel = viewModel,
                existingNames = viewModel.sftpEntries.map { it.name },
                confirm = confirm,
                onPaste = { viewModel.pasteIntoSftp() },
            )
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

        // Dual-pane: a second SFTP browser below the primary listing. Copy/cut here stages onto the
        // cross-endpoint clipboard, so pasting in the primary pane streams the files across. A
        // draggable handle adjusts the split; the primary list (weight 1f above) fills whatever
        // height pane B leaves. Free drag, generous clamp, double-tap to rebalance — not persisted.
        if (viewModel.dualPaneEnabled) {
            SftpSplitHandle(
                onReset = { dualPaneFraction = 0.5f },
                onDrag = { dy ->
                    // Dragging up grows pane B (it sits below the handle), so subtract dy.
                    if (columnHeightPx > 0f) dualPaneFraction = (dualPaneFraction - dy / columnHeightPx).coerceIn(0.15f, 0.85f)
                },
            )
            val paneBHeight = with(density) { (columnHeightPx * dualPaneFraction).toDp() }
            SftpSecondPane(
                viewModel, confirm,
                modifier = if (columnHeightPx > 0f) Modifier.height(paneBHeight) else Modifier.weight(1f),
            )
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
                            if (viewModel.isArchiveFile(file.name)) {
                                TextButton(
                                    onClick = {
                                        selectedFileForOption = null
                                        viewModel.sftpExtractArchive(file)
                                    }
                                ) {
                                    Icon(Icons.Filled.Unarchive, null)
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text("Extract here")
                                }
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
                                viewModel.sftpArchiveSelection("tar.gz", only = file)
                            }
                        ) {
                            Icon(Icons.Filled.Archive, null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Compress to .tar.gz")
                        }
                        TextButton(
                            onClick = {
                                selectedFileForOption = null
                                val fullPath = (viewModel.sftpPath.ifBlank { "" } + "/" + file.name).replace("//", "/")
                                copyToClipboard(fullPath)
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

/**
 * Horizontal draggable divider for the SFTP dual-pane split. Reports raw vertical drag pixels to
 * [onDrag] (free movement, no snap); double-tap resets to balanced. A wide strip is the touch
 * target, with a short grip bar centred in it.
 */
@Composable
private fun SftpSplitHandle(onReset: () -> Unit, onDrag: (Float) -> Unit) {
    val haptics = LocalHapticFeedback.current
    Box(
        Modifier
            .fillMaxWidth()
            .height(22.dp)
            .pointerInput(Unit) {
                detectVerticalDragGestures(
                    onDragStart = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) },
                ) { _, dy -> onDrag(dy) }
            }
            .pointerInput(Unit) { detectTapGestures(onDoubleTap = { onReset() }) },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.width(40.dp).height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(OmniColors.cyan),
        )
    }
}

/**
 * The dual-pane second browser: an independent SFTP listing for a chosen host. Read/copy oriented —
 * navigate folders, and copy/cut files onto the cross-endpoint clipboard to stream them into the
 * primary pane. Keeps its own state on the ViewModel (paneB*) so the two panes never interfere.
 */
@Composable
private fun SftpSecondPane(viewModel: AppViewModel, confirm: ConfirmController, modifier: Modifier = Modifier) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var serverMenu by remember { mutableStateOf(false) }
    val srvName = servers.find { it.id == viewModel.paneBServerId }?.name ?: "Select host"

    Column(modifier = modifier.fillMaxWidth()) {
        // Pane header: host picker + up/refresh + path.
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Box {
                TextButton(onClick = { serverMenu = true }) {
                    Icon(Icons.Filled.Dns, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(srvName, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Icon(Icons.Filled.ArrowDropDown, null)
                }
                DropdownMenu(expanded = serverMenu, onDismissRequest = { serverMenu = false }) {
                    servers.forEach { s ->
                        DropdownMenuItem(text = { Text(s.name) }, onClick = { serverMenu = false; viewModel.paneBSelectServer(s.id) })
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { viewModel.paneBNavigateUp() }, enabled = viewModel.paneBPath.trim('/').isNotEmpty()) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = "Up one folder")
            }
            IconButton(onClick = { viewModel.loadPaneB(viewModel.paneBPath.ifBlank { null }) }) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
            }
        }
        Text(
            viewModel.paneBPath.ifBlank { "/" },
            fontFamily = OmniFonts.mono, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp),
        )
        viewModel.paneBError?.let {
            Text(it, color = OmniColors.red, fontSize = 11.sp, fontFamily = OmniFonts.mono, modifier = Modifier.padding(horizontal = 4.dp))
        }

        when {
            viewModel.paneBServerId == null -> Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("Pick a host to browse.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            }
            viewModel.paneBLoading && viewModel.paneBEntries.isEmpty() -> Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            viewModel.paneBEntries.isEmpty() -> Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("Empty folder.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp)
            }
            else -> LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f)) {
                items(viewModel.paneBEntries, key = { it.name }) { file ->
                    var menu by remember(file.name) { mutableStateOf(false) }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = file.isDirectory) { viewModel.paneBNavigateInto(file.name) }
                            .padding(vertical = 5.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            if (file.isDirectory) Icons.Filled.Folder else Icons.AutoMirrored.Filled.InsertDriveFile,
                            null,
                            tint = if (file.isDirectory) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(file.name, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        if (!file.isDirectory) Text(formatBytes(file.size), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Box {
                            IconButton(onClick = { menu = true }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Filled.MoreVert, contentDescription = "Actions", modifier = Modifier.size(16.dp))
                            }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text("Copy → other pane") },
                                    leadingIcon = { Icon(Icons.Filled.ContentCopy, null) },
                                    onClick = { menu = false; viewModel.paneBClipFile(file, move = false) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Cut → other pane") },
                                    leadingIcon = { Icon(Icons.Filled.ContentCut, null) },
                                    onClick = { menu = false; viewModel.paneBClipFile(file, move = true) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Windows-style aggregate transfer banner: "Copying 3 files · 1.2 GB of 4.7 GB · 18.4 MB/s · ETA 2m".
 * Shows a combined progress bar over every in-flight transfer for the given [endpointId] (null =
 * all endpoints). Renders nothing when idle. Reused by the Transfers tab, the share browser, and
 * the SFTP Files tab so every transfer surface reports files + total size consistently.
 */
@Composable
fun TransferAggregateBar(viewModel: AppViewModel, endpointId: Int? = null, modifier: Modifier = Modifier) {
    val agg = viewModel.transferAggregate(endpointId) ?: return
    val etaStr = if (agg.etaSeconds > 0) " · ETA ${formatEta(agg.etaSeconds)}" else ""
    val speedStr = if (agg.speedKbps >= 1024f) "%.1f MB/s".format(agg.speedKbps / 1024f)
        else if (agg.speedKbps > 0f) "%.0f KB/s".format(agg.speedKbps) else ""
    // Batches run one file at a time, so the in-flight count alone would always read "1 file".
    // When a batch is active, show the overall position instead: current index + done/pending.
    val batchTotal = viewModel.transferBatchTotal
    val batchDone = viewModel.transferBatchDone
    val title = if (batchTotal > 1) {
        val pending = (batchTotal - batchDone - 1).coerceAtLeast(0)
        "Transferring file ${(batchDone + 1).coerceAtMost(batchTotal)} of $batchTotal · $batchDone done, $pending pending"
    } else {
        "Transferring ${agg.activeFiles} file${if (agg.activeFiles == 1) "" else "s"}"
    }
    OmniCard(modifier = modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.SyncAlt, null, tint = OmniColors.cyan)
                Spacer(Modifier.width(8.dp))
                Text(
                    title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
            }
            Spacer(Modifier.height(6.dp))
            if (agg.hasKnownTotal) {
                LinearProgressIndicator(progress = { agg.fraction }, modifier = Modifier.fillMaxWidth(), color = OmniColors.cyan)
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = OmniColors.cyan)
            }
            Spacer(Modifier.height(4.dp))
            Text(
                buildString {
                    if (agg.hasKnownTotal) append("${formatBytes(agg.bytesTransferred)} of ${formatBytes(agg.totalBytes)}")
                    else append(formatBytes(agg.bytesTransferred))
                    if (speedStr.isNotBlank()) append(" · $speedStr")
                    append(etaStr)
                },
                fontSize = 11.sp,
                fontFamily = OmniFonts.mono,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun formatEta(seconds: Int): String = when {
    seconds >= 3600 -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
    seconds >= 60 -> "${seconds / 60}m ${seconds % 60}s"
    else -> "${seconds}s"
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
                if (hasRunningTransfers) {
                    Text("Cancel all", fontSize = 11.sp, color = OmniColors.amber, modifier = Modifier.clickable { viewModel.cancelAllRunningTransfers() })
                } else {
                    Text("Clear logs", fontSize = 11.sp, color = Color.Red, modifier = Modifier.clickable { confirmClearTransfers = true })
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
            // Windows-style rollup across every in-flight transfer, above the per-file rows.
            if (hasRunningTransfers) {
                TransferAggregateBar(viewModel)
                Spacer(modifier = Modifier.height(12.dp))
            }
            LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(viewModel.sftpTransfers, key = { it.id }) { item ->
                    val cancelled = item.status == SftpTransferStatus.Failure && item.message == TRANSFER_CANCELLED_MESSAGE
                    val accent = when {
                        cancelled -> OmniColors.amber
                        item.status == SftpTransferStatus.Success -> OmniColors.green
                        item.status == SftpTransferStatus.Failure -> OmniColors.red
                        else -> OmniColors.cyan
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
                                    when {
                                        cancelled -> "Cancelled"
                                        item.status == SftpTransferStatus.InProgress -> "Running"
                                        item.status == SftpTransferStatus.Success -> "Done"
                                        else -> "Failed"
                                    },
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = accent,
                                )
                                if (item.status == SftpTransferStatus.InProgress) {
                                    IconButton(onClick = { viewModel.cancelSftpTransfer(item.id) }, modifier = Modifier.size(28.dp)) {
                                        Icon(Icons.Filled.Close, contentDescription = "Cancel transfer", tint = OmniColors.amber, modifier = Modifier.size(16.dp))
                                    }
                                }
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
    // Network shares can't elevate, so their editor hides the sudo toggle entirely (rather than
    // showing a dead control). SFTP hosts leave it on.
    showSudo: Boolean = true,
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
        topBarAction = if (!showSudo) null else {
            {
                IconToggleButton(checked = sudo, onCheckedChange = { onToggleSudo() }) {
                    Icon(
                        Icons.Filled.AdminPanelSettings,
                        contentDescription = if (sudo) "Save as root: on" else "Save as root: off",
                        tint = if (sudo) OmniColors.red else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
    )
}

@Composable
fun SftpBookmarksTab(viewModel: AppViewModel) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val shares by viewModel.networkShares.collectAsStateWithLifecycle()
    var newBookmarkPath by remember { mutableStateOf("") }
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    // Bookmarks span every host and share; reload on entry so stars set elsewhere show up.
    LaunchedEffect(Unit) { viewModel.loadAllBookmarks() }
    val srv = viewModel.selectedServer

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (srv != null) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = newBookmarkPath,
                    onValueChange = { newBookmarkPath = it },
                    label = { Text("Add path on ${srv.name}") },
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Button(
                    onClick = {
                        if (newBookmarkPath.isNotBlank()) {
                            viewModel.addSftpBookmark(newBookmarkPath.trim())
                            newBookmarkPath = ""
                            viewModel.loadAllBookmarks()
                        }
                    }
                ) {
                    Text("Add")
                }
            }
        }

        Spacer(modifier = Modifier.height(4.dp))
        Text(
            "Quick-access bookmarks — every host and share. Offline endpoints are greyed out.",
            fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (viewModel.allBookmarks.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "No bookmarks yet. Star a folder in the SFTP or Shares browser to pin it here.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(viewModel.allBookmarks, key = { "${it.serverId}|${it.shareId}|${it.path}" }) { bmk ->
                val share = bmk.shareId?.let { id -> shares.firstOrNull { it.id == id } }
                // A host must be probed online; a share is selectable unless its last test failed
                // (an untested share is still worth attempting — browsing dials it anyway).
                val available = when {
                    bmk.serverId != null -> servers.any { it.id == bmk.serverId && it.status == "online" }
                    share != null -> share.lastStatus != "offline"
                    else -> false
                }
                val endpointColor = if (bmk.shareId != null) shareProtocolColor(share?.protocol ?: "") else OmniColors.cyan
                OmniCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .alpha(if (available) 1f else 0.38f)
                        .clickable(enabled = available) { viewModel.openEndpointBookmark(bmk) }
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            if (bmk.shareId != null) Icons.Filled.Lan else Icons.Filled.Bookmark,
                            contentDescription = null,
                            tint = if (available) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = bmk.path,
                                fontFamily = OmniFonts.mono,
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = bmk.endpointName + if (available) "" else " · offline",
                                fontSize = 11.sp,
                                color = endpointColor,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        IconButton(onClick = {
                            confirm.ask("Remove Bookmark?", "Remove ${bmk.path} on ${bmk.endpointName}?", confirmLabel = "Remove") {
                                viewModel.removeEndpointBookmark(bmk)
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
