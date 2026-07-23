package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import kotlinx.coroutines.launch
import androidx.compose.ui.res.stringResource
import com.jetsetslow.omniterm.R

@Composable
fun InfraScreen(viewModel: AppViewModel) {
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val onlineServers = servers.filter { it.status == "online" }
    val explicitlySelected = servers.find { it.id == viewModel.selectedServerId }
    val srv = explicitlySelected ?: onlineServers.firstOrNull()
    // Load real container runtime state whenever the selected host changes.
    LaunchedEffect(srv?.id) {
        if (srv != null) {
            if (explicitlySelected == null && viewModel.selectedServerId != srv.id) viewModel.selectedServerId = srv.id
            viewModel.loadDocker()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Host picker (mirrors SFTP/Cron) so the user can switch which host's containers they inspect.
        ServerSelectorBar(viewModel, onlineOnly = true, onServerChange = { viewModel.loadDocker() })
        if (srv == null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.no_online_hosts_available_container_data), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            return@Column
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Containers · ${srv.name}", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
            IconButton(onClick = { viewModel.loadDocker() }) {
                Icon(Icons.Filled.Refresh, contentDescription = "Reload")
            }
        }
        PrimaryScrollableTabRow(
            selectedTabIndex = viewModel.activeInfraTab,
            edgePadding = 0.dp,
            modifier = Modifier.fillMaxWidth()
        ) {
            Tab(selected = viewModel.activeInfraTab == 0, onClick = { viewModel.activeInfraTab = 0 }) { Text(stringResource(R.string.stacks), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), maxLines = 1) }
            Tab(selected = viewModel.activeInfraTab == 1, onClick = { viewModel.activeInfraTab = 1 }) { Text(stringResource(R.string.builder), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), maxLines = 1) }
            Tab(selected = viewModel.activeInfraTab == 2, onClick = { viewModel.activeInfraTab = 2 }) { Text(stringResource(R.string.images), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), maxLines = 1) }
            Tab(selected = viewModel.activeInfraTab == 3, onClick = { viewModel.activeInfraTab = 3 }) { Text(stringResource(R.string.volumes), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), maxLines = 1) }
            Tab(selected = viewModel.activeInfraTab == 4, onClick = { viewModel.activeInfraTab = 4 }) { Text(stringResource(R.string.networks), fontSize = OmniTextSize.Dense, modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp), maxLines = 1) }
        }

        Box(modifier = Modifier.fillMaxWidth().weight(1f).padding(12.dp)) {
            when {
                viewModel.activeInfraTab == 1 ->
                    ComposeBuilder(viewModel)
                viewModel.dockerLoading && viewModel.dockerContainers.isEmpty() ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                viewModel.dockerError != null ->
                    ContainerRuntimeError(viewModel.dockerError!!)
                else -> when (viewModel.activeInfraTab) {
                    0 -> StacksView(viewModel, viewModel.dockerContainers)
                    2 -> ImageList(viewModel, viewModel.dockerImages)
                    3 -> VolumeList(viewModel, viewModel.dockerVolumes)
                    4 -> NetworkList(viewModel, viewModel.dockerNetworks)
                    else -> StacksView(viewModel, viewModel.dockerContainers)
                }
            }
        }
    }
}

