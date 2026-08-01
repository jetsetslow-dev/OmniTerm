package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.OperationId
import com.jetsetslow.omniterm.shared.core.WallClock
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.HostKey
import com.jetsetslow.omniterm.shared.platform.HostKeyTrust
import com.jetsetslow.omniterm.shared.platform.KnownHostsStore
import com.jetsetslow.omniterm.shared.platform.SshAdapter
import com.jetsetslow.omniterm.shared.platform.SshEndpoint
import com.jetsetslow.omniterm.shared.platform.SshShell
import com.jetsetslow.omniterm.shared.platform.hostKeyAlias
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val ED25519 = HostKey("ssh-ed25519", "SHA256:" + "A".repeat(43))
private val RSA = HostKey("ssh-rsa", "SHA256:" + "B".repeat(43))

private class FakeShell(override val id: OperationId = OperationId("shell")) : SshShell {
    val outputFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 16)
    val sent = mutableListOf<ByteArray>()
    val resizes = mutableListOf<Pair<Int, Int>>()
    var closed = false
    var cancelled = false

    override val output: Flow<ByteArray> get() = outputFlow
    override suspend fun send(bytes: ByteArray): CapabilityResult<Unit> {
        sent += bytes
        return CapabilityResult.Available(Unit)
    }

    override suspend fun resize(columns: Int, rows: Int): CapabilityResult<Unit> {
        resizes += columns to rows
        return CapabilityResult.Available(Unit)
    }

    override suspend fun close() {
        closed = true
    }

    override fun cancel() {
        cancelled = true
    }
}

private class FakeSsh(private val keys: Map<String, HostKey> = emptyMap()) : SshAdapter {
    val shells = mutableListOf<FakeShell>()
    val openedFor = mutableListOf<String>()
    /** When set, [openShell] parks until completed so a race can be driven deterministically. */
    var gate: CompletableDeferred<Unit>? = null

    override suspend fun presentedHostKey(endpoint: SshEndpoint): CapabilityResult<HostKey> =
        CapabilityResult.Available(keys[endpoint.host] ?: ED25519)

    override suspend fun command(endpoint: SshEndpoint, command: String) =
        CapabilityResult.Available(com.jetsetslow.omniterm.shared.platform.CommandResult(0, "", ""))

    override suspend fun openShell(endpoint: SshEndpoint, columns: Int, rows: Int): CapabilityResult<SshShell> {
        gate?.await()
        openedFor += endpoint.host
        val shell = FakeShell()
        shells += shell
        return CapabilityResult.Available(shell)
    }
}

private class MemoryKnownHosts : KnownHostsStore {
    val entries = mutableMapOf<String, HostKey>()
    override suspend fun find(alias: String): HostKey? = entries[alias]
    override suspend fun put(alias: String, key: HostKey) {
        entries[alias] = key
    }

    override suspend fun remove(alias: String) {
        entries.remove(alias)
    }
}

private class SequentialIds : IdGenerator {
    private var next = 0
    override fun nextId(): String = "id-${next++}"
}

private fun endpoint(host: String) = SshEndpoint(host, 22, "root")

