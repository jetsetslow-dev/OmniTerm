package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Recreates the manually-provisioned lab SSH host the device suites expect
 * (`E2E Foreground Demo`). Not a test of app behaviour — a setup utility for a freshly wiped
 * device, since no suite creates that host and several only `await` it.
 *
 * Credentials are passed as instrumentation arguments so nothing secret is committed. Run both
 * steps after wiping app data — create the row, then trust the host key:
 *
 * ```
 * R=com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
 * adb shell am instrument -w -e omniterm_e2e_provision_host yes \
 *   -e host <ip> -e user <name> -e pass '<password>' \
 *   -e class com.jetsetslow.omniterm.E2eLabHostProvisioner#provisionLabHost $R
 * adb shell am instrument -w -e omniterm_e2e_trust_host yes \
 *   -e class com.jetsetslow.omniterm.E2eLabHostProvisioner#trustLabHostKey $R
 * ```
 *
 * Idempotent: re-running while the host already exists is a no-op.
 */
class E2eLabHostProvisioner {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun provisionLabHost() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_provision_host") == "yes")
        val host = requireNotNull(args.getString("host")) { "-e host <ip> is required" }
        val user = requireNotNull(args.getString("user")) { "-e user <name> is required" }
        val pass = requireNotNull(args.getString("pass")) { "-e pass <password> is required" }
        val port = args.getString("port")?.toIntOrNull() ?: 22

        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }

        if (vm.servers.value.any { it.name == HOST_NAME }) return@runBlocking

        var result: String? = "pending"
        composeRule.runOnUiThread {
            vm.addServer(
                name = HOST_NAME,
                host = host,
                port = port,
                username = user,
                group = null,
                authType = "password",
                notes = "",
                keepAlive = 0,
                compression = false,
                proxy = "",
                password = pass,
            ) { error -> result = error }
        }
        await("host row created") { vm.servers.value.any { it.name == HOST_NAME } }
        assertTrue("addServer reported: $result", result == null)
    }

    /**
     * Connects once to trust the host key. A freshly wiped device has an empty known-hosts store,
     * so the first connection parks on a TOFU approval no suite dismisses and every SSH-backed test
     * hangs until timeout. Run this after [provisionLabHost].
     */
    @Test
    fun trustLabHostKey() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_trust_host") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val host = requireNotNull(vm.servers.value.find { it.name == HOST_NAME }) { "host row missing" }
        composeRule.runOnUiThread {
            vm.selectedServerId = host.id
            vm.runFleetBroadcast("printf 'FLEET-SMALL-END\\n'", listOf(host.id))
        }
        repeat(120) {
            composeRule.runOnUiThread { if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true) }
            if (!vm.isBroadcastExecuting) return@repeat
            delay(250)
        }
        await("broadcast settles", 30_000) { !vm.isBroadcastExecuting }
        val result = vm.broadcastResults.singleOrNull()
        assertTrue(
            "probe failed: status=${result?.status} output=${result?.output?.take(200)}",
            result?.output?.contains("FLEET-SMALL-END") == true,
        )
    }

    private suspend fun await(label: String, timeoutMs: Long = 10_000, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (failure: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", failure)
        }
    }

    private companion object { const val HOST_NAME = "E2E Foreground Demo" }
}
