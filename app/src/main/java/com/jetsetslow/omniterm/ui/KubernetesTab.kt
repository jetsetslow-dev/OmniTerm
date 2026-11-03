package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.automirrored.filled.EventNote
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.KubeConfigFile
import com.jetsetslow.omniterm.data.KubeContextConfig
import com.jetsetslow.omniterm.data.Kube
import com.jetsetslow.omniterm.data.KubeDeployment
import com.jetsetslow.omniterm.data.KubeHealth
import com.jetsetslow.omniterm.data.KubeNode
import com.jetsetslow.omniterm.data.KubePod
import com.jetsetslow.omniterm.data.KubeService
import com.jetsetslow.omniterm.data.KubeSnapshot
import com.jetsetslow.omniterm.data.KubeView
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * The Containers screen's Kubernetes tab: the cluster that the kubectl on [srv] reaches, with its
 * pods, deployments, services and nodes, in the context and namespace picked for this host.
 */
@Composable
internal fun KubernetesTab(viewModel: AppViewModel, srv: ServerEntity) {
    val id = srv.id
    val key = viewModel.kubeKey(id)
    val snapshot = viewModel.kubeSnapshots[key]
    val error = viewModel.kubeErrors[key]
    LaunchedEffect(key) {
        if (viewModel.kubeSnapshots[key] == null && viewModel.kubeLoading[key] != true) viewModel.loadKubernetes(srv)
    }
    Column(Modifier.fillMaxSize()) {
        // Always shown, so a host without kubectl can still reach a saved cluster or import one.
        KubeSourcePicker(viewModel, srv)
        Spacer(Modifier.height(6.dp))
        Box(Modifier.fillMaxWidth().weight(1f)) {
            when {
                error != null -> KubeErrorPanel(viewModel, id, error)
                snapshot == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                else -> KubeCluster(viewModel, id, snapshot)
            }
        }
    }
}

/** Which cluster the tab shows: the host's kubectl or a saved one; also imports and removes saved ones. */
@Composable
private fun KubeSourcePicker(viewModel: AppViewModel, srv: ServerEntity) {
    val clusters by viewModel.kubeClusters.collectAsStateWithLifecycle()
    val cluster = viewModel.kubeCluster(srv.id)
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    var open by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf<List<KubeContextConfig>?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }
    val pickKubeconfig = rememberTextFilePicker { text ->
        try {
            importing = KubeConfigFile.parse(text)
        } catch (e: KubeConfigFile.Invalid) {
            importError = e.message
        }
    }
    val viaHost = stringResource(R.string.kube_via_host, srv.name)
    Box {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.fillMaxWidth().testTag("kube.source")) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.kube_cluster), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(cluster?.name ?: viaHost, fontSize = 12.sp, fontFamily = OmniFonts.mono, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(viaHost, fontSize = 13.sp) },
                onClick = {
                    open = false
                    viewModel.setKubeSource(srv.id, null)
                },
                modifier = Modifier.testTag("kube.source.host"),
            )
            clusters.forEach { saved ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(saved.name, fontFamily = OmniFonts.mono, fontSize = 13.sp)
                            Text(saved.server, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    },
                    onClick = {
                        open = false
                        viewModel.setKubeSource(srv.id, saved.id)
                    },
                    modifier = Modifier.testTag("kube.source.cluster.${saved.name}"),
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.kube_import_kubeconfig), fontSize = 13.sp) },
                leadingIcon = { Icon(Icons.Filled.UploadFile, contentDescription = null) },
                onClick = {
                    open = false
                    pickKubeconfig()
                },
                modifier = Modifier.testTag("kube.source.import"),
            )
            if (cluster != null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.kube_remove_cluster, cluster.name), color = OmniColors.red, fontSize = 13.sp) },
                    leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = OmniColors.red) },
                    onClick = {
                        open = false
                        confirm.ask(
                            confirm.str(R.string.kube_remove_cluster_title),
                            confirm.str(R.string.kube_remove_cluster_message, cluster.name),
                            confirmLabel = confirm.str(R.string.remove),
                        ) { viewModel.deleteKubeCluster(cluster.id) }
                    },
                    modifier = Modifier.testTag("kube.source.remove"),
                )
            }
        }
    }
    importing?.let { contexts ->
        KubeImportDialog(contexts, onDismiss = { importing = null }) { picked ->
            importing = null
            viewModel.saveKubeClusters(srv.id, picked)
        }
    }
    importError?.let { message ->
        AlertDialog(
            onDismissRequest = { importError = null },
            title = { Text(stringResource(R.string.kube_import_title)) },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { importError = null }) { Text(stringResource(R.string.ok)) } },
        )
    }
}

