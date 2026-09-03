package com.jetsetslow.omniterm

import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The resumable-tmux retention contract, over real SSH against the repository's disposable fleet.
 *
 * A saved recovery row is the user's only handle on a long-running remote job. Deleting one because
 * a probe *failed* loses that handle for good, so the rule is deliberately asymmetric: only an
 * authenticated, exact-name answer of "absent" may remove a row. Everything else — unreachable
 * host, refused connection, auth failure, arbitrary transport text that merely happens to end in
 * "no" — must keep it and offer a retry.
 *
 * The existing coverage does not reach this. `SshConnectionStateTest` pins
 * `parseRemoteTmuxSessionPresence` as a pure function, and the Flutter suite drives a fake
 * transport; neither runs a real `tmux has-session` over a real SSH channel, which is where the
 * command string, the transport's error formatting and the parser have to agree. That agreement is
 * the thing this test exists to check.
 *
 * ```
 * adb shell am instrument -w -e omniterm_e2e_tmux_retention yes \
 *   -e host 10.0.2.2 -e port 2205 -e username omniterm -e password '<fixture password>' \
 *   -e class com.jetsetslow.omniterm.E2eTmuxRecoveryRetentionTest \
 *   com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
 * ```
 */
class E2eTmuxRecoveryRetentionTest {
    @Test
    fun ambiguityKeepsTheRecoveryRowAndConfirmedAbsenceAloneRemovesIt() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_tmux_retention") == "yes")
        val host = requireNotNull(args.getString("host")) { "-e host <ip> is required" }
        val port = requireNotNull(args.getString("port")?.toIntOrNull()) { "-e port <n> is required" }
        val username = requireNotNull(args.getString("username")) { "-e username <name> is required" }
        val password = requireNotNull(args.getString("password")) { "-e password <secret> is required" }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        TerminalSessionManager.clearAll()

        // Two rows for the same fixture: one reachable, one pointed at a closed port on the same
        // address. Using a closed port rather than a bogus IP keeps the failure fast and local
        // instead of waiting out a routing timeout, and still produces the transport-error text the
        // parser must refuse to read as "absent".
        val reachableId = repository.insertServer(
            ServerEntity(
                name = "$PREFIX Reachable", host = host, port = port, username = username,
                groupName = "E2E Lab", authPassword = password, persistentSession = true,
            ),
        ).toInt()
        val unreachableId = repository.insertServer(
            ServerEntity(
                name = "$PREFIX Unreachable", host = host, port = CLOSED_PORT, username = username,
                groupName = "E2E Lab", authPassword = password, persistentSession = true,
            ),
        ).toInt()

        val keptName = "omniterm-e2e-kept"
        val goneName = "omniterm-e2e-never-existed"
        // Both rows must exist before the ViewModel is constructed: `restorablePersistentSessions`
        // is loaded once during init and has no public refresh, so a row written afterwards would
        // never appear and `resumePersistentSession` would silently return.
        repository.upsertPersistentSession(
            PersistentSessionEntity(keptName, unreachableId, "$PREFIX Unreachable"),
        )
        repository.upsertPersistentSession(
            PersistentSessionEntity(goneName, reachableId, "$PREFIX Reachable"),
        )

        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val vm = scenario.viewModel()
        runOnUi { vm.isAppLocked = false }

        try {
            // ---- Ambiguity: the probe cannot complete, so the row must survive. ----
            runOnUi { vm.navigateTo(Screen.Shell) }
            await("kept row visible", 15_000) { vm.restorablePersistentSessions.any { it.tmuxName == keptName } }

            runOnUi { vm.resumePersistentSession(keptName) }
            await("unreachable resume settles", 60_000) { !vm.isTerminalConnecting && vm.terminalConnectError != null }

            assertTrue(
                "an unverifiable probe must keep the row; error was: ${vm.terminalConnectError}",
                repository.getPersistentSessions().any { it.tmuxName == keptName },
            )
            assertTrue(
                "the user must be told the entry was kept and can be retried; got: ${vm.terminalConnectError}",
                vm.terminalConnectError.orEmpty().contains("kept"),
            )
            assertTrue(
                "no shell may be opened for a session that was never verified",
                vm.activeSessions.none { it.tmuxName == keptName },
            )

            // ---- Confirmed absence: authenticated, exact-name "no" is the only thing that removes. ----
            await("absent row visible", 15_000) { vm.restorablePersistentSessions.any { it.tmuxName == goneName } }

            runOnUi { vm.resumePersistentSession(goneName) }
            await("confirmed-absent resume settles", 60_000) {
                if (vm.pendingHostKeyApproval != null) runOnUi { vm.approveHostKey(true) }
                !vm.isTerminalConnecting && vm.terminalConnectError != null
            }

            assertTrue(
                "a confirmed-absent session must be forgotten; error was: ${vm.terminalConnectError}",
                repository.getPersistentSessions().none { it.tmuxName == goneName },
            )
            assertTrue(
                "removal must be explained rather than silent; got: ${vm.terminalConnectError}",
                vm.terminalConnectError.orEmpty().contains("no longer exists"),
            )
            // The failure this guards against is the app "helpfully" opening a fresh tmux session
            // under the lost name, which looks like recovery and silently discards the user's work.
            assertTrue(
                "no empty replacement session may be created under the lost name",
                vm.activeSessions.none { it.tmuxName == goneName },
            )
            assertEquals(
                "the unrelated kept row must not be collateral damage",
                1,
                repository.getPersistentSessions().count { it.tmuxName == keptName },
            )
        } finally {
            repository.deletePersistentSession(keptName)
            repository.deletePersistentSession(goneName)
            repository.deleteServerAndDependents(reachableId)
            repository.deleteServerAndDependents(unreachableId)
            scenario.close()
        }
    }

    private fun runOnUi(block: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private fun ActivityScenario<MainActivity>.viewModel(): AppViewModel {
        val result = AtomicReference<AppViewModel>()
        onActivity { result.set(ViewModelProvider(it)[AppViewModel::class.java]) }
        return result.get()
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (timeout: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", timeout)
        }
    }

    private companion object {
        const val PREFIX = "E2E Tmux Retention"

        /** Published by nothing in `scripts/test-hosts/docker-compose.yml`, so it refuses fast. */
        const val CLOSED_PORT = 2298
    }
}