@Composable
private fun ContainerRuntimeError(error: String) {
    val copyToClipboard = rememberClipboardCopy()
    val scroll = rememberScrollState()
    Column(
        Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Filled.ErrorOutline, contentDescription = null, tint = Color.Red, modifier = Modifier.size(40.dp))
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.could_not_query_containers), fontWeight = FontWeight.Bold)
        Box(
            modifier = Modifier.fillMaxWidth()
                .heightIn(min = 96.dp, max = 220.dp)
                .padding(top = 8.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(Color.Black)
                .verticalScroll(scroll)
                .padding(10.dp),
        ) {
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(
                    error,
                    fontSize = 11.sp,
                    color = Color.White,
                    fontFamily = OmniFonts.mono,
                )
            }
        }
        TextButton(
            onClick = { copyToClipboard(error) },
            modifier = Modifier.padding(top = 4.dp),
        ) {
            Icon(Icons.Filled.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.copy_error))
        }
        Text(stringResource(R.string.is_docker_or_podman_installed_and),
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun ContainerList(viewModel: AppViewModel, containers: List<SimContainer>) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    if (containers.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.no_containers_found_on_this_host), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    var isSelectionMode by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { isSelectionMode = !isSelectionMode; if (!isSelectionMode) selectedIds = setOf() }) {
                    Text(if (isSelectionMode) "Cancel Selection" else "Multi-Select")
                }
                if (isSelectionMode && selectedIds.isNotEmpty()) {
                    Button(
                        onClick = {
                            confirm.ask("Remove Containers?", "Permanently remove ${selectedIds.size} containers?", confirmLabel = "Remove") {
                                selectedIds.forEach { id ->
                                    val runtime = containers.firstOrNull { it.id == id }?.runtime.orEmpty()
                                    viewModel.dockerAction(id, "remove", runtime)
                                }
                                selectedIds = setOf()
                                isSelectionMode = false
                            }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = OmniColors.red)
                    ) { Text(stringResource(R.string.delete_selected)) }
                }
            }
        }
        items(containers, key = { it.id }) { c ->
            var expanded by remember { mutableStateOf(false) }
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = if (c.status == "running") OmniColors.green else OmniColors.red) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (isSelectionMode) {
                        Checkbox(checked = c.id in selectedIds, onCheckedChange = { if (it) selectedIds += c.id else selectedIds -= c.id })
                    }
                    Column(modifier = Modifier.weight(1f).clickable { expanded = !expanded }.padding(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            StatusDot(online = c.status == "running", color = OmniColors.green, size = 8.dp)
                            Spacer(Modifier.width(8.dp))
                            Column {
                                Text(c.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text(c.image, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                            }
                        }
                        OmniTag(c.group, color = OmniColors.cyan)
                    }

                    if (expanded) {
                        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                        Text("ID: ${c.id}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        Text("Ports: ${c.ports}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        Spacer(Modifier.height(10.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                        ) {
                            OmniButton(label = "Logs", onClick = {
                                viewModel.dockerContainerLogs(c.id, c.name, c.runtime)
                            }, color = OmniColors.cyan, small = true)
                            OmniButton(label = "Stats", onClick = {
                                viewModel.dockerContainerStats(c.id, c.name, c.runtime)
                            }, color = OmniColors.cyan, small = true)
                            // Exec into a shell only makes sense for a running container.
                            if (c.status == "running" || c.status == "paused") {
                                OmniButton(label = "Shell", onClick = {
                                    viewModel.dockerExecIntoContainer(c)
                                }, color = OmniColors.purple, small = true)
                            }

                            when (c.status) {
                                "paused" -> {
                                    OmniButton(
                                        label = "Unpause",
                                        onClick = { viewModel.dockerAction(c.id, "unpause", c.runtime) },
                                        color = OmniColors.green,
                                        small = true,
                                    )
                                    OmniButton(
                                        label = "Stop",
                                        onClick = {
                                            confirm.ask("Stop ${c.name}?", "Stop this container? It will remain stopped until started again.", confirmLabel = "Stop") {
                                                viewModel.dockerAction(c.id, "stop", c.runtime)
                                            }
                                        },
                                        color = OmniColors.red,
                                        small = true,
                                    )
                                }
                                "running", "restarting" -> {
                                    OmniButton(
                                        label = "Pause",
                                        onClick = { viewModel.dockerAction(c.id, "pause", c.runtime) },
                                        color = OmniColors.amber,
                                        small = true,
                                    )
                                    OmniButton(
                                        label = "Restart",
                                        onClick = {
                                            confirm.ask("Restart ${c.name}?", "Restart this container? It will briefly go down.", confirmLabel = "Restart") {
                                                viewModel.dockerAction(c.id, "restart", c.runtime)
                                            }
                                        },
                                        color = OmniColors.cyan,
                                        small = true,
                                    )
                                    OmniButton(
                                        label = "Stop",
                                        onClick = {
                                            confirm.ask("Stop ${c.name}?", "Stop this container? It will remain stopped until started again.", confirmLabel = "Stop") {
                                                viewModel.dockerAction(c.id, "stop", c.runtime)
                                            }
                                        },
                                        color = OmniColors.red,
                                        small = true,
                                    )
                                    OmniButton(
                                        label = "Delete",
                                        onClick = {
                                            confirm.ask("Delete ${c.name}?", "Force-remove this running container? This cannot be undone.", confirmLabel = "Delete") {
                                                viewModel.dockerAction(c.id, "remove", c.runtime)
                                            }
                                        },
                                        color = OmniColors.red,
                                        small = true,
                                    )
                                }
                                else -> {
                                    OmniButton(
                                        label = "Start",
                                        onClick = { viewModel.dockerAction(c.id, "start", c.runtime) },
                                        color = OmniColors.green,
                                        small = true,
                                    )
                                    OmniButton(
                                        label = "Remove",
                                        onClick = {
                                            confirm.ask("Remove ${c.name}?", "Permanently remove this container? This cannot be undone.", confirmLabel = "Remove") {
                                                viewModel.dockerAction(c.id, "remove", c.runtime)
                                            }
                                        },
                                        color = OmniColors.red,
                                        small = true,
                                    )
                                }
                            }
                        }
                    }
                    }
                }
            }
        }
    }

}