/**
 * Picks which of a kubeconfig's contexts to save, with each one's address editable: a kubeconfig
 * written on the cluster's own machine often names 127.0.0.1, which the phone cannot reach.
 */
@Composable
private fun KubeImportDialog(contexts: List<KubeContextConfig>, onDismiss: () -> Unit, onSave: (List<KubeContextConfig>) -> Unit) {
    var chosen by remember { mutableStateOf(contexts.filter { it.unsupported == null }.map { it.name }.toSet()) }
    var addresses by remember { mutableStateOf(contexts.associate { it.name to it.server }) }
    fun validAddress(name: String) = addresses[name].orEmpty().trim().let { it.startsWith("https://") && it.length > "https://".length }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.kube_import_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    stringResource(
                        if (contexts.any { it.unsupported == null }) R.string.kube_import_explainer else R.string.kube_import_none,
                    ),
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                contexts.forEach { context ->
                    val usable = context.unsupported == null
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                        Checkbox(
                            checked = context.name in chosen,
                            onCheckedChange = { on -> chosen = if (on) chosen + context.name else chosen - context.name },
                            enabled = usable,
                            modifier = Modifier.testTag("kube.import.pick.${context.name}"),
                        )
                        Text(context.name, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono, fontSize = 13.sp)
                    }
                    if (!usable) {
                        Text(context.unsupported.orEmpty(), fontSize = 11.sp, color = OmniColors.red)
                    } else if (context.name in chosen) {
                        OutlinedTextField(
                            value = addresses[context.name].orEmpty(),
                            onValueChange = { addresses = addresses + (context.name to it) },
                            label = { Text(stringResource(R.string.kube_address)) },
                            singleLine = true,
                            isError = !validAddress(context.name),
                            supportingText = if (validAddress(context.name)) null else ({ Text(stringResource(R.string.kube_address_error)) }),
                            modifier = Modifier.fillMaxWidth().testTag("kube.import.address.${context.name}"),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(contexts.filter { it.name in chosen }.map { it.copy(server = addresses[it.name].orEmpty().trim().trimEnd('/')) }) },
                enabled = chosen.isNotEmpty() && chosen.all(::validAddress),
                modifier = Modifier.testTag("kube.import.save"),
            ) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun KubeErrorPanel(viewModel: AppViewModel, serverId: Int, error: String) {
    val hint = Kube.hint(error)
    RemoteErrorPanel(
        title = stringResource(R.string.kube_could_not_reach_cluster),
        error = error,
        hint = when {
            error == Kube.NO_KUBECTL -> stringResource(R.string.kube_install_hint)
            hint == Kube.Hint.K3sRootOnly -> stringResource(R.string.kube_k3s_root_only_hint)
            hint == Kube.Hint.NoCluster -> stringResource(R.string.kube_no_cluster_hint)
            else -> null
        },
    ) {
        if (hint == Kube.Hint.K3sRootOnly) {
            Text(
                Kube.K3S_COPY_CONFIG,
                fontFamily = OmniFonts.mono,
                fontSize = 11.sp,
                modifier = Modifier.padding(top = 6.dp),
            )
            TextButton(onClick = { viewModel.kubeCopyK3sConfig(serverId) }, modifier = Modifier.testTag("kube.copyK3sConfig")) {
                Text(stringResource(R.string.kube_copy_config_in_terminal))
            }
        }
    }
}

@Composable
private fun KubeCluster(viewModel: AppViewModel, serverId: Int, snapshot: KubeSnapshot) {
    val scope = viewModel.kubeScope(serverId)
    val loading = viewModel.kubeLoading[viewModel.kubeKey(serverId)] == true
    // A saved cluster is one context already; only a host's kubectl offers others.
    val viaHost = viewModel.kubeCluster(serverId) == null
    // Ages count from when the lists arrived, like the rest of what they show.
    val now = remember(snapshot) { System.currentTimeMillis() }
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val setup = snapshot.setup
            val current = setup.currentContext
            if (viaHost) KubePicker(
                label = stringResource(R.string.kube_context),
                value = scope.context ?: current ?: stringResource(R.string.kube_no_context),
                options = setup.contexts.map { name ->
                    // The current context is picked by naming none, so kubectl's own choice is followed.
                    (if (name == current) null else name) to
                        if (name == current) stringResource(R.string.kube_current_context, name) else name
                },
                onPick = { viewModel.setKubeContext(serverId, it) },
                tag = "kube.context",
                modifier = Modifier.weight(1f),
            )
            KubePicker(
                label = stringResource(R.string.kube_namespace),
                value = scope.namespace.ifBlank { stringResource(R.string.kube_all_namespaces) },
                options = listOf("" to stringResource(R.string.kube_all_namespaces)) + snapshot.namespaces.map { it to it },
                onPick = { viewModel.setKubeNamespace(serverId, it.orEmpty()) },
                tag = "kube.namespace",
                modifier = Modifier.weight(1f),
            )
            OutlinedButton(onClick = { viewModel.kubeEvents(serverId) }, modifier = Modifier.testTag("kube.events")) {
                Icon(Icons.AutoMirrored.Filled.EventNote, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.kube_events), fontSize = 12.sp)
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            KubeView.entries.forEach { view ->
                val count = when (view) {
                    KubeView.Pods -> snapshot.pods.size
                    KubeView.Deployments -> snapshot.deployments.size
                    KubeView.Services -> snapshot.services.size
                    KubeView.Nodes -> snapshot.nodes.size
                }
                FilterChip(
                    selected = scope.view == view,
                    onClick = { viewModel.setKubeView(serverId, view) },
                    label = { Text(stringResource(R.string.kube_view_count, stringResource(view.label), count), fontSize = 12.sp) },
                    modifier = Modifier.testTag("kube.view.${view.name}"),
                )
            }
            if (loading) CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        }
        val viewError = snapshot.errors[scope.view]
        Box(Modifier.fillMaxWidth().weight(1f)) {
            if (viewError != null) {
                KubeErrorPanel(viewModel, serverId, viewError)
            } else {
                when (scope.view) {
                    KubeView.Pods -> PodList(viewModel, serverId, snapshot.pods, now)
                    KubeView.Deployments -> DeploymentList(viewModel, serverId, snapshot.deployments, now)
                    KubeView.Services -> ServiceList(viewModel, serverId, snapshot.services)
                    KubeView.Nodes -> NodeList(viewModel, serverId, snapshot.nodes, now)
                }
            }
        }
    }
}

