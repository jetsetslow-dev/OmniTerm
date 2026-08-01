package com.jetsetslow.omniterm.shared.platform

import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The behavior every [SshAdapter] must exhibit, whatever engine implements it (IOS-051/052).
 *
 * This lives in `commonTest` so each platform's test source set can run it against its own adapter:
 * the JVM/Android adapter wrapping the existing engine, and the iOS adapter once an engine is
 * chosen. Running it against a fake proves the suite itself; running it against a real engine is
 * the acceptance evidence IOS-052 asks for, and until that happens no SSH claim may be made.
 *
 * It deliberately checks *contract* behavior — ownership, typed errors, cancellation, ordering —
 * not protocol details, which need a real server fixture.
 */
class SshAdapterConformance(
    private val adapter: SshAdapter,
    private val endpoint: SshEndpoint,
    private val unreachable: SshEndpoint,
) {
    suspend fun runAll() {
        presentsAHostKeyBeforeAnythingElse()
        opensAShellAndStreamsOutput()
        resizeIsAcceptedWhileStreaming()
        closeIsIdempotent()
        unreachableHostFailsWithATypedError()
    }

    private suspend fun presentsAHostKeyBeforeAnythingElse() {
        val presented = adapter.presentedHostKey(endpoint)
        val key = assertIs<CapabilityResult.Available<HostKey>>(presented).value
        assertTrue(key.algorithm.isNotBlank(), "an adapter must name the key algorithm")
        // The shared trust policy is the only thing allowed to decide; a well-formed fingerprint is
        // the adapter's whole responsibility here.
        assertEquals(null, hostKeyProblem(key), "presented key must satisfy the shared trust policy")
    }

    private suspend fun opensAShellAndStreamsOutput() {
        val opened = adapter.openShell(endpoint, columns = 80, rows = 24)
        val shell = assertIs<CapabilityResult.Available<SshShell>>(opened).value
        try {
            assertIs<CapabilityResult.Available<Unit>>(shell.send("echo hi\n".encodeToByteArray()))
            val chunks = shell.output.take(1).toList()
            assertTrue(chunks.isNotEmpty(), "output must reach the caller as bytes, not decoded text")
        } finally {
            shell.close()
        }
    }

    private suspend fun resizeIsAcceptedWhileStreaming() {
        val shell = assertIs<CapabilityResult.Available<SshShell>>(
            adapter.openShell(endpoint, columns = 80, rows = 24),
        ).value
        try {
            assertIs<CapabilityResult.Available<Unit>>(shell.resize(120, 40))
            // A resize to the same size must still be accepted; the store, not the adapter, decides
            // whether a geometry change is worth sending.
            assertIs<CapabilityResult.Available<Unit>>(shell.resize(120, 40))
        } finally {
            shell.close()
        }
    }

    private suspend fun closeIsIdempotent() {
        val shell = assertIs<CapabilityResult.Available<SshShell>>(
            adapter.openShell(endpoint, columns = 80, rows = 24),
        ).value
        shell.close()
        // Teardown paths can race; a second close must not throw or reopen anything.
        shell.close()
    }

    private suspend fun unreachableHostFailsWithATypedError() {
        val result = adapter.openShell(unreachable, columns = 80, rows = 24)
        when (result) {
            is CapabilityResult.Available -> throw AssertionError("an unreachable host must not open a shell")
            is CapabilityResult.Unsupported -> Unit
            is CapabilityResult.Failed ->
                // The point of the contract: engine-specific message strings never leak upward.
                assertTrue(
                    result.error is PlatformError.NetworkUnavailable ||
                        result.error is PlatformError.NotFound ||
                        result.error is PlatformError.AuthenticationFailed ||
                        result.error is PlatformError.Protocol,
                    "unexpected error type ${result.error}",
                )
        }
    }
}
