package com.jetsetslow.omniterm.automation

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The Locale/Tasker plug-in's edit screen. It makes nothing: the user pastes a token made in
 * OmniTerm, sees what it runs and which app will hold it, and saves. An app that opens this screen
 * learns nothing without a token, and one that is not waiting for a result gets nothing to save.
 */
class TaskerEditActivity : ComponentActivity() {

    /** What a pasted token opens, as shown before saving. */
    private data class Grant(val scriptName: String, val hostNames: List<String>, val automationOn: Boolean)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The token is a secret: keep it out of screenshots and the recent-apps preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setResult(RESULT_CANCELED)
        val saved = Automation.Plugin.tokenFrom(runCatching { intent.getBundleExtra(Automation.Plugin.EXTRA_BUNDLE) }.getOrNull())
        val capabilities = runCatching { intent.getIntExtra(Automation.Plugin.EXTRA_HOST_CAPABILITIES, 0) }.getOrDefault(0)
        val caller = callingActivity?.packageName
        val callerLabel = caller?.let { pkg ->
            runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }.getOrNull() ?: pkg
        }
        setContent {
            MyApplicationTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    EditScreen(saved, caller, callerLabel, onCancel = { finish() }, onSave = { token, grant ->
                        setResult(RESULT_OK, resultIntent(token, grant, capabilities))
                        finish()
                    })
                }
            }
        }
    }

    private fun resultIntent(token: String, grant: Grant, capabilities: Int): Intent = Intent()
        .putExtra(Automation.Plugin.EXTRA_BUNDLE, Automation.Plugin.bundleFor(token))
        .putExtra(Automation.Plugin.EXTRA_BLURB, getString(R.string.automation_blurb, grant.scriptName, grant.hostNames.joinToString(", ")))
        .apply {
            if (capabilities and Automation.Plugin.CAPABILITY_SYNCHRONOUS != 0) {
                putExtra(Automation.Plugin.EXTRA_REQUESTED_TIMEOUT, Automation.TASKER_TIMEOUT_MS)
            }
            if (capabilities and Automation.Plugin.CAPABILITY_RELEVANT_VARIABLES != 0) {
                putExtra(
                    Automation.Plugin.EXTRA_RELEVANT_VARIABLES,
                    arrayOf(
                        "${Automation.Plugin.VAR_OUTPUT}\n${getString(R.string.automation_var_output)}\n${getString(R.string.automation_var_output_help)}",
                        "${Automation.Plugin.VAR_EXIT}\n${getString(R.string.automation_var_exit)}\n${getString(R.string.automation_var_exit_help)}",
                        "${Automation.Plugin.VAR_FAILED_HOSTS}\n${getString(R.string.automation_var_failed)}\n${getString(R.string.automation_var_failed_help)}",
                    ),
                )
            }
        }

    private suspend fun lookUp(token: String): Grant? = withContext(Dispatchers.IO) {
        val repository = AutomationJobs.repository(this@TaskerEditActivity)
        val gate = AutomationGate(this@TaskerEditActivity, repository)
        val grant = gate.grantFor(token) ?: return@withContext null
        val script = repository.getAllScripts().find { it.id == grant.scriptId }
        val hosts = Automation.parseServerIds(grant.serverIds).mapNotNull { repository.getServerById(it)?.name }
        Grant(script?.name ?: "?", hosts, gate.enabled())
    }

    @Composable
    private fun EditScreen(
        saved: String?,
        caller: String?,
        callerLabel: String?,
        onCancel: () -> Unit,
        onSave: (String, Grant) -> Unit,
    ) {
        var token by remember { mutableStateOf(saved.orEmpty()) }
        var grant by remember { mutableStateOf<Grant?>(null) }
        var checked by remember { mutableStateOf(false) }
        LaunchedEffect(token) {
            checked = false
            grant = token.trim().takeIf(Automation::looksLikeToken)?.let { lookUp(it) }
            checked = true
        }
        Column(
            modifier = Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.automation_plugin_title), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text(stringResource(R.string.automation_plugin_explain))
            OutlinedTextField(
                value = token,
                onValueChange = { token = it.trim() },
                label = { Text(stringResource(R.string.automation_token)) },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth().testTag("automation.plugin.token"),
            )
            val g = grant
            when {
                g != null -> {
                    Text(
                        stringResource(R.string.automation_plugin_runs, g.scriptName, g.hostNames.joinToString(", ")),
                        modifier = Modifier.testTag("automation.plugin.grant"),
                    )
                    if (!g.automationOn) {
                        Text(stringResource(R.string.automation_plugin_off), color = MaterialTheme.colorScheme.error)
                    }
                }
                checked && token.isNotBlank() -> Text(
                    stringResource(R.string.automation_unknown_token),
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("automation.plugin.unknown"),
                )
            }
            if (caller == null) {
                Text(stringResource(R.string.automation_plugin_no_caller), color = MaterialTheme.colorScheme.error)
            } else {
                Text(stringResource(R.string.automation_plugin_caller, callerLabel ?: caller, caller), modifier = Modifier.testTag("automation.plugin.caller"))
            }
            Spacer(Modifier.padding(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
                Button(
                    onClick = { g?.let { onSave(token.trim(), it) } },
                    enabled = g != null && caller != null,
                    modifier = Modifier.testTag("automation.plugin.save"),
                ) { Text(stringResource(R.string.save)) }
            }
        }
    }
}