private val KubeView.label: Int
    get() = when (this) {
        KubeView.Pods -> R.string.kube_view_pods
        KubeView.Deployments -> R.string.kube_view_deployments
        KubeView.Services -> R.string.kube_view_services
        KubeView.Nodes -> R.string.kube_view_nodes
    }

@Composable
private fun healthColor(health: KubeHealth): Color = when (health) {
    KubeHealth.Ok -> OmniColors.green
    KubeHealth.Progressing -> OmniColors.amber
    KubeHealth.Failed -> OmniColors.red
    KubeHealth.Idle -> MaterialTheme.colorScheme.outline
}

/** A labelled value that opens a menu of [options] (value to pick, text shown). */
@Composable
private fun KubePicker(
    label: String,
    value: String,
    options: List<Pair<String?, String>>,
    onPick: (String?) -> Unit,
    tag: String,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.fillMaxWidth().testTag(tag)) {
            Column(Modifier.weight(1f)) {
                Text(label, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(value, fontSize = 12.sp, fontFamily = OmniFonts.mono, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (pick, text) ->
                DropdownMenuItem(
                    text = { Text(text, fontFamily = OmniFonts.mono, fontSize = 13.sp) },
                    onClick = {
                        open = false
                        onPick(pick)
                    },
                    modifier = Modifier.testTag("$tag.option.${pick.orEmpty()}"),
                )
            }
        }
    }
}

