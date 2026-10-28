package com.jetsetslow.omniterm.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DeveloperBoard
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lan
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Monitor
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SpecField
import com.jetsetslow.omniterm.data.SpecItem
import com.jetsetslow.omniterm.data.SpecKind
import com.jetsetslow.omniterm.data.SpecNotice
import com.jetsetslow.omniterm.data.SpecSection
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

@Composable
private fun specTitle(kind: SpecKind): String = stringResource(
    when (kind) {
        SpecKind.System -> R.string.spec_system
        SpecKind.Cpu -> R.string.spec_cpu
        SpecKind.Memory -> R.string.spec_memory
        SpecKind.Storage -> R.string.spec_storage
        SpecKind.Gpu -> R.string.spec_gpu
        SpecKind.Network -> R.string.spec_network
    },
)

private fun specIcon(kind: SpecKind): ImageVector = when (kind) {
    SpecKind.System -> Icons.Filled.Computer
    SpecKind.Cpu -> Icons.Filled.DeveloperBoard
    SpecKind.Memory -> Icons.Filled.Memory
    SpecKind.Storage -> Icons.Filled.Storage
    SpecKind.Gpu -> Icons.Filled.Monitor
    SpecKind.Network -> Icons.Filled.Lan
}

@Composable
private fun noticeText(notice: SpecNotice): String = stringResource(
    when (notice) {
        SpecNotice.ModulesNeedRoot -> R.string.spec_modules_need_root
        SpecNotice.ModulesToolMissing -> R.string.spec_modules_tool_missing
        SpecNotice.NoModulesReported -> R.string.spec_no_modules_reported
        SpecNotice.DriveHealthNeedsRoot -> R.string.spec_drive_health_needs_root
        SpecNotice.DriveHealthToolMissing -> R.string.spec_drive_health_tool_missing
    },
)

/**
 * A host's system specs as collapsible sections, each with its devices collapsible inside it.
 * The one view behind Monitor › Specs and the Hosts tab's pop-up.
 */
@Composable
fun SystemSpecsContent(
    viewModel: AppViewModel,
    srv: ServerEntity,
    modifier: Modifier = Modifier,
) {
    val state = viewModel.systemSpecs[srv.id]
    val specs = state?.specs
    val copy = rememberCopyWithConfirmation()
    val titles = SpecKind.entries.associateWith { specTitle(it) }
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                stringResource(R.string.spec_read_from, srv.name),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = OmniTextSize.Meta,
                modifier = Modifier.weight(1f),
            )
            if (specs != null) {
                IconButton(onClick = { copy(specs.asText { titles.getValue(it) }) }) {
                    Icon(Icons.Filled.ContentCopy, contentDescription = stringResource(R.string.copy_all_specs))
                }
            }
            IconButton(onClick = { viewModel.loadSystemSpecs(srv) }, enabled = state?.loading != true) {
                Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.refresh_specs))
            }
        }
        if (state?.loading == true && specs != null) LinearProgressIndicator(Modifier.fillMaxWidth())
        when {
            specs == null && state?.error != null -> Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.could_not_read_specs, state.error), color = OmniColors.red, fontSize = OmniTextSize.Meta)
                TextButton(onClick = { viewModel.loadSystemSpecs(srv) }) { Text(stringResource(R.string.retry)) }
            }
            specs == null -> Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(Modifier.size(28.dp))
                    Spacer(Modifier.size(8.dp))
                    Text(stringResource(R.string.reading_system_specs), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta)
                }
            }
            else -> LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.error?.let { error ->
                    item { Text(stringResource(R.string.could_not_read_specs, error), color = OmniColors.red, fontSize = OmniTextSize.Meta) }
                }
                if (specs.wouldGainFromSudo || specs.sudoError != null) {
                    item { SudoBanner(viewModel, srv, specs.sudoError) }
                }
                items(specs.sections, key = { it.kind }) { section ->
                    val extra = if (section.kind == SpecKind.System) {
                        listOfNotNull(specs.uptimeSeconds?.let { SpecField(stringResource(R.string.uptime_label), formatUptime(it)) })
                    } else {
                        emptyList()
                    }
                    SpecSectionCard(section, titles.getValue(section.kind), extra)
                }
            }
        }
    }
}

