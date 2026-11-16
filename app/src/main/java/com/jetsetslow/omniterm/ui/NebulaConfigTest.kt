package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.tunnel.TunnelProbe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Tests only the pasted configuration. An edit keeps its stored identity off the screen. */
@Composable
internal fun NebulaConfigTest(config: String, valid: Boolean) {
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("22") }
    var busy by remember { mutableStateOf(false) }
    var result by remember(config, host, port) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val success = stringResource(R.string.vpn_nebula_test_ok)
    val successRunning = stringResource(R.string.vpn_nebula_test_ok_running)
    OutlinedTextField(
        value = host, onValueChange = { host = it }, singleLine = true,
        label = { Text(stringResource(R.string.vpn_nebula_test_host)) },
        modifier = Modifier.fillMaxWidth().testTag("vpn.nebula.host"),
    )
    OutlinedTextField(
        value = port, onValueChange = { port = it }, singleLine = true,
        label = { Text(stringResource(R.string.vpn_nebula_test_port)) },
        modifier = Modifier.fillMaxWidth().testTag("vpn.nebula.port"),
    )
    TextButton(
        enabled = valid && !busy && host.isNotBlank(),
        onClick = {
            busy = true
            scope.launch {
                result = withContext(Dispatchers.IO) {
                    runCatching { TunnelProbe.nebula(config, host, port.toIntOrNull() ?: 0) }
                        .fold({ if (it) successRunning else success }, { it.message ?: "The connection through Nebula failed." })
                }
                busy = false
            }
        },
        modifier = Modifier.testTag("vpn.nebula.test"),
    ) { Text(stringResource(if (busy) R.string.vpn_nebula_testing else R.string.vpn_nebula_test)) }
    result?.let { Text(it, modifier = Modifier.testTag("vpn.nebula.result")) }
}
