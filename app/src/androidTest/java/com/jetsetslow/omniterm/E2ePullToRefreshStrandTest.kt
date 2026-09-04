package com.jetsetslow.omniterm

import android.app.Application
import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Pull-to-refresh must never strand a host on the "Checking host…" spinner.
 *
 * The reported defect: a host would sit on that spinner indefinitely with **no error and nothing to
 * retry**, and only a reboot of the remote machine appeared to clear it. Rebooting looked like the
 * cure because it removed the reason the host was slow (a wedged network mount that made its probe
 * take seconds instead of milliseconds) rather than because anything was wrong on the server.
 *
 * The actual mechanism was local and had nothing to do with the remote host:
 *
 *  1. `refreshAllServers()` marked every host `connecting` — which is what the row renders as
 *     "Checking host…".
 *  2. It then called `startTelemetryPolling()`, whose first act was to cancel every in-flight probe;
 *     the probes were also children of `pollingJob`, so cancelling that killed them regardless.
 *  3. In `probeServer` the cancellation path could not write a terminal state: the coroutine was
 *     already cancelled, so every suspension point in the `catch`/`finally` rethrew immediately and
 *     neither the status restore nor the `probedServerIds` entry ever landed.
 *  4. So the row stayed `connecting`, unprobed, forever — and `refreshAllServers()` reported nothing
 *     at all, because unlike `refreshServer()` it never computed a failure message.
 *
 * A host that answers in milliseconds finished before the next pull could cancel it, which is why
 * this only ever bit the one slow host and looked intermittent.
 *
 * This test reproduces the starvation directly: a host that cannot be reached quickly, pulled
 * repeatedly at a cadence shorter than its own probe. It is device-only because it needs the real
 * Room database, the real Android networking stack and the real view-model coroutine scope.
 *
 * Opt in with `-e omniterm_e2e_refresh_strand yes`.
 */
@RunWith(AndroidJUnit4::class)
class E2ePullToRefreshStrandTest {

    /**
     * TEST-NET-1 (RFC 5737). Guaranteed not to be routable, so the reachability probe takes seconds
     * to give up rather than failing instantly — the same wide cancellation window the user's slow
     * host had, without depending on anything the developer machine happens to be running.
     */
    private val unroutableHost = "192.0.2.1"

    private lateinit var repository: AppRepository
    private val seeded = mutableListOf<Int>()

    @After
    fun removeSeededHosts() = runBlocking {
        if (::repository.isInitialized) {
            seeded.forEach { runCatching { repository.deleteServerAndDependents(it) } }
        }
    }

    @Test
    fun repeatedPullsNeverLeaveAHostCheckingWithoutAnError() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_refresh_strand") == "yes")

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            "This test seeds app data and is restricted to debuggable builds"
        }

        repository = AppRepository(AppDatabase.getDatabase(context))
        // Only ever touch rows this test created; a developer's real hosts must survive it.
        val id = repository.insertServer(
            ServerEntity(
                name = SEED_NAME,
                host = unroutableHost,
                port = 22,
                username = "nobody",
                groupName = "E2E Refresh",
                authPassword = "unused",
                notes = "Deliberately unroutable pull-to-refresh fixture",
            )
        ).toInt()
        seeded += id

        val app = context.applicationContext as Application
        val vm = AppViewModelHandle(app).viewModel

        // Phase 1 -- measure how long one *uncancelled* probe of this host takes. `refreshServer`
        // awaits probeServer directly, so nothing interferes with it. The pull cadence below is
        // derived from this rather than hard-coded, because the whole defect is a race between the
        // pull interval and the probe duration: a cadence guessed wrong tests nothing.
        val probeStarted = System.currentTimeMillis()
        vm.refreshServer(id)
        var probeMs = -1L
        while (System.currentTimeMillis() - probeStarted < MAX_PROBE_MS) {
            if (repository.getServerById(id)?.status != "connecting" &&
                vm.probedServerIds.containsKey(id)
            ) {
                probeMs = System.currentTimeMillis() - probeStarted
                break
            }
            delay(100)
        }
        assertTrue(
            "A single probe of $unroutableHost did not settle within ${MAX_PROBE_MS}ms, so this " +
                "test cannot calibrate its pull cadence",
            probeMs > 0,
        )
        assertTrue(
            "A probe of $unroutableHost completed in ${probeMs}ms, too fast to be interrupted by a " +
                "realistic pull. This test needs a host that stalls.",
            probeMs >= MIN_PROBE_MS,
        )

        // Phase 1 legitimately reported that this host is offline. Clear it, or phase 2 would read
        // that stale message as "the refresh told the user something" and pass without ever
        // exercising the pull path.
        vm.dismissManualRefreshError()

        // Phase 2 -- pull faster than the host can answer, and keep pulling. This is the reported
        // behaviour ("when i pull to refresh again"), and it is what starves the probe: on the
        // unfixed build each pull cancelled the probe the previous pull had started, so the elapsed
        // probe time never accumulated past one interval and no probe ever reached a verdict.
        val pullInterval = probeMs / 4
        val windowMs = probeMs * 3
        val startedAt = System.currentTimeMillis()
        var pulls = 0
        // Sampled throughout so a failure says what the row actually did, not just where it ended.
        val trail = mutableListOf<String>()
        while (System.currentTimeMillis() - startedAt < windowMs) {
            vm.refreshAllServers()
            pulls++
            val until = System.currentTimeMillis() + pullInterval
            while (System.currentTimeMillis() < until) {
                trail += "+${System.currentTimeMillis() - startedAt}ms=" +
                    "${repository.getServerById(id)?.status}/" +
                    "probed=${vm.probedServerIds.containsKey(id)}/" +
                    "err=${vm.manualRefreshError != null}"
                delay(500)
            }
        }

        // Checked while the pulls are still in flight, which is the state the user is actually
        // looking at. A probe that survives them has had ~3x its own duration to finish.
        val row = repository.getServerById(id)
        val reported = vm.manualRefreshError
        val stranded = row?.status == "connecting" && reported == null
        assertTrue(
            "Host was left on \"Checking host…\" with no error after $pulls pulls at " +
                "${pullInterval}ms over ${windowMs}ms (one probe takes ${probeMs}ms). " +
                "status=${row?.status}, manualRefreshError=$reported\n" +
                trail.joinToString("\n"),
            !stranded,
        )
    }

    /** Keeps view-model construction on the main thread, as Android requires. */
    private class AppViewModelHandle(app: Application) {
        val viewModel: com.jetsetslow.omniterm.ui.AppViewModel = run {
            var created: com.jetsetslow.omniterm.ui.AppViewModel? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                created = com.jetsetslow.omniterm.ui.AppViewModel(app)
            }
            requireNotNull(created)
        }
    }

    private companion object {
        const val SEED_NAME = "E2E Refresh Strand"

        /** Give up calibrating if even an uninterrupted probe will not settle. */
        const val MAX_PROBE_MS = 90_000L

        /**
         * Below this a probe is too quick for any realistic pull to interrupt, and the test would
         * pass for the wrong reason. Failing loudly is better than a green run that proves nothing.
         */
        const val MIN_PROBE_MS = 2_000L
    }
}