@Composable
private fun SudoBanner(viewModel: AppViewModel, srv: ServerEntity, sudoError: String?) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(OmniColors.amber.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
            .padding(10.dp),
    ) {
        Text(stringResource(R.string.some_specs_need_root), fontSize = OmniTextSize.Meta)
        sudoError?.let {
            Text(stringResource(R.string.sudo_refused, it), color = OmniColors.red, fontSize = OmniTextSize.Meta, modifier = Modifier.padding(top = 4.dp))
            if (srv.sudoPassword.isBlank()) {
                Text(stringResource(R.string.save_a_sudo_password_for_specs), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta)
            }
        }
        OutlinedButton(onClick = { viewModel.readSystemSpecsWithSudo(srv) }, modifier = Modifier.padding(top = 6.dp)) {
            Text(stringResource(R.string.read_with_sudo))
        }
    }
}

@Composable
private fun SpecSectionCard(section: SpecSection, title: String, extraFields: List<SpecField>) {
    var expanded by rememberSaveable(section.kind) { mutableStateOf(false) }
    OmniCard(modifier = Modifier.fillMaxWidth()) {
        ExpandableHeader(expanded, { expanded = !expanded }, title, section.summary, specIcon(section.kind))
        AnimatedVisibility(expanded) {
            Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                (extraFields + section.fields).forEach { SpecFieldRow(it) }
                section.items.forEach { SpecItemCard(it) }
                section.notices.forEach { notice ->
                    Text(noticeText(notice), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta, modifier = Modifier.padding(top = 4.dp))
                }
            }
        }
    }
}

@Composable
private fun SpecItemCard(item: SpecItem) {
    var expanded by rememberSaveable(item.title) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        ExpandableHeader(expanded, { if (item.fields.isNotEmpty()) expanded = !expanded }, item.title, item.summary, null, showChevron = item.fields.isNotEmpty())
        AnimatedVisibility(expanded) {
            Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                item.fields.forEach { SpecFieldRow(it) }
            }
        }
    }
}

@Composable
private fun ExpandableHeader(
    expanded: Boolean,
    onToggle: () -> Unit,
    title: String,
    summary: String,
    icon: ImageVector?,
    showChevron: Boolean = true,
) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onToggle), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = OmniColors.cyan, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (summary.isNotEmpty()) {
                Text(summary, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (showChevron) {
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = stringResource(if (expanded) R.string.collapse else R.string.expand),
            )
        }
    }
}

@Composable
private fun SpecFieldRow(field: SpecField) {
    SelectionContainer {
        if (field.label.isEmpty()) {
            Text(field.value, fontFamily = OmniFonts.mono, fontSize = OmniTextSize.Meta)
        } else {
            Row(Modifier.fillMaxWidth()) {
                Text(field.label, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = OmniTextSize.Meta, modifier = Modifier.weight(0.42f).padding(end = 8.dp))
                Text(field.value, fontSize = OmniTextSize.Meta, modifier = Modifier.weight(0.58f))
            }
        }
    }
}

/** The Hosts tab's pop-up for ⋮ › System specs. */
@Composable
fun SystemSpecsDialog(viewModel: AppViewModel) {
    val srv = viewModel.systemSpecsHost ?: return
    Dialog(onDismissRequest = viewModel::closeSystemSpecs, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            modifier = Modifier.padding(horizontal = 16.dp).widthIn(max = 560.dp).fillMaxWidth().heightIn(max = 720.dp),
            shape = RoundedCornerShape(14.dp),
            tonalElevation = 8.dp,
        ) {
            Column(Modifier.fillMaxWidth().padding(12.dp)) {
                Text(stringResource(R.string.system_specs), style = MaterialTheme.typography.titleLarge)
                SystemSpecsContent(viewModel, srv, Modifier.weight(1f, fill = false))
                TextButton(onClick = viewModel::closeSystemSpecs, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.close))
                }
            }
        }
    }
}

/** Monitor › Specs: reads the selected host's specs the first time it is shown. */
@Composable
fun SpecsTab(viewModel: AppViewModel, srv: ServerEntity) {
    androidx.compose.runtime.LaunchedEffect(srv.id) {
        val state = viewModel.systemSpecs[srv.id]
        if (state?.specs == null && state?.loading != true) viewModel.loadSystemSpecs(srv)
    }
    SystemSpecsContent(viewModel, srv, Modifier.fillMaxSize())
}