@Composable
private fun EmptyList(text: String) {
    Box(Modifier.fillMaxWidth().padding(top = 48.dp), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun KubeCardHeader(name: String, detail: String, state: String, stateColor: Color) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name, fontWeight = FontWeight.Bold, fontSize = 14.sp, fontFamily = OmniFonts.mono, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (detail.isNotBlank()) {
                Text(detail, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontFamily = OmniFonts.mono, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(state, fontWeight = FontWeight.Bold, color = stateColor, fontSize = 13.sp)
    }
}

@Composable
private fun KubeLine(text: String) {
    Text(text, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun KubeActions(content: @Composable () -> Unit) {
    FlowRow(
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) { content() }
}

@Composable
private fun PodList(viewModel: AppViewModel, serverId: Int, pods: List<KubePod>, now: Long) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    OverflowLazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (pods.isEmpty()) item { EmptyList(stringResource(R.string.kube_no_pods)) }
        items(pods, key = { "${it.namespace}/${it.name}" }) { pod ->
            val color = healthColor(pod.health)
            OmniCard(modifier = Modifier.fillMaxWidth().testTag("kube.pod.${pod.namespace}.${pod.name}"), leftAccent = color) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    KubeCardHeader(
                        name = pod.name,
                        detail = listOf(pod.namespace, pod.node, pod.ip).filter { it.isNotBlank() }.joinToString(" · "),
                        state = pod.status,
                        stateColor = color,
                    )
                    KubeLine(stringResource(R.string.kube_pod_line, pod.ready, pod.total, pod.restarts, Kube.age(pod.startedAt, now)))
                    KubeActions {
                        OmniButton(stringResource(R.string.logs), onClick = { viewModel.kubePodLogs(serverId, pod) }, small = true)
                        OmniButton(stringResource(R.string.follow), onClick = { viewModel.kubePodLogs(serverId, pod, follow = true) }, small = true)
                        if (pod.restarts > 0) {
                            OmniButton(stringResource(R.string.kube_previous_logs), onClick = { viewModel.kubePodLogs(serverId, pod, previous = true) }, color = OmniColors.amber, small = true)
                        }
                        PodShellButton(enabled = pod.status == "Running", containers = pod.containers) { container ->
                            viewModel.kubeExec(serverId, pod, container)
                        }
                        OmniButton(stringResource(R.string.kube_describe), onClick = { viewModel.kubeDescribe(serverId, "pod", pod.namespace, pod.name) }, small = true)
                        OmniButton(
                            stringResource(R.string.delete),
                            onClick = {
                                confirm.ask(
                                    confirm.str(R.string.kube_delete_pod_title),
                                    confirm.str(R.string.kube_delete_pod_message, pod.name, pod.namespace),
                                    confirmLabel = confirm.str(R.string.delete),
                                ) { viewModel.kubeDeletePod(serverId, pod) }
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

/** Opens a shell in a pod; with several containers it asks which first. */
@Composable
private fun PodShellButton(enabled: Boolean, containers: List<String>, onOpen: (String?) -> Unit) {
    var choosing by remember { mutableStateOf(false) }
    Box {
        OmniButton(
            stringResource(R.string.shell),
            onClick = { if (containers.size > 1) choosing = true else onOpen(null) },
            color = OmniColors.green,
            small = true,
            enabled = enabled,
        )
        DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
            Text(
                stringResource(R.string.kube_choose_container),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
            containers.forEach { container ->
                DropdownMenuItem(
                    text = { Text(container, fontFamily = OmniFonts.mono, fontSize = 13.sp) },
                    onClick = {
                        choosing = false
                        onOpen(container)
                    },
                )
            }
        }
    }
}

@Composable
private fun DeploymentList(viewModel: AppViewModel, serverId: Int, deployments: List<KubeDeployment>, now: Long) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    var scaling by remember { mutableStateOf<KubeDeployment?>(null) }
    scaling?.let { deployment ->
        ScaleDialog(deployment, onDismiss = { scaling = null }) { replicas ->
            scaling = null
            viewModel.kubeScale(serverId, deployment, replicas)
        }
    }
    OverflowLazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (deployments.isEmpty()) item { EmptyList(stringResource(R.string.kube_no_deployments)) }
        items(deployments, key = { "${it.namespace}/${it.name}" }) { deployment ->
            val color = healthColor(deployment.health)
            OmniCard(modifier = Modifier.fillMaxWidth().testTag("kube.deployment.${deployment.namespace}.${deployment.name}"), leftAccent = color) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    KubeCardHeader(
                        name = deployment.name,
                        detail = deployment.namespace,
                        state = "${deployment.ready}/${deployment.desired}",
                        stateColor = color,
                    )
                    KubeLine(
                        stringResource(
                            R.string.kube_deployment_line,
                            deployment.upToDate,
                            deployment.available,
                            Kube.age(deployment.createdAt, now),
                        ),
                    )
                    if (deployment.images.isNotEmpty()) {
                        Text(
                            deployment.images.joinToString(", "),
                            fontSize = 11.sp,
                            fontFamily = OmniFonts.mono,
                            color = MaterialTheme.colorScheme.outline,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = 2.dp),
                        )
                    }
                    KubeActions {
                        OmniButton(stringResource(R.string.logs), onClick = { viewModel.kubeDeploymentLogs(serverId, deployment) }, small = true)
                        OmniButton(stringResource(R.string.scale), onClick = { scaling = deployment }, color = OmniColors.green, small = true)
                        OmniButton(
                            stringResource(R.string.restart),
                            onClick = {
                                confirm.ask(
                                    confirm.str(R.string.kube_restart_title),
                                    confirm.str(R.string.kube_restart_message, deployment.name),
                                    confirmLabel = confirm.str(R.string.restart),
                                    destructive = false,
                                ) { viewModel.kubeRestart(serverId, deployment) }
                            },
                            color = OmniColors.amber,
                            small = true,
                        )
                        OmniButton(stringResource(R.string.kube_describe), onClick = { viewModel.kubeDescribe(serverId, "deployment", deployment.namespace, deployment.name) }, small = true)
                    }
                }
            }
        }
    }
}

@Composable
private fun ScaleDialog(deployment: KubeDeployment, onDismiss: () -> Unit, onScale: (Int) -> Unit) {
    var text by rememberSaveable(deployment.namespace, deployment.name) { mutableStateOf(deployment.desired.toString()) }
    val replicas = text.toIntOrNull()?.takeIf { it in 0..Kube.MAX_REPLICAS }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.kube_scale_title, deployment.name)) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it.filter(Char::isDigit).take(4) },
                label = { Text(stringResource(R.string.kube_replicas)) },
                singleLine = true,
                isError = replicas == null,
                supportingText = if (replicas == null) {
                    { Text(stringResource(R.string.kube_replicas_error, Kube.MAX_REPLICAS)) }
                } else {
                    null
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth().testTag("kube.scale.replicas"),
            )
        },
        confirmButton = {
            TextButton(onClick = { replicas?.let(onScale) }, enabled = replicas != null, modifier = Modifier.testTag("kube.scale.confirm")) {
                Text(stringResource(R.string.scale))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun ServiceList(viewModel: AppViewModel, serverId: Int, services: List<KubeService>) {
    OverflowLazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (services.isEmpty()) item { EmptyList(stringResource(R.string.kube_no_services)) }
        items(services, key = { "${it.namespace}/${it.name}" }) { service ->
            OmniCard(modifier = Modifier.fillMaxWidth().testTag("kube.service.${service.namespace}.${service.name}"), leftAccent = OmniColors.cyan) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    KubeCardHeader(name = service.name, detail = service.namespace, state = service.type, stateColor = OmniColors.cyan)
                    if (service.clusterIp.isNotBlank() && service.clusterIp != "None") {
                        KubeLine(stringResource(R.string.kube_cluster_ip, service.clusterIp))
                    }
                    if (service.ports.isNotEmpty()) KubeLine(stringResource(R.string.kube_ports, service.ports.joinToString(", ")))
                    if (service.external.isNotEmpty()) KubeLine(stringResource(R.string.kube_external, service.external.joinToString(", ")))
                    KubeActions {
                        OmniButton(stringResource(R.string.kube_describe), onClick = { viewModel.kubeDescribe(serverId, "service", service.namespace, service.name) }, small = true)
                    }
                }
            }
        }
    }
}