private fun store(
    scope: CoroutineScope,
    ssh: FakeSsh,
    hosts: MemoryKnownHosts = MemoryKnownHosts(),
    sink: TerminalOutputSink = TerminalOutputSink { _, _ -> },
    history: TerminalHistoryLoader? = null,
) = TerminalStore(
    scope = scope,
    ssh = ssh,
    hostKeyTrust = HostKeyTrust(hosts),
    ids = SequentialIds(),
    clock = WallClock { 1_000L },
    outputSink = sink,
    historyLoader = history,
)

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalStoreTest {
    @Test
    fun firstUseHostKeyRequiresApprovalBeforeTheShellOpens() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val ssh = FakeSsh()
        val hosts = MemoryKnownHosts()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()

        val pending = assertNotNull(terminal.state.value.pendingApproval)
        assertFalse(pending.changed)
        assertTrue(ssh.openedFor.isEmpty(), "shell must not open before the key is trusted")
        assertEquals(TerminalPhase.AwaitingHostKey, terminal.state.value.sessions.single().phase)

        terminal.dispatch(TerminalAction.ResolveHostKey(pending.requestId, trust = true))
        advanceUntilIdle()

        assertEquals(TerminalPhase.Connected, terminal.state.value.sessions.single().phase)
        assertEquals(ED25519, hosts.entries[hostKeyAlias(endpoint("a.example"))])
        assertNull(terminal.state.value.pendingApproval)
        terminal.close()
    }

    @Test
    fun rejectedApprovalLeavesTheSessionDisconnectedAndUntrusted() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val ssh = FakeSsh()
        val hosts = MemoryKnownHosts()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        val pending = assertNotNull(terminal.state.value.pendingApproval)
        terminal.dispatch(TerminalAction.ResolveHostKey(pending.requestId, trust = false))
        advanceUntilIdle()

        assertEquals(TerminalPhase.Disconnected, terminal.state.value.sessions.single().phase)
        assertTrue(hosts.entries.isEmpty())
        assertTrue(ssh.openedFor.isEmpty())
        terminal.close()
    }

    @Test
    fun changedHostKeyIsReportedAsChangedAndNeverSilentlyReplaced() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = RSA }
        val ssh = FakeSsh(mapOf("a.example" to ED25519))
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()

        val pending = assertNotNull(terminal.state.value.pendingApproval)
        assertTrue(pending.changed)
        assertEquals(RSA, pending.previous)

        terminal.dispatch(TerminalAction.ResolveHostKey(pending.requestId, trust = false))
        advanceUntilIdle()

        assertEquals(RSA, hosts.entries[hostKeyAlias(endpoint("a.example"))])
        assertTrue(ssh.openedFor.isEmpty())
        terminal.close()
    }

    @Test
    fun switchingHostMidConnectDiscardsTheSupersededSessionAndClosesItsShell() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply {
            entries[hostKeyAlias(endpoint("a.example"))] = ED25519
            entries[hostKeyAlias(endpoint("b.example"))] = ED25519
        }
        val ssh = FakeSsh()
        val gate = CompletableDeferred<Unit>()
        ssh.gate = gate
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        terminal.dispatch(TerminalAction.Connect(endpoint("b.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        gate.complete(Unit)
        advanceUntilIdle()

        val session = terminal.state.value.sessions.single()
        assertEquals("b.example", session.endpoint.host)
        assertEquals(TerminalPhase.Connected, session.phase)
        // The first attempt's shell may still have been created; it must not stay open.
        assertTrue(ssh.shells.dropLast(1).all { it.closed }, "superseded shells must be closed")
        terminal.close()
    }

    @Test
    fun readOnlySessionDropsInputBelowTheUiLayer() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val ssh = FakeSsh()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        val id = terminal.state.value.sessions.single().id

        terminal.dispatch(TerminalAction.SetReadOnly(id, readOnly = true))
        terminal.dispatch(TerminalAction.SendInput("rm -rf /\n".encodeToByteArray()))
        advanceUntilIdle()
        assertTrue(ssh.shells.single().sent.isEmpty(), "read-only must block every input path")

        terminal.dispatch(TerminalAction.SetReadOnly(id, readOnly = false))
        terminal.dispatch(TerminalAction.SendInput("ls\n".encodeToByteArray()))
        advanceUntilIdle()
        assertEquals("ls\n", ssh.shells.single().sent.single().decodeToString())
        terminal.close()
    }

    @Test
    fun splitInputGoesToTheFocusedPaneOnly() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply {
            entries[hostKeyAlias(endpoint("a.example"))] = ED25519
            entries[hostKeyAlias(endpoint("b.example"))] = ED25519
        }
        val ssh = FakeSsh()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        val first = terminal.state.value.sessions.single().id
        terminal.dispatch(TerminalAction.EnterSplit)
        terminal.dispatch(TerminalAction.FocusPane(1))
        terminal.dispatch(TerminalAction.Connect(endpoint("b.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        val second = terminal.state.value.sessions.first { it.id != first }.id

        assertEquals(listOf(first, second), terminal.state.value.paneSessionIds)
        terminal.dispatch(TerminalAction.SendInput("two".encodeToByteArray()))
        advanceUntilIdle()
        terminal.dispatch(TerminalAction.FocusPane(0))
        terminal.dispatch(TerminalAction.SendInput("one".encodeToByteArray()))
        advanceUntilIdle()

        assertEquals(listOf("one"), ssh.shells[0].sent.map { it.decodeToString() })
        assertEquals(listOf("two"), ssh.shells[1].sent.map { it.decodeToString() })

        // The same session may never own both panes: that would double-apply every keystroke.
        terminal.dispatch(TerminalAction.AssignPane(1, first))
        advanceUntilIdle()
        assertEquals(listOf(null, first), terminal.state.value.paneSessionIds)
        terminal.close()
    }

    @Test
    fun resizeDuringHydrationDiscardsTheResumedHistory() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val ssh = FakeSsh()
        val release = CompletableDeferred<Unit>()
        val terminal = store(scope, ssh, hosts, history = TerminalHistoryLoader { _, _ ->
            release.await()
            List(10_000) { "line $it" }
        })

        terminal.dispatch(
            TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24), persistent = true, tmuxName = "work"),
        )
        advanceUntilIdle()
        val id = terminal.state.value.sessions.single().id

        terminal.dispatch(TerminalAction.Resize(id, TerminalGeometry(120, 40)))
        advanceUntilIdle()
        release.complete(Unit)
        advanceUntilIdle()

        val session = terminal.state.value.sessions.single()
        assertFalse(session.historyHydrated, "history laid out for the old geometry must be discarded")
        assertEquals(0, session.hydratedHistoryLines)
        assertEquals(TerminalGeometry(120, 40), session.geometry)
        assertEquals(listOf(120 to 40), ssh.shells.single().resizes)
        terminal.close()
    }

    @Test
    fun undisturbedHydrationPublishesHistory() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val terminal = store(scope, FakeSsh(), hosts, history = TerminalHistoryLoader { _, _ -> listOf("a", "b") })

        terminal.dispatch(
            TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24), persistent = true, tmuxName = "work"),
        )
        advanceUntilIdle()

        val session = terminal.state.value.sessions.single()
        assertTrue(session.historyHydrated)
        assertEquals(2, session.hydratedHistoryLines)
        terminal.close()
    }

    @Test
    fun leavingATmuxSessionResumableClosesTheShellAndRemembersIt() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val ssh = FakeSsh()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(
            TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24), persistent = true, tmuxName = "work"),
        )
        advanceUntilIdle()
        val id = terminal.state.value.sessions.single().id
        terminal.dispatch(TerminalAction.LeaveOrBackground(id))
        advanceUntilIdle()

        assertTrue(terminal.state.value.sessions.isEmpty())
        assertEquals(listOf("work"), terminal.state.value.resumable.map { it.tmuxName })
        assertEquals(1_000L, terminal.state.value.resumable.single().leftAtEpochMillis)
        assertTrue(ssh.shells.single().closed)
        terminal.close()
    }

    @Test
    fun disconnectDuringReconnectTearsTheSessionDown() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val ssh = FakeSsh()
        val terminal = store(scope, ssh, hosts)

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        val id = terminal.state.value.sessions.single().id

        val gate = CompletableDeferred<Unit>()
        ssh.gate = gate
        terminal.dispatch(TerminalAction.Disconnect(id))
        advanceUntilIdle()
        assertTrue(terminal.state.value.sessions.isEmpty())
        assertTrue(ssh.shells.single().closed)

        // A late reconnect for a session that no longer exists must be a no-op.
        terminal.dispatch(TerminalAction.Reconnect(id))
        gate.complete(Unit)
        advanceUntilIdle()
        assertTrue(terminal.state.value.sessions.isEmpty())
        assertEquals(1, ssh.shells.size)
        terminal.close()
    }

    @Test
    fun serverOutputReachesTheSinkAndCloseReleasesEveryShell() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val hosts = MemoryKnownHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = ED25519 }
        val ssh = FakeSsh()
        val received = mutableListOf<String>()
        val terminal = store(scope, ssh, hosts, sink = { _, bytes -> received += bytes.decodeToString() })

        terminal.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        ssh.shells.single().outputFlow.emit("hello".encodeToByteArray())
        advanceUntilIdle()
        assertEquals(listOf("hello"), received)

        terminal.close()
        advanceUntilIdle()
        assertTrue(ssh.shells.single().closed, "close() must release every open PTY")
        assertTrue(terminal.state.value.sessions.isEmpty())
    }
}
