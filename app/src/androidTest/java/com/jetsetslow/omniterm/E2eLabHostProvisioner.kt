package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Recreates the manually-provisioned lab SSH host the device suites expect
 * (`E2E Foreground Demo`). Not a test of app behaviour — a setup utility for a freshly wiped
 * device, since no suite creates that host and several only `await` it.
 *
 * Credentials are passed as instrumentation arguments so nothing secret is committed. Run both
 * steps after wiping app data — create the row (the repository's Docker runtime fixture, through
 * the reversed ports), then trust the host key:
 *
 * ```
 * ./scripts/test-hosts.sh suite 'E2eLabHostProvisioner#provisionLabHost' \
 *   omniterm_e2e_provision_host=yes host port user pass
 * ./scripts/test-hosts.sh suite 'E2eLabHostProvisioner#trustLabHostKey' omniterm_e2e_trust_host=yes
 * ```
 *
 * A third step is required before any suite that drives the UI through accessibility:
 *
 * ```
 * adb shell dumpsys deviceidle whitelist +com.jetsetslow.omniterm.app.oss
 * ```
 *
 * [E2eLabSeedTest] writes `background_keep_alive=true`, and `AppUi`'s `needsPermissions` is
 * `backgroundKeepAlive && activeSessionCount > 0 && (!hasNotif || !hasBatt)`. A fresh device is
 * never exempt from battery optimisation, so `hasBatt` is false and `FirstRunDialog`
 * ("Keep sessions active in background?") covers the app the moment a session opens. Granting
 * POST_NOTIFICATIONS alone is not enough. The dialog is modal, so
 * `uiAutomation.rootInActiveWindow` then exposes only its own five nodes and every
 * `hasDescription`/`hasText` lookup for the screen underneath fails with no hint as to why.
 *
 * Idempotent: re-running while the host already exists is a no-op.
 */
class E2eLabHostProvisioner {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun provisionLabHost() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_provision_host") == "yes")
        val host = E2eArgs.require("host")
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        val port = args.getString("port")?.toIntOrNull() ?: 22

        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }

        E2eLabHosts.add(vm, HOST_NAME, host, port, user, pass, keepExisting = true)
        Unit
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
        await("host row loaded") { vm.servers.value.any { it.name == HOST_NAME } }
        val host = requireNotNull(vm.servers.value.find { it.name == HOST_NAME }) { "host row missing" }
        E2eLabHosts.connectOnce(vm, host)
        Unit
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
