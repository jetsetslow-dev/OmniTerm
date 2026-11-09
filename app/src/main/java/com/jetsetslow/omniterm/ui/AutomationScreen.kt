package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts

/**
 * Tools → Automation: whether other apps may run scripts, the tokens that let them, and how to use
 * one. The switch applies at once; a new token needs App Lock or the phone's screen lock and is
 * shown only once.
 */
@Composable
fun AutomationToolView(viewModel: AppViewModel) {
    val grants by viewModel.automationGrants.collectAsStateWithLifecycle()
    val scripts by viewModel.quickScripts.collectAsStateWithLifecycle()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    var creating by remember { mutableStateOf(false) }
    var newToken by remember { mutableStateOf<String?>(null) }
    var revoking by remember { mutableStateOf<AutomationGrantEntity?>(null) }

    ToolScaffold(viewModel, "Automation", onAdd = { creating = true }) {
        ToolCardColumn {
            ToolSwitchCard(
                title = stringResource(R.string.automation_switch),
                help = stringResource(R.string.automation_switch_help),
                checked = viewModel.automationEnabled,
                onCheckedChange = viewModel::saveAutomationEnabled,
                switchTag = "automation.enabled",
            ) {
                Text(stringResource(R.string.automation_rules), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            SettingsCardHeader(stringResource(R.string.automation_tokens), "", OmniColors.cyan)
            if (grants.isEmpty()) {
                Text(
                    stringResource(R.string.automation_no_tokens),
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("automation.empty"),
                )
            }
            grants.forEach { grant ->
                GrantCard(grant, scripts, servers, onRevoke = { revoking = grant })
            }

            OmniCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.automation_how_title), fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Text(
                        stringResource(
                            R.string.automation_how_tasker,
                            Automation.Plugin.VAR_OUTPUT, Automation.Plugin.VAR_EXIT, Automation.Plugin.VAR_FAILED_HOSTS,
                        ),
                        fontSize = 12.sp,
                    )
                    SelectionContainer {
                        Text(
                            stringResource(
                                R.string.automation_how_intent,
                                Automation.ACTION_RUN, LocalContext.current.packageName, Automation.EXTRA_TOKEN,
                                Automation.EXTRA_REPLY_PACKAGE, Automation.EXTRA_REPLY_ACTION,
                            ),
                            fontSize = 12.sp,
                        )
                    }
                }
            }
        }
    }

    if (creating) {
        NewTokenDialog(
            viewModel, scripts, servers,
            onDismiss = { creating = false },
            onCreated = { token -> creating = false; newToken = token },
        )
    }
    newToken?.let { token -> TokenShownOnceDialog(token, onDone = { newToken = null }) }
    revoking?.let { grant ->
        val name = scripts.find { it.id == grant.scriptId }?.name ?: stringResource(R.string.automation_grant_missing_script)
        AlertDialog(
            onDismissRequest = { revoking = null },
            title = { Text(stringResource(R.string.automation_revoke_title)) },
            text = { Text(stringResource(R.string.automation_revoke_text, name)) },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.revokeAutomationGrant(grant.id); revoking = null },
                    modifier = Modifier.testTag("automation.revoke.confirm"),
                ) { Text(stringResource(R.string.automation_revoke), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { revoking = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/** The hosts of [ids] by name, in [servers]' order; ids no longer saved are left out. */
private fun hostNames(ids: Collection<Int>, servers: List<ServerEntity>): String =
    servers.filter { it.id in ids }.joinToString(", ") { it.name }

@Composable
private fun GrantCard(grant: AutomationGrantEntity, scripts: List<QuickScriptEntity>, servers: List<ServerEntity>, onRevoke: () -> Unit) {
    val script = scripts.find { it.id == grant.scriptId }
    OmniCard(modifier = Modifier.fillMaxWidth().testTag("automation.grant.${grant.id}")) {
        Row(modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(grant.label, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                Text(
                    stringResource(
                        R.string.automation_grant_runs,
                        script?.name ?: stringResource(R.string.automation_grant_missing_script),
                        hostNames(Automation.parseServerIds(grant.serverIds), servers),
                    ),
                    fontSize = 12.sp,
                )
                val made = formatShortDateTime(grant.createdAt)
                Text(
                    grant.lastUsedAt?.let { stringResource(R.string.automation_grant_used, made, formatShortDateTime(it)) }
                        ?: stringResource(R.string.automation_grant_never_used, made),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            TextButton(onClick = onRevoke, modifier = Modifier.testTag("automation.grant.${grant.id}.revoke")) {
                Text(stringResource(R.string.automation_revoke), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/**
 * Picks the script and hosts for a new token. The script must be one automation can run; the
 * token is made only after App Lock or the phone's screen lock.
 */
@Composable
private fun NewTokenDialog(
    viewModel: AppViewModel,
    scripts: List<QuickScriptEntity>,
    servers: List<ServerEntity>,
    onDismiss: () -> Unit,
    onCreated: (String) -> Unit,
) {
    var label by remember { mutableStateOf("") }
    var scriptId by remember { mutableStateOf<Int?>(null) }
    val hostIds = remember { mutableStateListOf<Int>() }
    var picking by remember { mutableStateOf(false) }
    var authenticating by remember { mutableStateOf(false) }
    val script = scriptId?.let { id -> scripts.find { it.id == id } }
    val problem = viewModel.automationProblem(script)
    val hosts = hostNames(hostIds, servers)
    val canMake = problem == null && hostIds.isNotEmpty() && label.isNotBlank()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.automation_new_token)) },
        text = {
            Column(modifier = Modifier.verticalScrollWithIndicators(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = label,
                    onValueChange = { label = it.take(60) },
                    label = { Text(stringResource(R.string.automation_label)) },
                    placeholder = { Text(stringResource(R.string.automation_label_hint)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("automation.new.label"),
                )
                ScriptChoiceField(
                    label = stringResource(R.string.automation_script),
                    choice = script?.let { "${it.emoji} ${it.name}" } ?: stringResource(R.string.automation_pick_script),
                    error = problem?.takeIf { script != null },
                    tag = "automation.new.script",
                    onClick = { picking = true },
                )
                HostPickerField(
                    label = stringResource(R.string.automation_hosts),
                    servers = servers,
                    selectedIds = hostIds.toSet(),
                    onToggle = { id -> if (!hostIds.remove(id)) hostIds.add(id) },
                    modifier = Modifier.testTag("automation.new.hosts"),
                )
                if (hostIds.isEmpty()) {
                    Text(stringResource(R.string.automation_pick_hosts), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { authenticating = true },
                enabled = canMake,
                modifier = Modifier.testTag("automation.new.make"),
            ) { Text(stringResource(R.string.automation_make)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
    if (picking) {
        ScriptPickerDialog(
            title = stringResource(R.string.automation_pick_script),
            scripts = scripts.sortedWith(compareBy<QuickScriptEntity> { it.name.lowercase() }.thenBy { it.id }),
            emptyText = stringResource(R.string.no_scripts_saved_yet),
            onPick = { picked -> picked?.let { scriptId = it.id }; picking = false },
            onDismiss = { picking = false },
        )
    }
    if (authenticating && script != null) {
        SensitiveActionDialog(
            viewModel = viewModel,
            key = Triple(script.id, hostIds.toList(), label),
            title = R.string.automation_authenticate,
            question = stringResource(R.string.automation_make_question, script.name, hosts),
            biometricSubtitle = R.string.confirm_it_s_you,
            noScreenLockText = R.string.automation_no_screen_lock,
            onCancel = { authenticating = false },
            onAuthenticated = {
                authenticating = false
                viewModel.createAutomationGrant(script.id, hostIds.toList(), label, onCreated)
            },
            confirmTag = "automation.new.confirm",
        )
    }
}

/**
 * The new token, once: copied as sensitive text, which the clipboard forgets after a minute, on
 * the app's own scope so that happens after this screen has closed too.
 */
@Composable
internal fun TokenShownOnceDialog(token: String, onDone: () -> Unit, onceText: String = stringResource(R.string.automation_token_once), tag: String = "automation.token") {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.automation_token_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(onceText, fontSize = 13.sp)
                SelectionContainer {
                    Text(token, fontFamily = OmniFonts.mono, fontSize = 14.sp, modifier = Modifier.testTag(tag))
                }
                if (copied) {
                    Text(stringResource(R.string.automation_token_copied), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { copySensitiveClipboard(context.applicationContext, TerminalSessionManager.scope, "OmniTerm token", token); copied = true },
                modifier = Modifier.testTag("$tag.copy"),
            ) { Text(stringResource(R.string.copy)) }
        },
        dismissButton = {
            TextButton(onClick = onDone, modifier = Modifier.testTag("$tag.done")) { Text(stringResource(R.string.done)) }
        },
    )
}
