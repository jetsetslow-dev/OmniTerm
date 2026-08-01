package com.jetsetslow.omniterm.shared.platform

import com.jetsetslow.omniterm.shared.core.OperationId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertFailsWith

/**
 * Proves the conformance suite itself: a compliant fake passes, and adapters that break the two
 * rules most likely to be broken by a real engine — leaking a raw error and opening a shell for an
 * unreachable host — fail.
 */
class SshAdapterConformanceSelfTest {
    private val endpoint = SshEndpoint("a.example", 22, "root")
    private val unreachable = SshEndpoint("down.example", 22, "root")

    @Test
    fun aCompliantAdapterPasses() = runTest {
        SshAdapterConformance(CompliantAdapter(), endpoint, unreachable).runAll()
    }

    @Test
    fun anAdapterThatConnectsToAnUnreachableHostFails() = runTest {
        val adapter = object : SshAdapter by CompliantAdapter() {
            override suspend fun openShell(endpoint: SshEndpoint, columns: Int, rows: Int) =
                CapabilityResult.Available(FakeConformanceShell() as SshShell)
        }
        assertFailsWith<AssertionError> {
            SshAdapterConformance(adapter, endpoint, unreachable).runAll()
        }
    }

    @Test
    fun anAdapterPresentingAMalformedKeyFails() = runTest {
        val adapter = object : SshAdapter by CompliantAdapter() {
            override suspend fun presentedHostKey(endpoint: SshEndpoint) =
                CapabilityResult.Available(HostKey("ssh-ed25519", "MD5:aa:bb:cc"))
        }
        assertFailsWith<AssertionError> {
            SshAdapterConformance(adapter, endpoint, unreachable).runAll()
        }
    }
}

private class FakeConformanceShell : SshShell {
    override val id = OperationId("fake")
    var closes = 0
    override val output: Flow<ByteArray> = flow { emit("hi\n".encodeToByteArray()) }
    override suspend fun send(bytes: ByteArray) = CapabilityResult.Available(Unit)
    override suspend fun resize(columns: Int, rows: Int) = CapabilityResult.Available(Unit)
    override suspend fun close() {
        closes++
    }

    override fun cancel() = Unit
}

private class CompliantAdapter : SshAdapter {
    override suspend fun presentedHostKey(endpoint: SshEndpoint): CapabilityResult<HostKey> =
        CapabilityResult.Available(HostKey("ssh-ed25519", "SHA256:" + "A".repeat(43)))

    override suspend fun command(endpoint: SshEndpoint, command: String): CapabilityResult<CommandResult> =
        CapabilityResult.Available(CommandResult(0, "", ""))

    override suspend fun openShell(endpoint: SshEndpoint, columns: Int, rows: Int): CapabilityResult<SshShell> =
        if (endpoint.host == "down.example") {
            CapabilityResult.Failed(PlatformError.NetworkUnavailable)
        } else {
            CapabilityResult.Available(FakeConformanceShell())
        }
}