@Composable
private fun StacksView(viewModel: AppViewModel, containers: List<SimContainer>) {
    val scope = rememberCoroutineScope()
    var pendingDown by remember { mutableStateOf<StackSummary?>(null) }
    var pendingDownRemoveOrphans by remember { mutableStateOf(false) }
    var scaleTarget by remember { mutableStateOf<ScaleTarget?>(null) }
    var portsTarget by remember { mutableStateOf<StackSummary?>(null) }
    var editBuilderError by remember { mutableStateOf<String?>(null) }
    val copyToClipboard = rememberClipboardCopy()
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    val stacks = remember(containers) {
        containers.groupBy { it.runtime to it.group }.map { (key, list) ->
            val (runtime, name) = key
            val portDetails = list
                .filter { it.ports != "—" }
                .map { ContainerPortDetail(it.name, it.composeService.ifBlank { it.name.substringBefore('_') }, it.ports) }
            StackSummary(
                name = name,
                runtime = runtime,
                total = list.size,
                running = list.count { it.status == "running" },
                unhealthy = list.count { it.health == "unhealthy" },
                restarting = list.count { it.status == "restarting" },
                restartCount = list.sumOf { it.restartCount },
                exposedPorts = portDetails.size,
                portDetails = portDetails,
                oldestCreatedAt = list.mapNotNull { it.createdAt.takeIf(String::isNotBlank) }.minOrNull().orEmpty(),
                // Podman/podman-compose frequently sets the config_files label but NOT
                // working_dir; the helper falls back to the first absolute config file's parent
                // directory — the directory `compose` would `cd` into anyway.
                workingDir = com.jetsetslow.omniterm.data.RemoteParsers.composeStackWorkingDir(
                    list.firstOrNull { it.composeWorkingDir.isNotBlank() }?.composeWorkingDir.orEmpty(),
                    list.firstOrNull { it.composeConfigFiles.isNotBlank() }?.composeConfigFiles.orEmpty(),
                ),
                configFiles = list.firstOrNull { it.composeConfigFiles.isNotBlank() }?.composeConfigFiles.orEmpty(),
                services = list.groupBy { it.composeService.ifBlank { it.name.substringBefore('_') } }
                    .map { (service, serviceContainers) ->
                        StackService(
                            name = service.ifBlank { "service" },
                            total = serviceContainers.size,
                            running = serviceContainers.count { it.status == "running" },
                            unhealthy = serviceContainers.count { it.health == "unhealthy" },
                            containerId = serviceContainers.firstOrNull { it.status == "running" }?.id ?: serviceContainers.firstOrNull()?.id.orEmpty(),
                            containers = serviceContainers.map {
                                StackContainer(
                                    name = it.name,
                                    status = it.status,
                                    ports = it.ports,
                                )
                            },
                        )
                    }
                    .sortedBy { it.name },
            )
        }
    }
    // Stacks known to the app-side registry with no containers in `ps -a` — downed via
    // `compose down`. The VM already diffs against the live list; the extra filter here only
    // covers the window between a stack action and the next refresh landing.
    val downedStacks = viewModel.downedStacks.filter { d -> stacks.none { it.runtime == d.runtime && it.name == d.project } }
    if (stacks.isEmpty() && downedStacks.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(stringResource(R.string.no_compose_stacks_found), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        return
    }
    // Resolve the ABSOLUTE path of the exact compose file the stack's labels reported and load it
    // into the visual builder. Shared by live and downed stacks — the file outlives the containers.
    suspend fun openStackInBuilder(project: String, workingDir: String, configFiles: String, runtime: String) {
        val firstConfig = configFiles.split(',').map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
        val composePath = when {
            firstConfig.startsWith("/") -> firstConfig
            firstConfig.isNotEmpty() -> "${workingDir.trimEnd('/')}/$firstConfig"
            else -> "${workingDir.trimEnd('/')}/docker-compose.yml"
        }
        val yaml = viewModel.readComposeFile(composePath)
        if (yaml != null && yaml.isNotBlank()) {
            editBuilderError = null
            viewModel.beginComposeDraft(parseDockerComposeYaml(
                yaml, project,
                workingDir = workingDir,
                fileName = composePath.substringAfterLast('/'),
                composeFilePath = composePath,
                composeConfigFiles = configFiles,
                runtime = runtime,
            ))
            viewModel.activeInfraTab = 1
        } else {
            editBuilderError = viewModel.composeFileReadError ?: "Could not read compose file: $composePath"
        }
    }
    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        editBuilderError?.let { msg ->
            item {
                Row(
                    modifier = Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(OmniColors.red.copy(alpha = 0.12f))
                        .padding(10.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(Icons.Filled.ErrorOutline, contentDescription = null, tint = OmniColors.red, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    androidx.compose.foundation.text.selection.SelectionContainer(
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface)
                    }
                    IconButton(onClick = { copyToClipboard(msg) }) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = "Copy error", modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
        items(stacks) { stack ->
            val canCompose = stack.name != "standalone" && stack.workingDir.isNotBlank()
            var servicesExpanded by remember(stack.name) { mutableStateOf(false) }
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Filled.Layers, contentDescription = null, tint = OmniColors.cyan)
                            Spacer(Modifier.width(12.dp))
                            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stack.name, fontWeight = FontWeight.Bold, fontSize = 16.sp, fontFamily = OmniFonts.mono)
                    Spacer(Modifier.width(6.dp))
                    OmniTag(stack.runtime.uppercase(), color = if (stack.runtime == "podman") OmniColors.purple else OmniColors.cyan)
                }
                                Text(
                                    if (canCompose) stack.workingDir else "No compose metadata for stack actions",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    fontFamily = OmniFonts.mono,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("${stack.running}/${stack.total}", fontWeight = FontWeight.Bold, color = if (stack.running == stack.total) OmniColors.green else OmniColors.red)
                            Text(stringResource(R.string.running), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.End, modifier = Modifier.fillMaxWidth()) {
                        if (canCompose) {
                            OmniButton(label = "Edit in Builder", color = OmniColors.purple, modifier = Modifier.fillMaxWidth(), onClick = {
                                scope.launch { openStackInBuilder(stack.name, stack.workingDir, stack.configFiles, stack.runtime) }
                            })
                        }
                        // Compose lifecycle actions need a working dir + config files to run.
                        // Only show them when the stack actually exposes that metadata, so a
                        // standalone group (or a runtime that hides the labels) never presents
                        // buttons that can only fail with a "no compose metadata" message.
                        if (canCompose) {
                        StackActionRow(
                            stack = stack,
                            actions = listOf("ps" to "PS", "logs" to "Logs", "followLogs" to "FOLLOW", "config" to "CONFIG"),
                            onAction = { action -> viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, action, runtime = stack.runtime) },
                        )
                        StackActionRow(
                            stack = stack,
                            actions = listOf("update" to "Update", "build" to "Build", "pull" to "Pull", "up" to "UP -D", "forceRecreate" to "Force Recreate", "restart" to "Restart", "down" to "DOWN", "removeOrphans" to "Remove Orphans"),
                            onAction = { action ->
                                when (action) {
                                    "down" -> { pendingDownRemoveOrphans = false; pendingDown = stack }
                                    "build" -> confirm.ask(
                                        "Build ${stack.name}?",
                                        "Build this stack's Dockerfile-based images (refreshing their base images). Containers are not recreated — run Update or UP -D afterwards to apply.",
                                        confirmLabel = "Build",
                                    ) { viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, "build", runtime = stack.runtime) }
                                    "removeOrphans" -> confirm.ask(
                                        "Remove Orphans?",
                                        "Remove containers for services no longer defined in the compose file for ${stack.name}.",
                                        confirmLabel = "Remove Orphans",
                                    ) { viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, "removeOrphans", runtime = stack.runtime) }
                                    "update" -> confirm.ask(
                                        "Update ${stack.name}?",
                                        "Pull updated registry images, (re)build any Dockerfile-based images, then recreate this stack's containers?",
                                        confirmLabel = "Update",
                                    ) { viewModel.dockerStackUpdate(stack.name, stack.workingDir, stack.configFiles, stack.runtime) }
                                    "forceRecreate" -> confirm.ask(
                                        "Force Recreate ${stack.name}?",
                                        "Recreate all containers even if nothing changed? Running containers will briefly restart.",
                                        confirmLabel = "Recreate",
                                    ) { viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, "forceRecreate", runtime = stack.runtime) }
                                    "restart" -> confirm.ask(
                                        "Restart ${stack.name}?",
                                        "Restart all services in this stack? They will briefly go down.",
                                        confirmLabel = "Restart",
                                    ) { viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, action, runtime = stack.runtime) }
                                    else -> viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, action, runtime = stack.runtime)
                                }
                            },
                        )
                        }
                    }
                    StackHealthSummary(stack, onPortsClick = { portsTarget = stack })
                    if (stack.services.isNotEmpty()) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable { servicesExpanded = !servicesExpanded }.padding(vertical = 2.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    if (servicesExpanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    contentDescription = if (servicesExpanded) "Collapse containers" else "Expand containers",
                                    tint = MaterialTheme.colorScheme.primary,
                                )
                                Text(
                                    "${stack.services.size} service(s) · ${stack.running}/${stack.total} containers",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Text(
                                if (servicesExpanded) "Hide" else "Show",
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                        // Each service/container is an indented nested card so it visibly belongs
                        // to this stack rather than reading as one flat list.
                        if (servicesExpanded) {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(start = 12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                              stack.services.forEach { service ->
                                OmniCard(
                                    modifier = Modifier.fillMaxWidth(),
                                    leftAccent = if (service.running > 0 && service.unhealthy == 0) OmniColors.green else OmniColors.red,
                                ) {
                                  StackServiceRow(
                                    service = service,
                                    onLogs = { follow ->
                                        viewModel.dockerStackServiceAction(
                                            stack.name,
                                            stack.workingDir,
                                            stack.configFiles,
                                            service.name,
                                            if (follow) "followLogs" else "serviceLogs",
                                            runtime = stack.runtime,
                                        )
                                    },
                                    onRestart = {
                                        confirm.ask(
                                            "Restart ${service.name}?",
                                            "Restart this service in ${stack.name}? It will briefly go down.",
                                            confirmLabel = "Restart",
                                        ) { viewModel.dockerStackServiceAction(stack.name, stack.workingDir, stack.configFiles, service.name, "serviceRestart", runtime = stack.runtime) }
                                    },
                                    onStop = {
                                        confirm.ask(
                                            "Stop ${service.name}?",
                                            "Stop this service in ${stack.name}? It will remain stopped until started again.",
                                            confirmLabel = "Stop",
                                        ) { viewModel.dockerStackServiceAction(stack.name, stack.workingDir, stack.configFiles, service.name, "serviceStop", runtime = stack.runtime) }
                                    },
                                    onShell = { viewModel.openDockerExecShell(service.containerId) },
                                    onScale = { scaleTarget = ScaleTarget(stack, service) },
                                    onRemove = {
                                        confirm.ask(
                                            "Remove ${service.name}?",
                                            "Stop and remove the container(s) for this service in ${stack.name}. The service definition in the compose file is not deleted.",
                                            confirmLabel = "Remove",
                                        ) { viewModel.dockerStackServiceAction(stack.name, stack.workingDir, stack.configFiles, service.name, "serviceRemove", runtime = stack.runtime) }
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
        // ── Downed stacks: known to the registry, zero containers on the host ──
        items(downedStacks, key = { "down-${it.runtime}-${it.project}" }) { stack ->
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.red) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Filled.Layers, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(stack.project, fontWeight = FontWeight.Bold, fontSize = 16.sp, fontFamily = OmniFonts.mono)
                                    Spacer(Modifier.width(6.dp))
                                    OmniTag(stack.runtime.uppercase(), color = if (stack.runtime == "podman") OmniColors.purple else OmniColors.cyan)
                                }
                                Text(
                                    stack.workingDir,
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    fontFamily = OmniFonts.mono,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(stringResource(R.string.down), fontWeight = FontWeight.Bold, color = OmniColors.red)
                            Text(stringResource(R.string.str_0_containers), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text(stringResource(R.string.taken_down_its_containers_and_networks),
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                        OmniButton(label = "UP -D", color = OmniColors.green, modifier = Modifier.fillMaxWidth(), onClick = {
                            confirm.ask(
                                "Bring ${stack.project} up?",
                                "Run compose up -d from ${stack.workingDir}? Containers and networks are recreated from the compose file.",
                                confirmLabel = "UP -D",
                            ) { viewModel.bringUpDownedStack(stack) }
                        })
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                            OmniButton(label = "Edit in Builder", color = OmniColors.purple, modifier = Modifier.weight(1f), onClick = {
                                scope.launch { openStackInBuilder(stack.project, stack.workingDir, stack.configFiles, stack.runtime) }
                            })
                            OmniButton(label = "Forget", color = OmniColors.red, modifier = Modifier.weight(1f), onClick = {
                                confirm.ask(
                                    "Forget ${stack.project}?",
                                    "Remove this stack from OmniTerm's list only. Nothing on the host is touched — the compose file stays where it is.",
                                    confirmLabel = "Forget",
                                ) { viewModel.forgetDownedStack(stack) }
                            })
                        }
                    }
                }
            }
        }
    }

    // Stack action output streams into the global ActionStreamDialog (mounted in AppCoreScaffold).
    pendingDown?.let { stack ->
        AlertDialog(
            onDismissRequest = { pendingDown = null },
            title = { Text(stringResource(R.string.run_compose_down)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "This will stop and remove the containers for ${stack.name}. Volumes are not removed unless the compose file does so.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable { pendingDownRemoveOrphans = !pendingDownRemoveOrphans },
                    ) {
                        Checkbox(checked = pendingDownRemoveOrphans, onCheckedChange = { pendingDownRemoveOrphans = it })
                        Spacer(Modifier.width(4.dp))
                        Column {
                            Text(stringResource(R.string.remove_orphans), fontFamily = OmniFonts.mono, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                            Text(stringResource(R.string.also_removes_containers_for_services_no),
                                fontSize = 11.sp,
                                color = OmniColors.amber,
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.dockerStackAction(stack.name, stack.workingDir, stack.configFiles, "down", removeOrphans = pendingDownRemoveOrphans, runtime = stack.runtime)
                        pendingDown = null
                    }
                ) { Text(stringResource(R.string.down), color = OmniColors.red) }
            },
            dismissButton = { TextButton(onClick = { pendingDown = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    scaleTarget?.let { target ->
        var replicas by remember(target) { mutableStateOf(target.service.running.coerceAtLeast(1).toString()) }
        AlertDialog(
            onDismissRequest = { scaleTarget = null },
            title = { Text("Scale ${target.service.name}") },
            text = {
                OutlinedTextField(
                    value = replicas,
                    onValueChange = { replicas = it.filter(Char::isDigit).take(3) },
                    label = { Text(stringResource(R.string.replicas)) },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.dockerStackServiceAction(
                            target.stack.name,
                            target.stack.workingDir,
                            target.stack.configFiles,
                            target.service.name,
                            "scale",
                            replicas.toIntOrNull() ?: target.service.running.coerceAtLeast(1),
                            runtime = target.stack.runtime,
                        )
                        scaleTarget = null
                    }
                ) { Text(stringResource(R.string.scale)) }
            },
            dismissButton = { TextButton(onClick = { scaleTarget = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    portsTarget?.let { stack ->
        AlertDialog(
            onDismissRequest = { portsTarget = null },
            title = { Text("${stack.name} ports") },
            text = {
                if (stack.portDetails.isEmpty()) {
                    Text(stringResource(R.string.no_published_ports_were_reported_for), color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        stack.portDetails.forEach { detail ->
                            Column {
                                Text("${detail.service} · ${detail.container}", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                Text(detail.ports, fontFamily = OmniFonts.mono, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { portsTarget = null }) { Text(stringResource(R.string.close)) } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StackActionRow(
    stack: StackSummary,
    actions: List<Pair<String, String>>,
    onAction: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    FlowRow(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        actions.forEach { (action, label) ->
            OmniButton(
                label = label,
                onClick = { onAction(action) },
                color = when (action) {
                    "down", "removeOrphans" -> OmniColors.red
                    "up" -> OmniColors.green
                    "pull", "restart", "update" -> OmniColors.amber
                    else -> OmniColors.cyan
                },
                small = true,
            )
        }
    }
}

@Composable
private fun StackHealthSummary(stack: StackSummary, onPortsClick: () -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        OmniStatBox("${stack.unhealthy}", "Unhealthy", modifier = Modifier.weight(1f), color = if (stack.unhealthy > 0) OmniColors.red else OmniColors.green)
        OmniStatBox("${stack.restartCount}", "Restarts", modifier = Modifier.weight(1f), color = if (stack.restartCount > 0) OmniColors.amber else MaterialTheme.colorScheme.onSurfaceVariant)
        OmniStatBox("${stack.exposedPorts}", "Ports", modifier = Modifier.weight(1f).clickable { onPortsClick() }, color = OmniColors.cyan)
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                stack.oldestCreatedAt.take(10).ifBlank { "—" },
                color = MaterialTheme.colorScheme.onSurface,
                fontFamily = OmniFonts.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 12.sp,
                maxLines = 1,
            )
            Text(stringResource(R.string.created), color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold, fontSize = 10.sp, letterSpacing = 1.1.sp)
        }
    }
}

@Composable
private fun StackServiceRow(
    service: StackService,
    onLogs: (Boolean) -> Unit,
    onRestart: () -> Unit,
    onStop: () -> Unit,
    onShell: () -> Unit,
    onScale: () -> Unit,
    onRemove: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(online = service.running > 0 && service.unhealthy == 0, color = OmniColors.green, size = 7.dp)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(service.name, fontFamily = OmniFonts.mono, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                Text("${service.running}/${service.total} running", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 10.sp)
            }
        }
        service.containers.forEach { c ->
            Column(Modifier.fillMaxWidth().padding(start = 15.dp)) {
                Text("${c.name} · ${c.status}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 10.sp, fontFamily = OmniFonts.mono)
                Text("Ports: ${c.ports}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 10.sp, fontFamily = OmniFonts.mono)
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End)) {
            OmniButton("Logs", onClick = { onLogs(false) }, color = OmniColors.cyan, small = true)
            OmniButton("FOLLOW", onClick = { onLogs(true) }, color = OmniColors.cyan, small = true)
            OmniButton("Restart", onClick = onRestart, color = OmniColors.amber, small = true)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End)) {
            OmniButton("Scale", onClick = onScale, color = OmniColors.green, small = true)
            OmniButton("SHELL", onClick = onShell, color = OmniColors.purple, small = true)
            OmniButton("Stop", onClick = onStop, color = OmniColors.red, small = true)
            OmniButton("Remove", onClick = onRemove, color = OmniColors.red, small = true)
        }
    }
}

private data class StackSummary(
    val name: String,
    val runtime: String,
    val total: Int,
    val running: Int,
    val unhealthy: Int,
    val restarting: Int,
    val restartCount: Int,
    val exposedPorts: Int,
    val portDetails: List<ContainerPortDetail>,
    val oldestCreatedAt: String,
    val workingDir: String,
    val configFiles: String,
    val services: List<StackService>,
)

private data class StackService(
    val name: String,
    val total: Int,
    val running: Int,
    val unhealthy: Int,
    val containerId: String,
    val containers: List<StackContainer>,
)

private data class StackContainer(val name: String, val status: String, val ports: String)
private data class ContainerPortDetail(val container: String, val service: String, val ports: String)
private data class ScaleTarget(val stack: StackSummary, val service: StackService)

@Composable
private fun ImageList(viewModel: AppViewModel, images: List<SimDockerImage>) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    var isSelectionMode by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }
    fun imageKey(img: SimDockerImage) = "${img.runtime}:${img.id}"

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { isSelectionMode = !isSelectionMode; if (!isSelectionMode) selectedIds = setOf() }) {
                    Text(if (isSelectionMode) "Cancel Selection" else "Multi-Select")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (isSelectionMode && selectedIds.isNotEmpty()) {
                        Button(
                            onClick = {
                                confirm.ask("Remove Images?", "Permanently remove ${selectedIds.size} images?", confirmLabel = "Remove") {
                                    selectedIds.forEach { key ->
                                        images.firstOrNull { imageKey(it) == key }?.let {
                                            viewModel.dockerImageAction(it.id, "remove", it.runtime)
                                        }
                                    }
                                    selectedIds = setOf()
                                    isSelectionMode = false
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = OmniColors.red)
                        ) { Text(stringResource(R.string.delete_selected)) }
                    }
                    Button(
                        onClick = {
                            confirm.ask(
                                "Prune Unused Images?",
                                "Remove ALL images not currently used by a container (docker image prune -a). This may reclaim significant disk space and cannot be undone.",
                                confirmLabel = "Prune",
                            ) { viewModel.dockerPruneImages() }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = OmniColors.amber),
                    ) { Text(stringResource(R.string.prune_unused)) }
                }
            }
        }
        if (images.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().padding(top = 48.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.no_images_found_on_this_host), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        items(images, key = { imageKey(it) }) { img ->
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = if (img.inUse) OmniColors.green else MaterialTheme.colorScheme.outlineVariant) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (isSelectionMode) {
                        Checkbox(checked = imageKey(img) in selectedIds, onCheckedChange = { if (it) selectedIds += imageKey(img) else selectedIds -= imageKey(img) })
                    }
                    Column(modifier = Modifier.weight(1f).padding(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("${img.repository}:${img.tag}", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            Text("ID: ${img.id}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text(img.size, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = OmniColors.cyan)
                            Text(if (img.inUse) "In Use" else "Unused", fontSize = 10.sp, color = if (img.inUse) OmniColors.green else MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold)
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(img.created, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        OmniButton(
                            label = "Remove",
                            onClick = {
                                confirm.ask("Remove Image?", "Permanently remove image ${img.repository}:${img.tag}?", confirmLabel = "Remove") {
                                    viewModel.dockerImageAction(img.id, "remove", img.runtime)
                                }
                            },
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

@Composable
private fun VolumeList(viewModel: AppViewModel, volumes: List<SimDockerVolume>) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    var isSelectionMode by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }
    fun volumeKey(vol: SimDockerVolume) = "${vol.runtime}:${vol.name}"

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { isSelectionMode = !isSelectionMode; if (!isSelectionMode) selectedIds = setOf() }) {
                    Text(if (isSelectionMode) "Cancel Selection" else "Multi-Select")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (isSelectionMode && selectedIds.isNotEmpty()) {
                        Button(
                            onClick = {
                                confirm.ask("Remove Volumes?", "Permanently remove ${selectedIds.size} volumes?", confirmLabel = "Remove") {
                                    selectedIds.forEach { key ->
                                        volumes.firstOrNull { volumeKey(it) == key }?.let {
                                            viewModel.dockerVolumeAction(it.name, "remove", it.runtime)
                                        }
                                    }
                                    selectedIds = setOf()
                                    isSelectionMode = false
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = OmniColors.red)
                        ) { Text(stringResource(R.string.delete_selected)) }
                    }
                    Button(
                        onClick = {
                            confirm.ask(
                                "Prune Unused Volumes?",
                                "Remove ALL volumes not used by any container (volume prune). DATA WILL BE PERMANENTLY DELETED. This cannot be undone.",
                                confirmLabel = "Prune",
                            ) { viewModel.dockerPruneVolumes() }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = OmniColors.amber),
                    ) { Text(stringResource(R.string.prune_unused)) }
                }
            }
        }
        if (volumes.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().padding(top = 48.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.no_volumes_found_on_this_host), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        items(volumes, key = { volumeKey(it) }) { vol ->
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.purple) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (isSelectionMode) {
                        Checkbox(checked = volumeKey(vol) in selectedIds, onCheckedChange = { if (it) selectedIds += volumeKey(vol) else selectedIds -= volumeKey(vol) })
                    }
                    Column(modifier = Modifier.weight(1f).padding(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(vol.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            Text("Driver: ${vol.driver}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        }
                        if (vol.size.isNotBlank()) {
                            Text(vol.size, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(end = 8.dp))
                        }
                        StatusDot(online = vol.inUse, color = OmniColors.green, size = 8.dp)
                        Spacer(Modifier.width(4.dp))
                        Text(if (vol.inUse) "In Use" else "Unused", fontSize = 10.sp, color = if (vol.inUse) OmniColors.green else OmniColors.red, fontWeight = FontWeight.Bold)
                    }
                    if (vol.mountpoint.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(vol.mountpoint, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End
                    ) {
                        OmniButton(
                            label = "Remove",
                            onClick = {
                                confirm.ask("Remove Volume?", "Permanently remove volume ${vol.name}?", confirmLabel = "Remove") {
                                    viewModel.dockerVolumeAction(vol.name, "remove", vol.runtime)
                                }
                            },
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

@Composable
private fun NetworkList(viewModel: AppViewModel, networks: List<SimDockerNetwork>) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Button(
                    onClick = {
                        confirm.ask(
                            "Prune Unused Networks?",
                            "Remove all networks not used by any container (network prune). This cannot be undone.",
                            confirmLabel = "Prune",
                        ) { viewModel.dockerPruneNetworks() }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = OmniColors.amber),
                ) { Text(stringResource(R.string.prune_unused)) }
            }
        }
        if (networks.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().padding(top = 48.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.no_networks_found_on_this_host), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        items(networks, key = { "${it.runtime}:${it.id}" }) { net ->
            val isBuiltin = net.name in setOf("bridge", "host", "none")
            OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
                Column(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(net.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            Text("Driver: ${net.driver}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        }
                        OmniTag(label = net.driver, color = when (net.driver) {
                            "bridge" -> OmniColors.cyan
                            "host" -> OmniColors.purple
                            "overlay" -> OmniColors.green
                            "macvlan", "ipvlan" -> OmniColors.amber
                            else -> OmniColors.cyan
                        })
                    }
                    if (net.subnet.isNotBlank() || net.gateway.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            if (net.subnet.isNotBlank()) Text("Subnet: ${net.subnet}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                            if (net.gateway.isNotBlank()) Text("GW: ${net.gateway}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono)
                        }
                    }
                    if (net.containerCount > 0) {
                        Spacer(Modifier.height(2.dp))
                        Text("${net.containerCount} container${if (net.containerCount != 1) "s" else ""}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Spacer(Modifier.height(4.dp))
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Text(net.id.take(12), fontSize = 10.sp, color = MaterialTheme.colorScheme.outline, fontFamily = OmniFonts.mono)
                        if (!isBuiltin) {
                            OmniButton(
                                label = "Remove",
                                onClick = {
                                    confirm.ask("Remove Network?", "Permanently remove network ${net.name}?", confirmLabel = "Remove") {
                                        viewModel.dockerNetworkAction(net.id, "remove", net.runtime)
                                    }
                                },
                                color = OmniColors.red,
                                small = true,
                            )
                        }
                    }
                }
            }
        }
    }
}
