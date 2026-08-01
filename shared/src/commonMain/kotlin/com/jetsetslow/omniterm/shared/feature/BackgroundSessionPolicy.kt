package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.platform.ApplicationLifecycle
import com.jetsetslow.omniterm.shared.platform.ApplicationVisibility
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** ADR 0003: a backgrounded tmux session detaches once this grace period expires. */
const val BACKGROUND_DETACH_GRACE_MILLIS: Long = 25_000L

/** What a session should be told before the app goes to the background. */
enum class BackgroundWarning {
    /** tmux-backed: the remote session and its work survive a detach. */
    Resumable,

    /** Not tmux-backed: backgrounding may drop it, and that must be said before it happens. */
    MayDisconnect,
}

/**
 * Decides what backgrounding means for each session (IOS-064).
 *
 * iOS suspends ordinary apps, so there is no equivalent of Android's foreground service. Rather than
 * declaring an unrelated background mode, OmniTerm keeps the connection for the short grace period
 * the system usually allows, then detaches tmux cleanly so the remote session survives and is
 * resumable. Returning to the foreground first cancels the detach.
 *
 * The grace period is a product constant, not a guarantee: iOS may suspend sooner, and the reconnect
 * path must treat that identically.
 */
object BackgroundSessionPolicy {
    fun warningFor(session: TerminalSessionState): BackgroundWarning =
        if (session.persistent) BackgroundWarning.Resumable else BackgroundWarning.MayDisconnect

    /** Sessions to detach when the grace period expires: connected, tmux-backed, not already parked. */
    fun sessionsToDetach(state: TerminalState): List<TerminalSessionState> =
        state.sessions.filter { it.persistent && it.connected && !it.backgrounded }

    /**
     * Sessions that will simply be lost if the system suspends the app. The UI must have warned
     * about these before backgrounding, not after.
     */
    fun sessionsAtRisk(state: TerminalState): List<TerminalSessionState> =
        state.sessions.filter { !it.persistent && it.connected }
}

/**
 * Runs the grace timer against a [TerminalStore]. Foreground cancels it; expiry detaches every
 * tmux session through the store's normal leave path, so the resumable list and teardown are the
 * same ones the user's own "Leave" action uses.
 */
class BackgroundDetachScheduler(
    private val scope: CoroutineScope,
    private val store: TerminalStore,
    private val lifecycle: ApplicationLifecycle,
    private val graceMillis: Long = BACKGROUND_DETACH_GRACE_MILLIS,
) {
    private var pending: Job? = null

    fun start(): Job = scope.launch {
        lifecycle.visibility.collectLatest { visibility ->
            when (visibility) {
                ApplicationVisibility.Foreground -> cancelPending()
                ApplicationVisibility.Background -> schedule()
            }
        }
    }

    private fun schedule() {
        pending?.cancel()
        pending = scope.launch {
            delay(graceMillis)
            BackgroundSessionPolicy.sessionsToDetach(store.state.value).forEach { session ->
                store.dispatch(TerminalAction.LeaveOrBackground(session.id))
            }
        }
    }

    private fun cancelPending() {
        pending?.cancel()
        pending = null
    }

    fun stop() {
        cancelPending()
    }
}
