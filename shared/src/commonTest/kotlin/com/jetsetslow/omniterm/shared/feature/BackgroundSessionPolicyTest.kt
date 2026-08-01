package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.OperationId
import com.jetsetslow.omniterm.shared.core.WallClock
import com.jetsetslow.omniterm.shared.platform.ApplicationLifecycle
import com.jetsetslow.omniterm.shared.platform.ApplicationVisibility
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.HostKey
import com.jetsetslow.omniterm.shared.platform.HostKeyTrust
import com.jetsetslow.omniterm.shared.platform.KnownHostsStore
import com.jetsetslow.omniterm.shared.platform.SshAdapter
import com.jetsetslow.omniterm.shared.platform.SshEndpoint
import com.jetsetslow.omniterm.shared.platform.SshShell
import com.jetsetslow.omniterm.shared.platform.hostKeyAlias
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private val KEY = HostKey("ssh-ed25519", "SHA256:" + "A".repeat(43))

private class BackgroundFakeShell : SshShell {
    override val id = OperationId("shell")
    var closed = false
    override val output: Flow<ByteArray> = MutableSharedFlow()
    override suspend fun send(bytes: ByteArray) = CapabilityResult.Available(Unit)
    override suspend fun resize(columns: Int, rows: Int) = CapabilityResult.Available(Unit)
    override suspend fun close() {
        closed = true
    }

    override fun cancel() = Unit
}

private class BackgroundFakeSsh : SshAdapter {
    val shells = mutableListOf<BackgroundFakeShell>()
    override suspend fun presentedHostKey(endpoint: SshEndpoint) = CapabilityResult.Available(KEY)
    override suspend fun command(endpoint: SshEndpoint, command: String) =
        CapabilityResult.Available(com.jetsetslow.omniterm.shared.platform.CommandResult(0, "", ""))

    override suspend fun openShell(endpoint: SshEndpoint, columns: Int, rows: Int): CapabilityResult<SshShell> {
        val shell = BackgroundFakeShell()
        shells += shell
        return CapabilityResult.Available(shell)
    }
}

private class BackgroundHosts : KnownHostsStore {
    val entries = mutableMapOf<String, HostKey>()
    override suspend fun find(alias: String) = entries[alias]
    override suspend fun put(alias: String, key: HostKey) {
        entries[alias] = key
    }

    override suspend fun remove(alias: String) {
        entries.remove(alias)
    }
}

private class BackgroundIds : IdGenerator {
    private var next = 0
    override fun nextId(): String = "bg-${next++}"
}

private class ScriptedLifecycle(override val visibility: Flow<ApplicationVisibility>) : ApplicationLifecycle

@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundSessionPolicyTest {
    private fun endpoint(host: String) = SshEndpoint(host, 22, "root")

    private fun connectedStore(scope: CoroutineScope, ssh: BackgroundFakeSsh): TerminalStore {
        val hosts = BackgroundHosts().apply { entries[hostKeyAlias(endpoint("a.example"))] = KEY }
        return TerminalStore(
            scope = scope,
            ssh = ssh,
            hostKeyTrust = HostKeyTrust(hosts),
            ids = BackgroundIds(),
            clock = WallClock { 1_000L },
        )
    }

    @Test
    fun aNonTmuxSessionIsWarnedThatBackgroundingMayDropIt() {
        val tmux = TerminalSessionState(
            id = "1",
            endpoint = endpoint("a.example"),
            phase = TerminalPhase.Connected,
            persistent = true,
            geometry = TerminalGeometry(80, 24),
        )
        val plain = tmux.copy(id = "2", persistent = false)
        assertEquals(BackgroundWarning.Resumable, BackgroundSessionPolicy.warningFor(tmux))
        assertEquals(BackgroundWarning.MayDisconnect, BackgroundSessionPolicy.warningFor(plain))

        val state = TerminalState(sessions = listOf(tmux, plain))
        assertEquals(listOf("1"), BackgroundSessionPolicy.sessionsToDetach(state).map { it.id })
        assertEquals(listOf("2"), BackgroundSessionPolicy.sessionsAtRisk(state).map { it.id })
    }

    @Test
    fun returningToTheForegroundInsideTheGraceKeepsTheConnection() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val ssh = BackgroundFakeSsh()
        val store = connectedStore(scope, ssh)
        val visibility = MutableSharedFlow<ApplicationVisibility>(replay = 1)
        val scheduler = BackgroundDetachScheduler(scope, store, ScriptedLifecycle(visibility))
        scheduler.start()

        store.dispatch(
            TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24), persistent = true, tmuxName = "work"),
        )
        advanceUntilIdle()

        visibility.emit(ApplicationVisibility.Background)
        advanceTimeBy(BACKGROUND_DETACH_GRACE_MILLIS - 1_000)
        visibility.emit(ApplicationVisibility.Foreground)
        advanceUntilIdle()

        assertEquals(1, store.state.value.sessions.size, "a quick app switch must not detach")
        assertEquals(TerminalPhase.Connected, store.state.value.sessions.single().phase)
        assertTrue(store.state.value.resumable.isEmpty())
        scheduler.stop()
        store.close()
    }

    @Test
    fun stayingBackgroundedPastTheGraceDetachesTmuxAndKeepsItResumable() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val ssh = BackgroundFakeSsh()
        val store = connectedStore(scope, ssh)
        val visibility = MutableSharedFlow<ApplicationVisibility>(replay = 1)
        val scheduler = BackgroundDetachScheduler(scope, store, ScriptedLifecycle(visibility))
        scheduler.start()

        store.dispatch(
            TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24), persistent = true, tmuxName = "work"),
        )
        advanceUntilIdle()

        visibility.emit(ApplicationVisibility.Background)
        advanceTimeBy(BACKGROUND_DETACH_GRACE_MILLIS + 1_000)
        advanceUntilIdle()

        // The remote tmux session survives; only the local connection goes.
        assertTrue(store.state.value.sessions.isEmpty())
        assertEquals(listOf("work"), store.state.value.resumable.map { it.tmuxName })
        assertTrue(ssh.shells.single().closed, "the local SSH connection must be closed, not leaked")
        scheduler.stop()
        store.close()
    }

    @Test
    fun aNonTmuxSessionIsNotDetachedByTheScheduler() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val ssh = BackgroundFakeSsh()
        val store = connectedStore(scope, ssh)
        val scheduler = BackgroundDetachScheduler(
            scope,
            store,
            ScriptedLifecycle(flowOf(ApplicationVisibility.Background)),
        )
        scheduler.start()

        store.dispatch(TerminalAction.Connect(endpoint("a.example"), TerminalGeometry(80, 24)))
        advanceUntilIdle()
        advanceTimeBy(BACKGROUND_DETACH_GRACE_MILLIS + 1_000)
        advanceUntilIdle()

        // Nothing to detach *to*: the policy leaves it alone, and the UI's pre-background warning is
        // what makes the eventual loss honest.
        assertEquals(1, store.state.value.sessions.size)
        assertTrue(store.state.value.resumable.isEmpty())
        scheduler.stop()
        store.close()
    }
}