@Composable
private fun NodeList(viewModel: AppViewModel, serverId: Int, nodes: List<KubeNode>, now: Long) {
    val confirm = rememberConfirm()
    ConfirmHost(confirm)
    OverflowLazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (nodes.isEmpty()) item { EmptyList(stringResource(R.string.kube_no_nodes)) }
        items(nodes, key = { it.name }) { node ->
            val color = healthColor(node.health)
            OmniCard(modifier = Modifier.fillMaxWidth().testTag("kube.node.${node.name}"), leftAccent = color) {
                Column(Modifier.fillMaxWidth().padding(12.dp)) {
                    KubeCardHeader(
                        name = node.name,
                        detail = listOf(node.internalIp, node.version).filter { it.isNotBlank() }.joinToString(" · "),
                        state = stringResource(
                            when {
                                !node.ready -> R.string.kube_node_not_ready
                                !node.schedulable -> R.string.kube_scheduling_disabled
                                else -> R.string.kube_node_ready
                            },
                        ),
                        stateColor = color,
                    )
                    if (node.roles.isNotEmpty()) {
                        Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            node.roles.forEach { OmniTag(it, color = OmniColors.cyan) }
                        }
                    }
                    KubeLine(
                        listOf(node.os, node.cpu, node.memory, stringResource(R.string.kube_age, Kube.age(node.createdAt, now)))
                            .filter { it.isNotBlank() }.joinToString(" · "),
                    )
                    KubeActions {
                        OmniButton(stringResource(R.string.kube_describe), onClick = { viewModel.kubeDescribe(serverId, "node", null, node.name) }, small = true)
                        if (node.schedulable) {
                            OmniButton(
                                stringResource(R.string.kube_cordon),
                                onClick = {
                                    confirm.ask(
                                        confirm.str(R.string.kube_cordon_title),
                                        confirm.str(R.string.kube_cordon_message, node.name),
                                        confirmLabel = confirm.str(R.string.kube_cordon),
                                    ) { viewModel.kubeCordon(serverId, node, cordon = true) }
                                },
                                color = OmniColors.amber,
                                small = true,
                            )
                        } else {
                            OmniButton(stringResource(R.string.kube_uncordon), onClick = { viewModel.kubeCordon(serverId, node, cordon = false) }, color = OmniColors.green, small = true)
                        }
                    }
                }
            }
        }
    }
}
